//
//  StreamingTests.swift
//  MojoLiveTests
//
//  Tests de la lógica pura del motor de transmisión: CRC MPEG-2, ADTS,
//  paquetización TS y control de bitrate adaptativo.
//

import XCTest
import CoreMedia
@testable import MojoLive

final class StreamingTests: XCTestCase {

    // MARK: CRC32/MPEG-2

    func testCRC32MPEG2KnownVector() {
        // Vector estándar CRC-32/MPEG-2 para "123456789"
        XCTAssertEqual(CRC32MPEG2.checksum(Array("123456789".utf8)), 0x0376_E6E7)
    }

    func testPATSectionCRCValidates() {
        // Una sección PSI con su CRC al final debe dar residuo 0.
        XCTAssertEqual(CRC32MPEG2.checksum(TSMuxer.patSection()), 0)
    }

    // MARK: ADTS

    func testADTSHeader() {
        let h = ADTS.header(payloadLength: 100, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(h.count, 7)
        XCTAssertEqual(h[0], 0xFF)
        XCTAssertEqual(h[1], 0xF1)
        XCTAssertEqual(h[2], 0x4C)    // LC (01) · fs idx 3 (0011) · 0 · ch bit2 = 0
        // frame_length = 107 (13 bits repartidos en h[3..5])
        let len = (Int(h[3] & 0x03) << 11) | (Int(h[4]) << 3) | (Int(h[5]) >> 5)
        XCTAssertEqual(len, 107)
    }

    // MARK: TS

    private func makeMuxer() -> (TSMuxer, () -> Data) {
        let mux = TSMuxer(videoStreamType: 0x1B, hasAudio: true)
        var out = Data()
        mux.outputHandler = { out.append($0) }
        mux.clock = { CMTime(value: 1, timescale: 1) }
        return (mux, { out })
    }

    func testVideoPacketizationIsAlignedAndSynced() {
        let (mux, output) = makeMuxer()
        let au = Data([0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x65] + [UInt8](repeating: 0xAB, count: 5_000))
        mux.muxVideo(EncodedVideoFrame(data: au, pts: CMTime(value: 1, timescale: 1),
                                       dts: CMTime(value: 1, timescale: 1), isKeyframe: true))
        let ts = output()
        XCTAssertGreaterThan(ts.count, 0)
        XCTAssertEqual(ts.count % 188, 0)
        for i in stride(from: 0, to: ts.count, by: 188) { XCTAssertEqual(ts[i], 0x47, "sync byte en \(i)") }
        // Primer paquete = PAT (PID 0), segundo = PMT (PID 0x1000), tercero = video con PUSI + PCR
        XCTAssertEqual(ts[1] & 0x1F, 0); XCTAssertEqual(ts[2], 0)
        XCTAssertEqual(UInt16(ts[189] & 0x1F) << 8 | UInt16(ts[190]), TSMuxer.pmtPID)
        let v = 376
        XCTAssertEqual(ts[v + 1] & 0x40, 0x40)                                // PUSI
        XCTAssertEqual(UInt16(ts[v + 1] & 0x1F) << 8 | UInt16(ts[v + 2]), TSMuxer.videoPID)
        XCTAssertEqual(ts[v + 3] & 0x30, 0x30)                                // AF + payload
        XCTAssertEqual(ts[v + 5] & 0x50, 0x50)                                // random access + PCR
    }

    func testNonKeyframeBeforeFirstIDRIsDropped() {
        let (mux, output) = makeMuxer()
        mux.muxVideo(EncodedVideoFrame(data: Data([0, 0, 0, 1, 0x41, 1, 2, 3]), pts: .zero, dts: .zero, isKeyframe: false))
        XCTAssertEqual(output().count, 0)
    }

    func testContinuityCounterIncrements() {
        let (mux, output) = makeMuxer()
        for n in 0..<3 {
            let t = CMTime(value: Int64(n), timescale: 30)
            mux.muxVideo(EncodedVideoFrame(data: Data(repeating: 0x11, count: 400), pts: t, dts: t, isKeyframe: n == 0))
        }
        let ts = output()
        var last: UInt8?
        for i in stride(from: 0, to: ts.count, by: 188) {
            let pid = UInt16(ts[i + 1] & 0x1F) << 8 | UInt16(ts[i + 2])
            guard pid == TSMuxer.videoPID else { continue }
            let cc = ts[i + 3] & 0x0F
            if let last { XCTAssertEqual(cc, (last + 1) & 0x0F) }
            last = cc
        }
    }

    func testPTSEncodingRoundTrip() {
        let value: Int64 = 0x1_2345_6789 & 0x1_FFFF_FFFF
        let b = TSMuxer.timestamp(value, prefix: 0x2)
        let p0: Int64 = (Int64(b[0] >> 1) & 0x07) << 30
        let p1: Int64 = Int64(b[1]) << 22
        let p2: Int64 = Int64(b[2] >> 1) << 15
        let p3: Int64 = Int64(b[3]) << 7
        let decoded = p0 | p1 | p2 | p3 | Int64(b[4] >> 1)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(b[0] >> 4, 0x2)
    }

    // MARK: ABR

    func testABRCutsOnCongestionAndRecovers() {
        let abr = AdaptiveBitrateController(minBitrate: 1_000_000, maxBitrate: 8_000_000, startBitrate: 6_000_000, latencyMs: 500)
        var s = SRTStats()
        s.rttMs = 40
        s.sndBufMs = 300                                    // 60 % de la latencia → corte moderado
        let t0 = Date()
        XCTAssertEqual(abr.update(with: s, now: t0), 4_800_000)

        s.sndBufMs = 20                                     // enlace limpio
        var now = t0
        var rate = abr.current
        for _ in 0..<10 {
            now = now.addingTimeInterval(1)
            if let r = abr.update(with: s, now: now) { rate = r }
        }
        XCTAssertGreaterThan(rate, 4_800_000)
        XCTAssertLessThanOrEqual(rate, 8_000_000)
    }

    func testABRRespectsFloor() {
        let abr = AdaptiveBitrateController(minBitrate: 1_000_000, maxBitrate: 8_000_000, startBitrate: 1_200_000, latencyMs: 500)
        var s = SRTStats(); s.localDrops = 5
        XCTAssertEqual(abr.update(with: s), 1_000_000)
    }
}
