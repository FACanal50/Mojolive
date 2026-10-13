//
//  TSMuxer.swift
//  MojoLive — Módulo 1
//
//  Multiplexor MPEG-2 Transport Stream (ISO/IEC 13818-1) mínimo y de baja
//  latencia para contribución SRT. Es el formato que esperan los receptores
//  broadcast (Haivision, Matrox, vMix, OBS, ffmpeg, Wowza, Nimble…).
//
//    PID 0x0000  PAT
//    PID 0x1000  PMT (programa 1)
//    PID 0x0100  Video H.264 (0x1B) / HEVC (0x24)  — lleva el PCR
//    PID 0x0101  Audio AAC-LC ADTS (0x0F)
//
//  • PCR derivado del reloj de host (tiempo real) en cada frame de video.
//  • PAT/PMT antes de cada keyframe y como mínimo cada 250 ms.
//  • Un PES por access unit de video y uno por frame AAC.
//  • Sin estado global: instanciar uno por sesión. NO es thread-safe:
//    llamar siempre desde la misma cola serial.
//

import Foundation
import CoreMedia

final class TSMuxer {

    static let packetSize = 188
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101
    static let pmtPID: UInt16   = 0x1000
    static let programNumber: UInt16 = 1

    /// Retardo inicial PTS-PCR (ms). Da margen al buffer del decoder (T-STD).
    static let muxDelay90k: Int64 = 63_000          // 700 ms

    /// Salida: bloques de N×188 bytes listos para enviar.
    var outputHandler: ((Data) -> Void)?

    private let videoStreamType: UInt8
    private let hasAudio: Bool
    private var continuity: [UInt16: UInt8] = [:]
    private var baseTime: CMTime?
    private var lastPSI90k: Int64?
    /// Reloj para el PCR (inyectable para tests).
    var clock: () -> CMTime = { HostClock.now }

    init(videoStreamType: UInt8, hasAudio: Bool = true) {
        self.videoStreamType = videoStreamType
        self.hasAudio = hasAudio
    }

    // MARK: Entrada de muestras

    func muxVideo(_ frame: EncodedVideoFrame) {
        if baseTime == nil {
            // El flujo siempre arranca en un IDR (con SPS/PPS) para que el receptor decodifique de inmediato.
            guard frame.isKeyframe else { return }
            baseTime = frame.dts
        }
        guard let pts = to90k(frame.pts), let dts = to90k(frame.dts) else { return }

        var out = Data(capacity: frame.data.count + frame.data.count / 180 * 4 + 3 * Self.packetSize)
        let pcr = pcr27MHz()
        if frame.isKeyframe || lastPSI90k.map({ pcr / 300 - $0 > 22_500 }) ?? true {   // 250 ms
            writePSI(into: &out)
            lastPSI90k = pcr / 300
        }
        let pes = Self.pesPacket(streamID: 0xE0, payload: frame.data, pts: pts,
                                 dts: dts != pts ? dts : nil, boundedLength: false)
        writePES(pes, pid: Self.videoPID, pcr: pcr, randomAccess: frame.isKeyframe, into: &out)
        outputHandler?(out)
    }

    func muxAudio(_ frame: EncodedAudioFrame) {
        // Hasta que no llega el primer frame de video no hay base de tiempo ni PSI:
        // el receptor necesita PAT/PMT + keyframe para arrancar.
        guard hasAudio, baseTime != nil, let pts = to90k(frame.pts) else { return }
        var out = Data(capacity: frame.adts.count + 2 * Self.packetSize)
        let pes = Self.pesPacket(streamID: 0xC0, payload: frame.adts, pts: pts, dts: nil, boundedLength: true)
        writePES(pes, pid: Self.audioPID, pcr: nil, randomAccess: true, into: &out)
        outputHandler?(out)
    }

    /// Reinicia la base de tiempo (nueva conexión SRT): el receptor arranca de cero.
    func reset() {
        baseTime = nil
        continuity.removeAll()
        lastPSI90k = nil
    }

