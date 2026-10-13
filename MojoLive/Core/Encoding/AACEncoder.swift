//
//  AACEncoder.swift
//  MojoLive — Módulo 1
//
//  Encoder AAC-LC 48 kHz estéreo (AudioToolbox vía AVAudioConverter).
//  Etapas:
//    1) PCM de entrada (cualquier fs / canales: 16 kHz BT, 44.1 kHz USB, etc.)
//       → PCM Float32 48 kHz (re-muestreo + selección de 2 canales)
//    2) mono → estéreo dual-mono si corresponde
//    3) PCM 48 kHz estéreo → AAC-LC (1024 muestras/paquete) → ADTS
//
//  Los timestamps se derivan del contador de muestras a partir del primer PTS
//  (sin jitter) y se re-sincronizan si la entrada salta más de 40 ms.
//

import AVFoundation
import CoreMedia

struct EncodedAudioFrame {
    let adts: Data      // header ADTS (7 bytes) + raw AAC
    let pts: CMTime
}

final class AACEncoder {

    var outputHandler: ((EncodedAudioFrame) -> Void)?

    let sampleRate: Double = 48_000
    let channels: AVAudioChannelCount = 2
    private(set) var bitrate: Int

    private let queue = DispatchQueue(label: "mojolive.audio.encoder", qos: .userInteractive)
    private let pcmFormat: AVAudioFormat
    private let aacFormat: AVAudioFormat
    private var aacConverter: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?

    // Reloj de muestras
    private var basePTS: CMTime?
    private var samplesIn: Int64 = 0       // muestras PCM 48k entregadas al encoder desde basePTS
    private var packetsOut: Int64 = 0      // paquetes AAC emitidos desde basePTS
    /// Retardo de "priming" del encoder AAC de Apple (2112 muestras).
    private let primingSamples: Int64 = 2112

    init(bitrate: Int = 128_000) {
        self.bitrate = bitrate
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000,
                                               mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 0, mReserved: 0)
        aacFormat = AVAudioFormat(streamDescription: &asbd)!
    }

    func start() {
        queue.async {
            self.aacConverter = AVAudioConverter(from: self.pcmFormat, to: self.aacFormat)
            self.aacConverter?.bitRate = self.bitrate
            self.resampler = nil
            self.resamplerInputFormat = nil
            self.basePTS = nil
            self.samplesIn = 0
            self.packetsOut = 0
        }
    }

    func stop() {
        queue.async { self.aacConverter = nil; self.resampler = nil }
    }

    /// Thread-safe. Copia el buffer (el tap reutiliza su memoria) y encola la codificación.
    func encode(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        guard let copy = buffer.deepCopy() else { return }
        queue.async { self.process(copy, pts: pts) }
    }

    // MARK: Pipeline interno (cola serial)

    private func process(_ input: AVAudioPCMBuffer, pts: CMTime) {
        guard aacConverter != nil else { return }
        guard let pcm48 = resample(input) else { return }
        guard let stereo = makeStereo(pcm48) else { return }

        // Re-sincronización: si el PTS real se aleja del reloj de muestras > 40 ms
        // (cambio de ruta, interrupción), se reinicia la base de tiempo.
        if let base = basePTS {
            let expected = CMTimeAdd(base, CMTime(value: samplesIn, timescale: 48_000))
            if abs(CMTimeGetSeconds(CMTimeSubtract(pts, expected))) > 0.040 {
                appLog.info("AAC: resync de timestamps (\(CMTimeGetSeconds(CMTimeSubtract(pts, expected))) s)")
                aacConverter?.reset()
                basePTS = pts; samplesIn = 0; packetsOut = 0
            }
        } else {
            basePTS = pts
        }
        samplesIn += Int64(stereo.frameLength)
        encodeAAC(stereo)
    }

    /// Re-muestrea a 48 kHz Float32 conservando hasta 2 canales.
    private func resample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFmt = input.format
        let outChannels = min(inFmt.channelCount, 2)
        if inFmt.sampleRate == sampleRate, inFmt.commonFormat == .pcmFormatFloat32,
           !inFmt.isInterleaved, inFmt.channelCount <= 2 {
            return input
        }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: outChannels, interleaved: false) else { return nil }
        if resampler == nil || resamplerInputFormat != inFmt {
            resampler = AVAudioConverter(from: inFmt, to: outFmt)
            if inFmt.channelCount > 2 { resampler?.channelMap = [0, 1] }   // interfaces multicanal: in 1+2
            resampler?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            resamplerInputFormat = inFmt
        }
        guard let resampler else { return nil }
        let ratio = sampleRate / inFmt.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = resampler.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            appLog.error("Resampler: \(error?.localizedDescription ?? "?")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Mono → dual-mono estéreo (el AAC sale siempre 2.0, lo esperado por decoders broadcast).
    private func makeStereo(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 2 { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        memcpy(dst[0], src[0], bytes)
        memcpy(dst[1], src[0], bytes)
        return out
    }

    private func encodeAAC(_ pcm: AVAudioPCMBuffer) {
        guard let converter = aacConverter, let base = basePTS else { return }
        let maxPacket = converter.maximumOutputPacketSize > 0 ? converter.maximumOutputPacketSize : 1536
        var fed = false

        while true {
            let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8, maximumPacketSize: maxPacket)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if status == .error {
                appLog.error("AAC encode: \(error?.localizedDescription ?? "?")")
                return
            }
            emitPackets(out, base: base)
            // .haveData = puede haber más paquetes listos; .inputRanDry = necesita más PCM.
            if status != .haveData || out.packetCount == 0 { break }
        }
    }

    private func emitPackets(_ buffer: AVAudioCompressedBuffer, base: CMTime) {
        guard buffer.packetCount > 0, let descs = buffer.packetDescriptions else { return }
        let bytes = buffer.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(buffer.packetCount) {
            let d = descs[i]
            let size = Int(d.mDataByteSize)
            guard size > 0 else { continue }
            var frame = Data(capacity: size + 7)
            frame.append(contentsOf: ADTS.header(payloadLength: size, sampleRate: 48_000, channels: 2))
            frame.append(bytes.advanced(by: Int(d.mStartOffset)), count: size)
            // PTS del paquete n = base + (n·1024 − priming) / 48000
            let sampleIndex = packetsOut * 1024 - primingSamples
            let pts = CMTimeAdd(base, CMTime(value: sampleIndex, timescale: 48_000))
            packetsOut += 1
            outputHandler?(EncodedAudioFrame(adts: frame, pts: pts))
        }
    }
}

// MARK: - ADTS

enum ADTS {
    static let sampleRates: [Int] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Header ADTS de 7 bytes (sin CRC) para AAC-LC.
    static func header(payloadLength: Int, sampleRate: Int, channels: Int) -> [UInt8] {
        let profile = 1                                   // AAC-LC (object type 2) − 1
        let freqIndex = sampleRates.firstIndex(of: sampleRate) ?? 3
        let frameLength = payloadLength + 7
        return [
            0xFF,
            0xF1,                                         // sync + MPEG-4 + layer 0 + sin CRC
            UInt8((profile << 6) | (freqIndex << 2) | ((channels >> 2) & 0x1)),
            UInt8(((channels & 0x3) << 6) | ((frameLength >> 11) & 0x3)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x7) << 5) | 0x1F),     // + buffer fullness 0x7FF (VBR)
            0xFC
        ]
    }
}

// MARK: - Copia de buffers PCM

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
