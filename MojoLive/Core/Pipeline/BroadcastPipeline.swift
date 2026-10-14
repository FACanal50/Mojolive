//
//  BroadcastPipeline.swift
//  MojoLive — Módulo 1
//
//  Orquestador del flujo completo. No contiene lógica de UI.
//
//   Cámara ──► FrameCompositor (zócalo/logo en GPU) ──┬──► Preview de programa
//                                                    └──► VideoEncoder (H.264/HEVC) ─┐
//   Micrófono ──► AudioCaptureEngine ──┬──► Vúmetro                                 ├──► TSMuxer ──► SRTTransport
//                                      └──► AACEncoder ──────────────────────────────┘         ▲
//                                                         AdaptiveBitrateController ◄── stats ┘
//

import AVFoundation
import CoreMedia
import UIKit

struct LiveStatus: Equatable {
    var connection: SRTConnectionState = .idle
    var stats = SRTStats()
    var videoBitrate = 0
    var abrReason = ""
    var captureFPS: Double = 0
    var droppedCameraFrames = 0
}

final class BroadcastPipeline {

    // Componentes
    let camera = CameraController()
    let audio = AudioCaptureEngine()
    let compositor = FrameCompositor()
    private let videoEncoder = VideoEncoder()
    private let audioEncoder = AACEncoder(bitrate: 128_000)
    private let srt = SRTTransport()
    private var muxer: TSMuxer?
    private var abr: AdaptiveBitrateController?

    private let muxQueue = DispatchQueue(label: "coop.coopmorteros.mojolive.mux", qos: .userInteractive)
    private let stateLock = NSLock()
    private var _isLive = false
    private(set) var profile = VideoProfile()
    private var srtConfig = SRTConfiguration()

    // Medición de fps real
    private var frameCounter = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var measuredFPS: Double = 0

    // MARK: Salidas hacia la UI

    var previewHandler: ((CMSampleBuffer) -> Void)?
    var statusHandler: ((LiveStatus) -> Void)?
    private var status = LiveStatus()

    var isLive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isLive
    }

    init() {
        wire()
    }

    // MARK: Preparación

    func prepare(profile: VideoProfile, lens: CameraLens) async throws {
        guard await AudioCaptureEngine.requestAccess() else {
            throw CameraError.configurationFailed("Sin permiso de micrófono. Habilitalo en Ajustes.")
        }
        try audio.configureSession()
        try await camera.configure(profile: profile, lens: lens)
        self.profile = profile
        let dims = profile.resolution.dimensions
        compositor.configure(width: Int(dims.width), height: Int(dims.height), fps: profile.frameRate)
        try audio.start()
        camera.start()
    }

    func reconfigure(profile: VideoProfile, lens: CameraLens) async throws {
        guard !isLive else { return }
        try await camera.configure(profile: profile, lens: lens)
        self.profile = profile
        let dims = profile.resolution.dimensions
        compositor.configure(width: Int(dims.width), height: Int(dims.height), fps: profile.frameRate)
    }

    func switchLens(_ lens: CameraLens) async throws {
        try await camera.configure(profile: profile, lens: lens)
        videoEncoder.requestKeyframe()
    }

    func shutdown() {
        stopLive()
        camera.stop()
        audio.stop()
    }

    // MARK: Transmisión

    func goLive(srt config: SRTConfiguration) throws {
        guard !isLive else { return }
        if let err = config.validationError() { throw CameraError.configurationFailed(err) }

        try videoEncoder.start(profile: profile)
        audioEncoder.start()

        let mux = TSMuxer(videoStreamType: profile.codec.mpegTSStreamType, hasAudio: true)
        mux.outputHandler = { [weak self] data in self?.srt.send(data) }
        muxQueue.sync { muxer = mux }

        abr = config.adaptiveBitrate
            ? AdaptiveBitrateController(minBitrate: profile.minBitrate, maxBitrate: profile.maxBitrate,
                                        startBitrate: profile.startBitrate, latencyMs: config.latencyMs)
            : nil

        srtConfig = config
        status = LiveStatus(connection: .connecting, videoBitrate: profile.startBitrate)
        stateLock.lock(); _isLive = true; stateLock.unlock()
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }

        srt.start(config: config, maxBitrate: profile.maxBitrate)
    }

    func stopLive() {
        guard isLive else { return }
        stateLock.lock(); _isLive = false; stateLock.unlock()
        srt.stop()
        videoEncoder.stop()
        audioEncoder.stop()
        muxQueue.sync { muxer = nil }
        abr = nil
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func requestKeyframe() { videoEncoder.requestKeyframe() }

    // MARK: Cableado interno

    private func wire() {
        // VIDEO: cámara → compositor → preview + encoder
        camera.videoHandler = { [weak self] sample in
            autoreleasepool {
                guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let program = self.compositor.process(pixelBuffer)

                if self.isLive { self.videoEncoder.encode(program, pts: pts) }
                if let preview = SampleBufferFactory.make(from: program, pts: pts) {
                    self.previewHandler?(preview)
                }
                self.countFrame()
            }
        }

        // AUDIO: tap → encoder AAC
        audio.pcmHandler = { [weak self] buffer, pts in
            autoreleasepool {
                guard let self, self.isLive else { return }
                self.audioEncoder.encode(buffer, pts: pts)
            }
        }

        // Encoders → muxer (cola serial protegida con autoreleasepool para evitar fugas en streaming prolongado)
        videoEncoder.outputHandler = { [weak self] frame in
            guard let self else { return }
            self.muxQueue.async {
                autoreleasepool {
                    self.muxer?.muxVideo(frame)
                }
            }
        }
        
        audioEncoder.outputHandler = { [weak self] frame in
            guard let self else { return }
            self.muxQueue.async {
                autoreleasepool {
                    self.muxer?.muxAudio(frame)
                }
            }
        }

        // SRT → estado / estadísticas / ABR
        srt.connectedHandler = { [weak self] in
            guard let self else { return }
            self.muxQueue.async { self.muxer?.reset() }
            self.videoEncoder.requestKeyframe()
        }
        srt.stateHandler = { [weak self] state in
            guard let self else { return }
            self.status.connection = state
            self.publishStatus()
        }
        srt.statsHandler = { [weak self] stats in
            guard let self else { return }
            self.status.stats = stats
            if let abr = self.abr, let newRate = abr.update(with: stats) {
                self.videoEncoder.setBitrate(newRate)
                self.status.abrReason = abr.lastReason
            }
            self.status.videoBitrate = self.videoEncoder.currentBitrate
            self.status.captureFPS = self.measuredFPS
            self.status.droppedCameraFrames = self.camera.droppedFrames
            self.publishStatus()
        }
    }

    private func countFrame() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            measuredFPS = Double(frameCounter) / (now - fpsWindowStart)
            frameCounter = 0
            fpsWindowStart = now
            if !isLive {
                let fps = measuredFPS
                DispatchQueue.main.async {
                    self.status.captureFPS = fps
                    self.publishStatus()
                }
            }
        }
    }

    private func publishStatus() {
        statusHandler?(status)
    }
}