    // MARK: Tiempo

    private func to90k(_ t: CMTime) -> Int64? {
        guard let base = baseTime, t.isValid else { return nil }
        let rel = CMTimeConvertScale(CMTimeSubtract(t, base), timescale: 90_000, method: .roundHalfAwayFromZero).value
        let v = rel + Self.muxDelay90k
        guard v >= 0 else { return nil }          // muestra anterior al inicio: se descarta
        return v & 0x1_FFFF_FFFF                   // 33 bits
    }

    /// PCR en unidades de 27 MHz = (ahora − base) del reloj de host.
    private func pcr27MHz() -> Int64 {
        guard let base = baseTime else { return 0 }
        let rel = CMTimeConvertScale(CMTimeSubtract(clock(), base), timescale: 27_000_000, method: .roundTowardNegativeInfinity).value
        return max(rel, 0) % (Int64(1 << 33) * 300)
    }

    // MARK: PES

    static func pesPacket(streamID: UInt8, payload: Data, pts: Int64, dts: Int64?, boundedLength: Bool) -> Data {
        let headerDataLength = dts == nil ? 5 : 10
        var pes = Data(capacity: payload.count + 9 + headerDataLength)
        pes.append(contentsOf: [0x00, 0x00, 0x01, streamID])
        let pesLength = 3 + headerDataLength + payload.count
        // Video: longitud 0 (no acotada, permitido solo en video). Audio: longitud real.
        let lengthField = (boundedLength && pesLength <= 0xFFFF) ? pesLength : 0
        pes.append(UInt8((lengthField >> 8) & 0xFF))
        pes.append(UInt8(lengthField & 0xFF))
        pes.append(0x84)                                  // '10' + data_alignment_indicator
        pes.append(dts == nil ? 0x80 : 0xC0)              // PTS (+DTS)
        pes.append(UInt8(headerDataLength))
        pes.append(contentsOf: timestamp(pts, prefix: dts == nil ? 0x2 : 0x3))
        if let dts { pes.append(contentsOf: timestamp(dts, prefix: 0x1)) }
        pes.append(payload)
        return pes
    }

    static func timestamp(_ t: Int64, prefix: UInt8) -> [UInt8] {
        let v = UInt64(t) & 0x1_FFFF_FFFF
        return [
            (prefix << 4) | UInt8(((v >> 30) & 0x07) << 1) | 0x01,
            UInt8((v >> 22) & 0xFF),
            UInt8(((v >> 15) & 0x7F) << 1) | 0x01,
            UInt8((v >> 7) & 0xFF),
            UInt8((v & 0x7F) << 1) | 0x01
        ]
    }

    // MARK: Paquetización TS

