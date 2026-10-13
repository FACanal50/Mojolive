//
//  VideoEncoder.swift
//  MojoLive — Módulo 1
//
//  Encoder H.264 / HEVC por hardware (VideoToolbox) afinado para contribución
//  en vivo de baja latencia:
//   • RealTime, sin B-frames (DTS = PTS), GOP cerrado de 1–2 s.
//   • AverageBitRate + DataRateLimits (techo duro) para que el SRT no se desborde.
//   • Bitrate modificable en caliente (control adaptativo).
//   • Salida en Annex-B con AUD y SPS/PPS(/VPS) en cada keyframe → apto MPEG-TS.
//

import Foundation
import VideoToolbox
import CoreMedia

struct EncodedVideoFrame {
    let data: Data          // access unit Annex-B (start codes 00 00 00 01)
    let pts: CMTime
    let dts: CMTime
    let isKeyframe: Bool
}

enum VideoEncoderError: LocalizedError {
    case sessionCreation(OSStatus)
    var errorDescription: String? {
        switch self { case .sessionCreation(let s): return "No se pudo crear el encoder de video (\(s))." }
    }
}

final class VideoEncoder {

    var outputHandler: ((EncodedVideoFrame) -> Void)?

    private var session: VTCompressionSession?
    private var profile = VideoProfile()
    private let lock = NSLock()
    private var forceKeyframeNext = false
    /// true entre start() y stop(): evita "resucitar" el encoder fuera del aire.
    private var isActive = false
    private(set) var currentBitrate: Int = 0
    private(set) var encodedFrames = 0

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    // MARK: Ciclo de vida

    func start(profile: VideoProfile) throws {
        stop()
        self.profile = profile
        let dims = profile.resolution.dimensions

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: dims.width, height: dims.height,
                                                codecType: profile.codec.cmCodecType,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &newSession)
        guard status == noErr, let s = newSession else { throw VideoEncoderError.sessionCreation(status) }

        let gopFrames = max(Int((Double(profile.frameRate) * profile.keyframeIntervalSeconds).rounded()), 1)

        set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)        // sin B-frames
        set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopFrames as CFNumber)
        set(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, profile.keyframeIntervalSeconds as CFNumber)
        set(s, kVTCompressionPropertyKey_ExpectedFrameRate, profile.frameRate as CFNumber)
        set(s, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(s, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(s, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)

        switch profile.codec {
        case .h264:
            set(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(s, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        case .hevc:
            set(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        applyBitrate(profile.startBitrate, to: s)
        VTCompressionSessionPrepareToEncodeFrames(s)

        lock.lock()
        session = s
        isActive = true
        forceKeyframeNext = true
        encodedFrames = 0
        lock.unlock()
        appLog.info("Encoder \(profile.codec.rawValue) \(dims.width)x\(dims.height)@\(profile.frameRate) \(profile.startBitrate / 1000) kbps")
    }

    func stop() {
        lock.lock()
        let s = session
        session = nil
        isActive = false
        lock.unlock()
        if let s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    // MARK: Control

    /// Cambia el bitrate objetivo en caliente (thread-safe).
    func setBitrate(_ bps: Int) {
        lock.lock(); let s = session; lock.unlock()
        guard let s else { return }
        let clamped = min(max(bps, profile.minBitrate), profile.maxBitrate)
        guard clamped != currentBitrate else { return }
        applyBitrate(clamped, to: s)
    }

    /// Fuerza un IDR en el próximo frame (al conectar un receptor, por ejemplo).
    func requestKeyframe() {
        lock.lock(); forceKeyframeNext = true; lock.unlock()
    }

    private func applyBitrate(_ bps: Int, to s: VTCompressionSession) {
        set(s, kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        // Techo duro: 120 % del promedio en ventanas de 1 s (en BYTES por segundo).
        let bytesPerSecond = Double(bps) * 1.2 / 8.0
        set(s, kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1.0] as CFArray)
        currentBitrate = bps
    }

    private func set(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        let st = VTSessionSetProperty(s, key: key, value: value)
        if st != noErr { appLog.warning("VTSessionSetProperty \(key as String) = \(st)") }
    }

    // MARK: Codificación

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let s = session
        let forceKey = forceKeyframeNext
        forceKeyframeNext = false
        lock.unlock()
        guard let s else { return }

        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let duration = CMTime(value: 1, timescale: CMTimeScale(profile.frameRate))

        let status = VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: pts, duration: duration,
                                                     frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else { return }
            self.handleEncoded(sample)
        }
        lock.lock(); let active = isActive; lock.unlock()
        if status == kVTInvalidSessionErr, active {
            // La sesión se invalida si la app pasa a background (GPU/HW revocados). Se recrea.
            appLog.warning("Sesión de encoder inválida; recreando")
            try? start(profile: profile)
        }
    }

    private func handleEncoded(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample),
              let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return }

        let isKeyframe: Bool = {
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
                  let first = arr.first else { return true }
            return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }()

        // Bytes AVCC/HVCC (NALs con prefijo de longitud big-endian)
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        var out = Data(capacity: length + 256)
        // Access Unit Delimiter (recomendado en MPEG-TS)
        switch profile.codec {
        case .h264: out.append(contentsOf: Self.startCode + [0x09, 0xF0])
        case .hevc: out.append(contentsOf: Self.startCode + [0x46, 0x01, 0x50])
        }

        var nalLengthSize: Int32 = 4
        let paramSets = Self.parameterSets(format: format, codec: profile.codec, nalLengthSize: &nalLengthSize)
        if isKeyframe {
            for ps in paramSets { out.append(contentsOf: Self.startCode); out.append(ps) }
        }

        // AVCC → Annex-B
        let n = Int(nalLengthSize)
        var offset = 0
        avcc.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while offset + n <= length {
                var nalLen = 0
                for i in 0..<n { nalLen = (nalLen << 8) | Int(bytes[offset + i]) }
                offset += n
                guard nalLen > 0, offset + nalLen <= length else { break }
                // Se descartan AUD que pudiera emitir el encoder (ya agregamos uno).
                let header = bytes[offset]
                let isAUD = profile.codec == .h264 ? (header & 0x1F) == 9 : ((header >> 1) & 0x3F) == 35
                if !isAUD {
                    out.append(contentsOf: Self.startCode)
                    out.append(UnsafeBufferPointer(rebasing: bytes[offset..<(offset + nalLen)]))
                }
                offset += nalLen
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        encodedFrames += 1
        outputHandler?(EncodedVideoFrame(data: out, pts: pts, dts: pts, isKeyframe: isKeyframe))
    }

    /// Extrae SPS/PPS (H.264) o VPS/SPS/PPS (HEVC) del format description.
    private static func parameterSets(format: CMFormatDescription, codec: VideoCodec, nalLengthSize: inout Int32) -> [Data] {
        var count = 0
        var sets: [Data] = []
        switch codec {
        case .h264:
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize) == noErr else { return [] }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        case .hevc:
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize) == noErr else { return [] }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }
        return sets
    }
}
