//
//  ProductionViewModel.swift
//  MojoLive — Módulo 1
//
//  Puente entre la UI (SwiftUI) y el BroadcastPipeline. Todo lo publicado aquí
//  vive en el main actor; el pipeline trabaja en sus propias colas.
//

import SwiftUI
import AVFoundation
import Combine

@MainActor
final class ProductionViewModel: ObservableObject {

    // MARK: Estado publicado

    @Published private(set) var status = LiveStatus()
    @Published private(set) var isLive = false
    @Published private(set) var liveSince: Date?
    @Published private(set) var meter = MeterBallistics()
    @Published private(set) var readout = CameraReadout()
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var lens: CameraLens = .wide
    @Published private(set) var availableLenses: [CameraLens] = CameraLens.available
    @Published private(set) var audioInputs: [AudioInputOption] = []
    @Published private(set) var currentInput: AudioInputOption?
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var isReady = false
    @Published var errorMessage: String?

    // Configuración persistida
    @Published var profile: VideoProfile
    @Published var srtConfig: SRTConfiguration
    @Published var graphics: GraphicsState {
        didSet {
            pipeline.compositor.update(graphics: graphics)
            store.saveGraphics(graphics)
        }
    }

    // Controles manuales (true = automático)
    @Published var exposureAuto = true
    @Published var focusAuto = true
    @Published var whiteBalanceAuto = true
    @Published var manualISO: Float = 100
    @Published var manualShutter: Double = 1.0 / 50
    @Published var manualFocus: Float = 0.5
    @Published var manualKelvin: Float = 5600
    @Published var inputGain: Float = 0.5

    // MARK: Infraestructura

    let pipeline = BroadcastPipeline()
    /// Destino de la señal de programa (no aislado al main actor: recibe frames en la cola de video).
    let previewSink = PreviewSink()
    private let store = SettingsStore.shared
    private var timers: Set<AnyCancellable> = []