    private func writePES(_ pes: Data, pid: UInt16, pcr: Int64?, randomAccess: Bool, into out: inout Data) {
        pes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            var first = true
            while offset < bytes.count {
                let remaining = bytes.count - offset
                let consumed = writePacket(pid: pid, pusi: first,
                                           payload: UnsafeBufferPointer(rebasing: bytes[offset..<bytes.count]),
                                           remaining: remaining,
                                           pcr: first ? pcr : nil,
                                           randomAccess: first && randomAccess,
                                           into: &out)
                offset += consumed
                first = false
            }
        }
    }

    /// Escribe un paquete TS de 188 bytes y devuelve cuántos bytes de payload consumió.
    private func writePacket(pid: UInt16, pusi: Bool, payload: UnsafeBufferPointer<UInt8>, remaining: Int,
                             pcr: Int64?, randomAccess: Bool, into out: inout Data) -> Int {
        // Cuerpo del adaptation field (sin el byte de longitud)
        var af: [UInt8]? = nil
        if pcr != nil || randomAccess {
            var flags: UInt8 = 0
            if randomAccess { flags |= 0x40 }
            if pcr != nil { flags |= 0x10 }
            af = [flags]
            if let pcr { af! += Self.pcrBytes(pcr) }
        }
        let afTotal = af.map { 1 + $0.count } ?? 0
        let maxPayload = Self.packetSize - 4 - afTotal
        let take = min(remaining, maxPayload)
        let stuffing = maxPayload - take
        if stuffing > 0 {
            if af == nil {
                // stuffing == 1 → adaptation field de longitud 0 (solo el byte de longitud)
                af = stuffing == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
            } else {
                af! += [UInt8](repeating: 0xFF, count: stuffing)
            }
        }

        let cc = nextCC(pid)
        let afc: UInt8 = af == nil ? 0x10 : 0x30   // 01 = solo payload, 11 = AF + payload
        out.append(0x47)
        out.append((pusi ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
        out.append(UInt8(pid & 0xFF))
        out.append(afc | cc)
        if let af {
            out.append(UInt8(af.count))
            out.append(contentsOf: af)
        }
        out.append(UnsafeBufferPointer(rebasing: payload[0..<take]))
        return take
    }

    static func pcrBytes(_ pcr27: Int64) -> [UInt8] {
        let base = UInt64(pcr27 / 300) & 0x1_FFFF_FFFF
        let ext = UInt64(pcr27 % 300)
        return [
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8(((base & 0x01) << 7) | 0x7E | ((ext >> 8) & 0x01)),
            UInt8(ext & 0xFF)
        ]
    }

    private func nextCC(_ pid: UInt16) -> UInt8 {
        let cc = continuity[pid] ?? 0
        continuity[pid] = (cc + 1) & 0x0F
        return cc
    }

    // MARK: PSI (PAT / PMT)

    private func writePSI(into out: inout Data) {
        writeSection(Self.patSection(), pid: 0x0000, into: &out)
        writeSection(pmtSection(), pid: Self.pmtPID, into: &out)
    }

    private func writeSection(_ section: [UInt8], pid: UInt16, into out: inout Data) {
        var pkt: [UInt8] = [0x47, 0x40 | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF), 0x10 | nextCC(pid), 0x00] // pointer_field = 0
        pkt += section
        pkt += [UInt8](repeating: 0xFF, count: Self.packetSize - pkt.count)
        out.append(contentsOf: pkt)
    }

    static func patSection() -> [UInt8] {
        var s: [UInt8] = [
            0x00,                               // table_id PAT
            0xB0, 0x00,                         // section_syntax=1, length (se completa)
            0x00, 0x01,                         // transport_stream_id
            0xC1,                               // version 0, current_next = 1
            0x00, 0x00,                         // section_number / last_section_number
            UInt8(programNumber >> 8), UInt8(programNumber & 0xFF),
            0xE0 | UInt8((pmtPID >> 8) & 0x1F), UInt8(pmtPID & 0xFF)
        ]
        finalizeSection(&s)
        return s
    }

    func pmtSection() -> [UInt8] {
        var s: [UInt8] = [
            0x02,                               // table_id PMT
            0xB0, 0x00,
            UInt8(Self.programNumber >> 8), UInt8(Self.programNumber & 0xFF),
            0xC1, 0x00, 0x00,
            0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF),   // PCR_PID
            0xF0, 0x00                          // program_info_length = 0
        ]
        s += [videoStreamType, 0xE0 | UInt8((Self.videoPID >> 8) & 0x1F), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        if hasAudio {
            s += [0x0F, 0xE0 | UInt8((Self.audioPID >> 8) & 0x1F), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00]
        }
        Self.finalizeSection(&s)
        return s
    }

    /// Completa section_length y agrega el CRC32/MPEG-2.
    private static func finalizeSection(_ s: inout [UInt8]) {
        let length = s.count - 3 + 4                       // desde después de section_length, incluyendo CRC
        s[1] = 0xB0 | UInt8((length >> 8) & 0x0F)
        s[2] = UInt8(length & 0xFF)
        let crc = CRC32MPEG2.checksum(s)
        s += [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}

// MARK: - CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, sin reflexión, sin XOR final)

enum CRC32MPEG2 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }
}
