//
//  AudioLevelMeter.swift
//  MojoLive — Módulo 1
//
//  Medición de nivel en dBFS (pico y RMS) por canal usando Accelerate (vDSP).
//  Se calcula sobre cada buffer del tap y se acumula hasta que la UI lo pide
//  (≈30 Hz), conservando el máximo pico y el RMS energético del período.
//

import AVFoundation
import Accelerate

struct AudioLevels: Equatable {
    /// dBFS por canal (L, R). -160 = silencio digital.
    var peak: [Float] = [-160, -160]
    var rms:  [Float] = [-160, -160]
    /// true si algún sample tocó 0 dBFS (clip) en el período.
    var clipped = false

    static let silent = AudioLevels()
}

final class AudioLevelMeter {
    private var peakLinear: [Float] = [0, 0]
    private var sumSquares: [Double] = [0, 0]
    private var sampleCount = 0
    private var clipped = false
    private let lock = NSLock()

    static let floorDB: Float = -160

    /// Acumula un buffer PCM Float32 (no intercalado). Seguro para llamar desde el hilo de audio.
    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)

        var peaks: [Float] = [0, 0]
        var squares: [Double] = [0, 0]
        for ch in 0..<min(channels, 2) {
            var maxMag: Float = 0
            vDSP_maxmgv(data[ch], 1, &maxMag, frames)
            var sumSq: Float = 0
            vDSP_svesq(data[ch], 1, &sumSq, frames)
            peaks[ch] = maxMag
            squares[ch] = Double(sumSq)
        }
        // Fuente mono: se replica en ambos canales del medidor.
        if channels == 1 { peaks[1] = peaks[0]; squares[1] = squares[0] }

        lock.lock()
        for ch in 0..<2 {
            peakLinear[ch] = max(peakLinear[ch], peaks[ch])
            sumSquares[ch] += squares[ch]
        }
        sampleCount += Int(frames)
        if peaks.contains(where: { $0 >= 0.999 }) { clipped = true }
        lock.unlock()
    }

    /// Devuelve los niveles acumulados desde la última lectura y resetea.
    func read() -> AudioLevels {
        lock.lock(); defer { lock.unlock() }
        guard sampleCount > 0 else { return .silent }
        var out = AudioLevels()
        for ch in 0..<2 {
            out.peak[ch] = Self.dB(peakLinear[ch])
            out.rms[ch] = Self.dB(Float(sqrt(sumSquares[ch] / Double(sampleCount))))
        }
        out.clipped = clipped
        peakLinear = [0, 0]; sumSquares = [0, 0]; sampleCount = 0; clipped = false
        return out
    }

    static func dB(_ linear: Float) -> Float {
        linear > 0 ? max(20 * log10(linear), floorDB) : floorDB
    }
}
