//
//  BroadcastPipeline.swift
//  MojoLive — Módulo 1
//
//  Orquestador del flujo completo. No contiene lógica de UI.
//
//   Cámara ──► FrameCompositor (zócalo/logo en GPU) ──┬──► Preview de programa
//                                                     └──► VideoEncoder (H.264/HEVC) ─┐
//   Micrófono ──► AudioCaptureEngine ──┬──► Vúmetro                                   ├──► TSMuxer ──► SRTTransport
//                                      └──► AACEncoder ──────────────────────────────┘        ▲
//                                                         AdaptiveBitrateController ◄── stats ┘
//
//  Colas:
//   camera.videoQueue  — composición + submit al encoder + preview
//   tap de audio       — medición + submit al encoder AAC
//   muxQueue           — TS mux + envío SRT (serial, único dueño del muxer)
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

    // Componentes (expuestos para que el ViewModel acceda a controles específicos)
    let camera = CameraController()
    let audio = AudioCaptureEngine()
    let compositor = FrameCompositor()
    private let videoEncoder = VideoEncoder()
    private let audioEncoder = AACEncoder(bitrate: 128_000)
    private let srt = SRTTransport()
    private var muxer: TSMuxer?
    private var abr: AdaptiveBitrateController?

    private let muxQueue = DispatchQueue(label: "mojolive.mux", qos: .userInteractive)
    private let stateLock = NSLock()
    private var _isLive = false
    private(set) var profile = VideoProfile()
    private var srtConfig = SRTConfiguration()

    // Medición de fps real
    private var frameCounter = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var measuredFPS: Double = 0

    // MARK: Salidas hacia la UI

    /// Frame de programa (con gráfica) para la vista previa. Se llama en la cola de video.
    var previewHandler: ((CMSampleBuffer) -> Void)?
    /// Estado de transmisión. Main thread.
    var statusHandler: ((LiveStatus) -> Void)?
    private var status = LiveStatus()

    var isLive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isLive
    }

    init() {
        wire()
    }

    // MARK: Preparación (cámara + audio, sin transmitir)

    func prepare(profile: VideoProfile, lens: CameraLens) async throws {
        guard await AudioCaptureEngine.requestAccess() else {
            throw CameraError.configurationFailed("Sin permiso de micrófono. Habilitalo en Ajustes > MojoLive.")
        }
        try audio.configureSession()
        try await camera.configure(profile: profile, lens: lens)
        self.profile = profile
        let dims = profile.resolution.dimensions
        compositor.configure(width: Int(dims.width), height: Int(dims.height), fps: profile.frameRate)
        try audio.start()
        camera.start()
    }

    /// Cambio de lente o de perfil (no permitido al aire: el receptor vería un cambio de formato).
    func reconfigure(profile: VideoProfile, lens: CameraLens) async throws {
        guard !isLive else { return }
        try await camera.configure(profile: profile, lens: lens)
        self.profile = profile
        let dims = profile.resolution.dimensions
        compositor.configure(width: Int(dims.width), height: Int(dims.height), fps: profile.frameRate)
    }

    /// Cambio de lente al aire: misma resolución/fps, solo cambia el dispositivo.
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
        mux.outputHandler = { [weak self] data in self?.srt.send(data) }   // corre en muxQueue
        muxQueue.sync { muxer = mux }

        abr = config.adaptiveBitrate
            ? AdaptiveBitrateController(minBitrate: profile.minBitrate, maxBitrate: profile.maxBitrate,
                                        startBitrate: profile.startBitrate, latencyMs: config.latencyMs)
            : nil

        srtConfig = config
        status = LiveStatus(connection: .connecting, videoBitrate: profile.startBitrate)
        stateLock.lock(); _isLive = true; stateLock.unlock()
        UIApplication.shared.isIdleTimerDisabled = true

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
            guard let self, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let program = self.compositor.process(pixelBuffer)

            if self.isLive { self.videoEncoder.encode(program, pts: pts) }
            if let preview = SampleBufferFactory.make(from: program, pts: pts) {
                self.previewHandler?(preview)
            }
            self.countFrame()
        }

        // AUDIO: tap → encoder AAC (el medidor ya acumula dentro de AudioCaptureEngine)
        audio.pcmHandler = { [weak self] buffer, pts in
            guard let self, self.isLive else { return }
            self.audioEncoder.encode(buffer, pts: pts)
        }

        // Encoders → muxer (cola serial)
        videoEncoder.outputHandler = { [weak self] frame in
            guard let self else { return }
            self.muxQueue.async { self.muxer?.muxVideo(frame) }
        }
        audioEncoder.outputHandler = { [weak self] frame in
            guard let self else { return }
            self.muxQueue.async { self.muxer?.muxAudio(frame) }
        }

        // SRT → estado / estadísticas / ABR
        srt.connectedHandler = { [weak self] in
            guard let self else { return }
            // Nueva conexión: reiniciar timeline TS y forzar IDR para arranque inmediato del decoder.
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
                appLog.info("ABR → \(newRate / 1000) kbps (\(abr.lastReason))")
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
        statusHandler?(status)   // ya en main (los handlers de SRT publican en main)
    }
}
