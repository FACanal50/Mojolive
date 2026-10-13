//
//  CameraController.swift
//  MojoLive — Módulo 1
//
//  Controlador de cámara (AVFoundation). Responsabilidades:
//   • Configurar AVCaptureSession con el formato exacto del sensor (1080p/4K, 25–60 fps).
//   • Controles manuales: ISO, obturación, enfoque (lens position), balance de blancos (K).
//   • Selección de lente: principal (wide), gran angular (ultra wide), tele, frontal.
//   • Entregar CMSampleBuffers (YUV 4:2:0) al pipeline vía `videoHandler`.
//
//  No conoce nada de UI ni de red. Toda la configuración del dispositivo se
//  serializa en `sessionQueue`; los frames llegan en `videoQueue`.
//

import AVFoundation
import CoreMedia
import UIKit

enum CameraLens: String, CaseIterable, Identifiable {
    case wide      = "Principal"
    case ultraWide = "Gran angular"
    case telephoto = "Tele"
    case front     = "Frontal"

    var id: String { rawValue }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide, .front: return .builtInWideAngleCamera
        case .ultraWide:    return .builtInUltraWideCamera
        case .telephoto:    return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position { self == .front ? .front : .back }

    var shortLabel: String {
        switch self {
        case .wide: return "1×"
        case .ultraWide: return "0.5×"
        case .telephoto: return "TELE"
        case .front: return "FRONT"
        }
    }

    var device: AVCaptureDevice? {
        AVCaptureDevice.default(deviceType, for: .video, position: position)
    }

    static var available: [CameraLens] { allCases.filter { $0.device != nil } }
}

/// Rangos que el dispositivo/formato activo soporta. La UI los usa para acotar sliders.
struct CameraCapabilities: Equatable {
    var isoRange: ClosedRange<Float> = 50...1600
    /// Duración de exposición en segundos (mín … máx permitida por el fps actual).
    var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    var supportsManualExposure = true
    var supportsManualFocus = true
    var supportsManualWhiteBalance = true
    var kelvinRange: ClosedRange<Float> = 2500...10000
    var supports4K = true
    var maxFrameRate1080 = 60
    var maxFrameRate4K = 60
}

/// Lectura en vivo de los parámetros (útil cuando están en automático).
struct CameraReadout: Equatable {
    var iso: Float = 0
    var shutterSeconds: Double = 0
    var lensPosition: Float = 0
    var kelvin: Float = 5600
    var tint: Float = 0
}

enum CameraError: LocalizedError {
    case notAuthorized, deviceUnavailable(CameraLens), formatUnavailable(String), configurationFailed(String)
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Sin permiso de cámara. Habilitalo en Ajustes > MojoLive."
        case .deviceUnavailable(let l): return "La lente \(l.rawValue) no está disponible en este equipo."
        case .formatUnavailable(let s): return "Formato no soportado por esta lente: \(s)."
        case .configurationFailed(let s): return "No se pudo configurar la cámara: \(s)"
        }
    }
}

final class CameraController: NSObject {

    // MARK: Salidas