    init() {
        profile = store.loadVideo()
        srtConfig = store.loadSRT()
        graphics = store.loadGraphics()
        pipeline.compositor.update(graphics: graphics)

        Self.wirePreview(pipeline, to: previewSink)
        pipeline.statusHandler = { [weak self] st in self?.status = st }
        pipeline.audio.inputsChanged = { [weak self] in self?.refreshAudioInputs() }
        pipeline.camera.errorHandler = { [weak self] err in self?.errorMessage = err.localizedDescription }

        // Vúmetro a 30 Hz
        Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tickMeter() }
            .store(in: &timers)
        // Lectura de cámara a 4 Hz (valores en automático)
        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tickReadout() }
            .store(in: &timers)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.thermal = ProcessInfo.processInfo.thermalState }
            .store(in: &timers)
    }

    /// Se arma fuera del main actor: el closure corre en la cola de video de la cámara.
    nonisolated private static func wirePreview(_ pipeline: BroadcastPipeline, to sink: PreviewSink) {
        pipeline.previewHandler = { sample in sink.enqueue(sample) }
    }

    // MARK: Arranque

    func start() async {
        guard !isReady else { return }
        do {
            try await pipeline.prepare(profile: profile, lens: lens)
            capabilities = pipeline.camera.capabilities
            refreshAudioInputs()
            inputGain = pipeline.audio.inputGain
            thermal = ProcessInfo.processInfo.thermalState
            isReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Aire

    func toggleLive() {
        if isLive {
            pipeline.stopLive()
            isLive = false
            liveSince = nil
        } else {
            do {
                store.saveSRT(srtConfig)
                try pipeline.goLive(srt: srtConfig)
                isLive = true
                liveSince = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Perfil de video / lente

    func applyVideoProfile(_ newProfile: VideoProfile) async {
        guard !isLive else { return }
        do {
            try await pipeline.reconfigure(profile: newProfile, lens: lens)
            profile = newProfile
            store.saveVideo(newProfile)
            capabilities = pipeline.camera.capabilities
            resetManualControls()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectLens(_ newLens: CameraLens) async {
        guard newLens != lens else { return }
        do {
            try await pipeline.switchLens(newLens)
            lens = newLens
            capabilities = pipeline.camera.capabilities
            resetManualControls()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetManualControls() {
        exposureAuto = true; focusAuto = true; whiteBalanceAuto = true
    }

    // MARK: Controles manuales

    func setExposureAuto(_ auto: Bool) {
        exposureAuto = auto
        if auto {
            pipeline.camera.setAutoExposure()
        } else {
            manualISO = readout.iso; manualShutter = readout.shutterSeconds
            pipeline.camera.setManualExposure(iso: manualISO, shutterSeconds: manualShutter)
        }
    }

    func setISO(_ iso: Float) {
        manualISO = iso
        exposureAuto = false
        pipeline.camera.setManualExposure(iso: iso, shutterSeconds: manualShutter)
    }

    func setShutter(_ seconds: Double) {
        manualShutter = seconds
        exposureAuto = false
        pipeline.camera.setManualExposure(iso: manualISO, shutterSeconds: seconds)
    }

    func setFocusAuto(_ auto: Bool) {
        focusAuto = auto
        if auto { pipeline.camera.setAutoFocus() }
        else { manualFocus = readout.lensPosition; pipeline.camera.setManualFocus(lensPosition: manualFocus) }
    }

    func setFocus(_ position: Float) {
        manualFocus = position
        focusAuto = false
        pipeline.camera.setManualFocus(lensPosition: position)
    }

    func setWhiteBalanceAuto(_ auto: Bool) {
        whiteBalanceAuto = auto
        if auto { pipeline.camera.setAutoWhiteBalance() }
        else { manualKelvin = readout.kelvin.rounded(); pipeline.camera.setWhiteBalance(kelvin: manualKelvin) }
    }

    func setKelvin(_ k: Float) {
        manualKelvin = k
        whiteBalanceAuto = false
        pipeline.camera.setWhiteBalance(kelvin: k)
    }

    func tapToFocus(normalized point: CGPoint) {
        guard focusAuto else { return }
        pipeline.camera.focusAndExpose(at: point)
    }

    // MARK: Audio

    func refreshAudioInputs() {
        audioInputs = pipeline.audio.availableInputs()
        currentInput = pipeline.audio.currentInput
    }

    func selectAudioInput(_ option: AudioInputOption) {
        do {
            try pipeline.audio.selectInput(option)
            // La ruta se actualiza de forma asíncrona; refrescamos tras un instante.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshAudioInputs() }
        } catch {
            errorMessage = "No se pudo seleccionar \(option.name): \(error.localizedDescription)"
        }
    }

    var isGainSettable: Bool { pipeline.audio.isInputGainSettable }

    func setInputGain(_ g: Float) {
        inputGain = g
        pipeline.audio.setInputGain(g)
    }

    // MARK: Gráfica

    func setLogo(_ image: UIImage?) {
        store.saveLogo(image)
        graphics.logo = image
    }

    func toggleLowerThird() { graphics.showLowerThird.toggle() }

    // MARK: Timers

    private func tickMeter() {
        meter.update(with: pipeline.audio.meter.read(), dt: 1.0 / 30)
    }

    private func tickReadout() {
        guard isReady else { return }
        readout = pipeline.camera.readout()
    }

    var liveDurationText: String {
        guard let since = liveSince else { return "00:00:00" }
        let t = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}

// MARK: - Balística del vúmetro

/// Comportamiento tipo PPM: ataque instantáneo, caída 20 dB/s, peak-hold 1,5 s, clip latcheado 2 s.
struct MeterBallistics: Equatable {
    var rms: [Float] = [-60, -60]
    var peak: [Float] = [-60, -60]
    var peakHold: [Float] = [-60, -60]
    var clip = false

    private var holdTimer: [Double] = [0, 0]
    private var clipTimer: Double = 0

    static let floor: Float = -60
    static let releaseDBPerSecond: Float = 20

    mutating func update(with levels: AudioLevels, dt: Double) {
        let fall = Self.releaseDBPerSecond * Float(dt)
        for ch in 0..<2 {
            let inRMS = max(levels.rms[ch], Self.floor)
            let inPeak = max(levels.peak[ch], Self.floor)
            rms[ch] = inRMS >= rms[ch] ? inRMS : max(rms[ch] - fall, inRMS)
            peak[ch] = inPeak >= peak[ch] ? inPeak : max(peak[ch] - fall, inPeak)
            if inPeak >= peakHold[ch] {
                peakHold[ch] = inPeak; holdTimer[ch] = 1.5
            } else if holdTimer[ch] > 0 {
                holdTimer[ch] -= dt
            } else {
                peakHold[ch] = max(peakHold[ch] - fall, peak[ch])
            }
        }
        if levels.clipped { clip = true; clipTimer = 2 }
        else if clipTimer > 0 { clipTimer -= dt; if clipTimer <= 0 { clip = false } }
    }
}
