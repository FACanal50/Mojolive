//
//  AudioCaptureEngine.swift
//  MojoLive — Módulo 1
//
//  Captura de audio con AVAudioEngine:
//   • Selección de entrada: micrófono incorporado, USB (interfaces/mics class-compliant),
//     Bluetooth HFP, headset cableado / line-in.
//   • Entrega buffers PCM con timestamp en el reloj de host (sincronizado con la cámara).
//   • Alimenta el medidor de nivel (pico/RMS) para el vúmetro.
//
//  No conoce la UI ni el encoder: publica PCM vía `pcmHandler`.
//

import AVFoundation
import CoreMedia

enum AudioInputKind: String {
    case builtIn = "Incorporado", usb = "USB", bluetooth = "Bluetooth", wired = "Cableado", other = "Otro"

    init(port: AVAudioSession.Port) {
        switch port {
        case .builtInMic: self = .builtIn
        case .usbAudio: self = .usb
        case .bluetoothHFP, .bluetoothLE: self = .bluetooth
        case .headsetMic, .lineIn: self = .wired
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .builtIn: return "iphone"
        case .usb: return "cable.connector"
        case .bluetooth: return "wave.3.right"
        case .wired: return "headphones"
        case .other: return "mic"
        }
    }
}

struct AudioInputOption: Identifiable, Hashable {
    let id: String          // AVAudioSessionPortDescription.uid
    let name: String
    let kind: AudioInputKind
    let channels: Int
}

final class AudioCaptureEngine {

    /// PCM + timestamp de presentación (reloj de host). Se llama en el hilo del tap.
    var pcmHandler: ((AVAudioPCMBuffer, CMTime) -> Void)?
    /// Cambios en la lista de entradas disponibles (enchufar/desenchufar). Main thread.
    var inputsChanged: (() -> Void)?

    let meter = AudioLevelMeter()
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var isRunning = false
    private let tapQueue = DispatchQueue(label: "mojolive.audio.control")

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(routeChanged(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(engineConfigChanged(_:)),
                       name: .AVAudioEngineConfigurationChange, object: engine)
        nc.addObserver(self, selector: #selector(interruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: Sesión de audio

    /// Configura AVAudioSession para captura broadcast:
    /// - `.measurement`: desactiva AGC / reducción de ruido / EQ de voz → señal limpia.
    /// - Bluetooth HFP habilitado (nota: HFP es banda angosta, 16 kHz típico).
    func configureSession() throws {
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true, options: [])
        configureBuiltInStereoIfAvailable()
    }

    /// En iPhones con varios micrófonos, iOS 14+ permite un patrón polar estéreo
    /// con el micrófono incorporado. Se orienta para el modo horizontal de la app.
    private func configureBuiltInStereoIfAvailable() {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let source = builtIn.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true })
        else { return }
        do {
            try source.setPreferredPolarPattern(.stereo)
            try builtIn.setPreferredDataSource(source)
            if session.currentRoute.inputs.first?.portType == .builtInMic {
                try session.setPreferredInputOrientation(.landscapeRight)
            }
        } catch {
            appLog.info("Estéreo incorporado no disponible: \(error.localizedDescription)")
        }
    }

    // MARK: Entradas

    func availableInputs() -> [AudioInputOption] {
        (session.availableInputs ?? []).map {
            AudioInputOption(id: $0.uid, name: $0.portName, kind: AudioInputKind(port: $0.portType),
                             channels: $0.channels?.count ?? 1)
        }
    }

    var currentInput: AudioInputOption? {
        guard let port = session.currentRoute.inputs.first else { return nil }
        return AudioInputOption(id: port.uid, name: port.portName, kind: AudioInputKind(port: port.portType),
                                channels: port.channels?.count ?? 1)
    }

    var currentSampleRate: Double { session.sampleRate }

    func selectInput(_ option: AudioInputOption) throws {
        guard let port = session.availableInputs?.first(where: { $0.uid == option.id }) else { return }
        try session.setPreferredInput(port)
        if port.portType == .builtInMic { configureBuiltInStereoIfAvailable() }
        // El cambio de ruta dispara AVAudioEngineConfigurationChange → se reinstala el tap.
    }

    /// Ganancia de entrada analógica (0–1). Solo algunos dispositivos/entradas lo permiten.
    var isInputGainSettable: Bool { session.isInputGainSettable }
    var inputGain: Float { session.inputGain }
    func setInputGain(_ gain: Float) {
        guard session.isInputGainSettable else { return }
        try? session.setInputGain(min(max(gain, 0), 1))
    }

    // MARK: Motor

    func start() throws {
        try tapQueue.sync { try startLocked() }
    }

    func stop() {
        tapQueue.sync {
            guard isRunning else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
    }

    /// Debe ejecutarse en `tapQueue` (serializa start/stop/reconfiguración).
    private func startLocked() throws {
        guard !isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)        // idempotente: evita "tap ya instalado"
        installTap()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            appLog.error("Formato de entrada inválido: \(format)")
            return
        }
        // Latencia de hardware de entrada: se descuenta del timestamp para alinear con el video.
        let inputLatency = CMTime(seconds: session.inputLatency + session.ioBufferDuration, preferredTimescale: 48_000)

        // bufferSize es orientativo: iOS puede entregar bloques más grandes.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.meter.accumulate(buffer)
            let pts: CMTime
            if when.isHostTimeValid {
                pts = CMTimeSubtract(HostClock.time(fromHostTime: when.hostTime), inputLatency)
            } else {
                pts = CMTimeSubtract(HostClock.now, inputLatency)
            }
            self.pcmHandler?(buffer, pts)
        }
    }

    // MARK: Notificaciones

    @objc private func engineConfigChanged(_ note: Notification) {
        // Cambió el hardware (otra entrada, otra frecuencia de muestreo): rearmar el grafo.
        tapQueue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            do { try self.startLocked() } catch { appLog.error("No se pudo reiniciar audio: \(error.localizedDescription)") }
        }
    }

    @objc private func routeChanged(_ note: Notification) {
        DispatchQueue.main.async { self.inputsChanged?() }
    }

    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            tapQueue.async {
                try? self.session.setActive(true)
                if self.isRunning { try? self.engine.start() }
            }
        }
    }
}