    /// Se invoca en `videoQueue` con cada frame capturado (420v/420f).
    var videoHandler: ((CMSampleBuffer) -> Void)?
    /// Se invoca en main ante errores en tiempo de ejecución.
    var errorHandler: ((Error) -> Void)?

    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "mojolive.camera.video", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "mojolive.camera.session", qos: .userInitiated)

    private let deviceLock = NSLock()
    private var _device: AVCaptureDevice?
    /// Dispositivo activo. Se escribe en sessionQueue y se lee desde main (readout): protegido.
    private(set) var device: AVCaptureDevice? {
        get { deviceLock.lock(); defer { deviceLock.unlock() }; return _device }
        set { deviceLock.lock(); _device = newValue; deviceLock.unlock() }
    }
    private var input: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()

    private(set) var profile = VideoProfile()
    private(set) var lens: CameraLens = .wide
    private(set) var capabilities = CameraCapabilities()
    private(set) var droppedFrames = 0

    var stabilizationEnabled = true

    // MARK: Ciclo de vida

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError, object: session)
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Configura la sesión completa. Puede llamarse de nuevo para cambiar lente o perfil.
    func configure(profile: VideoProfile, lens: CameraLens) async throws {
        guard await Self.requestAccess() else { throw CameraError.notAuthorized }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(profile: profile, lens: lens)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    // MARK: Configuración de sesión

    private func configureSession(profile: VideoProfile, lens: CameraLens) throws {
        guard let newDevice = lens.device else { throw CameraError.deviceUnavailable(lens) }
        // Se valida el formato ANTES de tocar la sesión: si falla, la lente actual sigue intacta.
        guard let format = Self.bestFormat(for: newDevice, resolution: profile.resolution, fps: profile.frameRate) else {
            throw CameraError.formatUnavailable("\(profile.resolution.label) @ \(profile.frameRate) fps")
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // El audio lo maneja AVAudioEngine (AudioCaptureEngine), no la sesión de cámara.
        session.automaticallyConfiguresApplicationAudioSession = false
        // Broadcast = Rec.709. Evitamos que la sesión active P3/HDR automáticamente.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        session.sessionPreset = .inputPriority

        // Entrada
        if input?.device != newDevice {
            if let input { session.removeInput(input) }
            let newInput: AVCaptureDeviceInput
            do { newInput = try AVCaptureDeviceInput(device: newDevice) }
            catch { throw CameraError.configurationFailed(error.localizedDescription) }
            guard session.canAddInput(newInput) else { throw CameraError.configurationFailed("canAddInput = false") }
            session.addInput(newInput)
            input = newInput
        }

        // Salida
        if !session.outputs.contains(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw CameraError.configurationFailed("canAddOutput = false") }
            session.addOutput(videoOutput)
        }

        // Formato del sensor + fps
        do {
            try newDevice.lockForConfiguration()
            newDevice.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(profile.frameRate))
            newDevice.activeVideoMinFrameDuration = frameDuration
            newDevice.activeVideoMaxFrameDuration = frameDuration
            if format.supportedColorSpaces.contains(.sRGB) { newDevice.activeColorSpace = .sRGB }
            if newDevice.isFocusModeSupported(.continuousAutoFocus) { newDevice.focusMode = .continuousAutoFocus }
            if newDevice.isExposureModeSupported(.continuousAutoExposure) { newDevice.exposureMode = .continuousAutoExposure }
            if newDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { newDevice.whiteBalanceMode = .continuousAutoWhiteBalance }
            if newDevice.isSmoothAutoFocusSupported { newDevice.isSmoothAutoFocusEnabled = true } // sin "hunting" brusco en video
            newDevice.unlockForConfiguration()
        } catch {
            throw CameraError.configurationFailed(error.localizedDescription)
        }

        // Orientación y estabilización de la conexión de video
        if let conn = videoOutput.connection(with: .video) {
            // La app está fija en landscapeRight == orientación nativa del sensor → rotación 0.
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .landscapeRight
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                // Nunca espejar la señal de programa: carteles y textos del fondo saldrían invertidos.
                conn.isVideoMirrored = false
            }
            if conn.isVideoStabilizationSupported {
                // .standard agrega ~2-3 frames de latencia; aceptable en contribución.
                conn.preferredVideoStabilizationMode = stabilizationEnabled ? .standard : .off
            }
        }

        device = newDevice
        self.profile = profile
        self.lens = lens
        capabilities = Self.capabilities(of: newDevice, fps: profile.frameRate)
    }

    /// Elige el mejor `AVCaptureDevice.Format` para resolución + fps.
    /// Preferencias: 420v (video range, niveles legales broadcast) > no binned > mayor ISO máximo.
    static func bestFormat(for device: AVCaptureDevice, resolution: VideoResolution, fps: Int) -> AVCaptureDevice.Format? {
        let target = resolution.dimensions
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let isYUV = sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let fpsOK = f.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) + 0.01 && $0.maxFrameRate >= Double(fps) - 0.01
            }
            return d.width == target.width && d.height == target.height && isYUV && fpsOK
        }
        return candidates.max { a, b in score(a) < score(b) }
    }

    private static func score(_ f: AVCaptureDevice.Format) -> Int {
        var s = 0
        if CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { s += 100 }
        if !f.isVideoBinned { s += 50 }
        s += Int(f.maxISO / 1000)
        return s
    }

    private static func capabilities(of device: AVCaptureDevice, fps: Int) -> CameraCapabilities {
        let f = device.activeFormat
        var c = CameraCapabilities()
        c.isoRange = f.minISO...f.maxISO
        let maxShutter = min(f.maxExposureDuration.seconds, 1.0 / Double(fps))
        c.shutterRange = f.minExposureDuration.seconds...max(maxShutter, f.minExposureDuration.seconds)
        c.supportsManualExposure = device.isExposureModeSupported(.custom)
        c.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
        c.supportsManualWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        let maxFps: (VideoResolution) -> Int = { res in
            let dims = res.dimensions
            return device.formats
                .filter { let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return d.width == dims.width && d.height == dims.height }
                .flatMap { $0.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate.rounded()) } }
                .max() ?? 0
        }
        c.maxFrameRate1080 = maxFps(.hd1080)
        c.maxFrameRate4K = maxFps(.uhd4K)
        c.supports4K = c.maxFrameRate4K >= 24
        return c
    }

    // MARK: Lectura de parámetros

    func readout() -> CameraReadout {
        guard let d = device else { return CameraReadout() }
        var r = CameraReadout()
        r.iso = d.iso
        r.shutterSeconds = d.exposureDuration.seconds
        r.lensPosition = d.lensPosition
        let tt = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains)
        r.kelvin = tt.temperature
        r.tint = tt.tint
        return r
    }

    // MARK: Exposición (ISO + obturación)

    /// Exposición manual. Si un parámetro es nil se conserva el valor actual del sensor,
    /// lo que permite mover solo ISO o solo shutter desde la UI.
    func setManualExposure(iso: Float?, shutterSeconds: Double?) {
        sessionQueue.async {
            guard let d = self.device, d.isExposureModeSupported(.custom) else { return }
            let f = d.activeFormat
            let isoValue = min(max(iso ?? d.iso, f.minISO), f.maxISO)
            let caps = self.capabilities
            let secs = min(max(shutterSeconds ?? d.exposureDuration.seconds, caps.shutterRange.lowerBound),
                           caps.shutterRange.upperBound)
            // Clamp en CMTime: el redondeo de Double puede caer fuera del rango y AVFoundation lanza excepción.
            let duration = CMTimeClampToRange(CMTime(seconds: secs, preferredTimescale: 1_000_000_000),
                                              range: CMTimeRangeFromTimeToTime(start: f.minExposureDuration,
                                                                               end: f.maxExposureDuration))
            self.withLock(d) { $0.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil) }
        }
    }

    func setAutoExposure() {
        sessionQueue.async {
            guard let d = self.device, d.isExposureModeSupported(.continuousAutoExposure) else { return }
            self.withLock(d) {
                $0.exposureMode = .continuousAutoExposure
                $0.setExposureTargetBias(0, completionHandler: nil)
            }
        }
    }

    // MARK: Enfoque

    /// lensPosition: 0.0 (más cerca) … 1.0 (infinito).
    func setManualFocus(lensPosition: Float) {
        sessionQueue.async {
            guard let d = self.device, d.isLockingFocusWithCustomLensPositionSupported else { return }
            self.withLock(d) { $0.setFocusModeLocked(lensPosition: min(max(lensPosition, 0), 1), completionHandler: nil) }
        }
    }

    func setAutoFocus() {
        sessionQueue.async {
            guard let d = self.device, d.isFocusModeSupported(.continuousAutoFocus) else { return }
            self.withLock(d) { $0.focusMode = .continuousAutoFocus }
        }
    }

    /// Tap-to-focus/expose. `point` en coordenadas normalizadas del frame (0,0 sup-izq; 1,1 inf-der).
    func focusAndExpose(at point: CGPoint) {
        sessionQueue.async {
            guard let d = self.device else { return }
            self.withLock(d) { dev in
                if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                    dev.focusPointOfInterest = point
                    dev.focusMode = .autoFocus
                }
                if dev.isExposurePointOfInterestSupported, dev.exposureMode != .custom,
                   dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposurePointOfInterest = point
                    dev.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    // MARK: Balance de blancos

    func setWhiteBalance(kelvin: Float, tint: Float = 0) {
        sessionQueue.async {
            guard let d = self.device, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
            let gains = Self.clamp(d.deviceWhiteBalanceGains(for: tt), max: d.maxWhiteBalanceGain)
            self.withLock(d) { $0.setWhiteBalanceModeLocked(with: gains, completionHandler: nil) }
        }
    }

    func setAutoWhiteBalance() {
        sessionQueue.async {
            guard let d = self.device, d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
            self.withLock(d) { $0.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }

    /// Las ganancias deben estar en [1, maxWhiteBalanceGain] o AVFoundation lanza excepción.
    private static func clamp(_ g: AVCaptureDevice.WhiteBalanceGains, max maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        var g = g
        g.redGain   = min(max(g.redGain, 1), maxGain)
        g.greenGain = min(max(g.greenGain, 1), maxGain)
        g.blueGain  = min(max(g.blueGain, 1), maxGain)
        return g
    }

    // MARK: Helpers

    private func withLock(_ d: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) {
        do {
            try d.lockForConfiguration()
            body(d)
            d.unlockForConfiguration()
        } catch {
            appLog.error("lockForConfiguration falló: \(error.localizedDescription)")
        }
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        appLog.error("AVCaptureSession runtime error: \(String(describing: error))")
        // Recuperación típica (p.ej. media services reset): reiniciar la sesión.
        sessionQueue.async { self.session.startRunning() }
        if let error { DispatchQueue.main.async { self.errorHandler?(error) } }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        videoHandler?(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        droppedFrames += 1
    }
}
