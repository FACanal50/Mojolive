//
//  AdaptiveBitrateController.swift
//  MojoLive — Módulo 1
//
//  Control de bitrate dinámico tipo AIMD a partir de las estadísticas SRT
//  (muestras cada 1 s). Señales de congestión, en orden de severidad:
//
//   1. Bloques descartados localmente (buffer SRT lleno) o paquetes "too late
//      to send" → corte fuerte (−35 %).
//   2. Buffer de envío (msSndBuf) > 40 % de la latencia, pérdidas > 5 % o
//      RTT > 2,5 × RTT base → corte moderado (−20 %).
//   3. Enlace estable 3 s seguidos (buffer < 20 % de latencia, pérdidas < 1 %)
//      → subida suave (+8 %, mín. 150 kbps), con 4 s de espera tras un corte.
//
//  Además se respeta un techo = 75 % de la capacidad estimada por SRT.
//  Es lógica pura (sin dependencias de hardware) para poder testearla.
//

import Foundation

final class AdaptiveBitrateController {

    let minBitrate: Int
    let maxBitrate: Int
    let latencyMs: Int
    private(set) var current: Int
    private(set) var lastReason = "inicio"

    private var stableSamples = 0
    private var holdUntil: Date = .distantPast
    private var baselineRTT: Double = .infinity
    private var lastLocalDrops = 0
    private var lastSndDrops = 0

    init(minBitrate: Int, maxBitrate: Int, startBitrate: Int, latencyMs: Int) {
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.latencyMs = max(latencyMs, 120)
        self.current = min(max(startBitrate, minBitrate), maxBitrate)
    }

    /// Procesa una muestra. Devuelve el nuevo bitrate si cambió.
    func update(with s: SRTStats, now: Date = Date()) -> Int? {
        if s.rttMs > 0 { baselineRTT = min(baselineRTT, s.rttMs) }

        let newLocalDrops = s.localDrops - lastLocalDrops
        let newSndDrops = s.droppedPacketsTotal - lastSndDrops
        lastLocalDrops = s.localDrops
        lastSndDrops = s.droppedPacketsTotal

        let latency = Double(latencyMs)
        let bufferRatio = Double(s.sndBufMs) / latency
        let rttInflated = baselineRTT.isFinite && baselineRTT > 0 && s.rttMs > max(baselineRTT * 2.5, baselineRTT + 150)

        var target = current
        if newLocalDrops > 0 || newSndDrops > 0 || bufferRatio > 0.8 {
            target = Int(Double(current) * 0.65)
            lastReason = "congestión severa"
            hold(now)
        } else if bufferRatio > 0.4 || s.lossPercent > 5 || rttInflated {
            target = Int(Double(current) * 0.80)
            lastReason = bufferRatio > 0.4 ? "buffer SRT creciendo" : (s.lossPercent > 5 ? "pérdidas \(Int(s.lossPercent)) %" : "RTT en aumento")
            hold(now)
        } else if bufferRatio < 0.2 && s.lossPercent < 1 {
            stableSamples += 1
            if stableSamples >= 3 && now >= holdUntil {
                target = current + max(Int(Double(current) * 0.08), 150_000)
                lastReason = "enlace estable"
                stableSamples = 0
            }
        } else {
            stableSamples = 0
        }

        // Techo por capacidad estimada (SRT mide con packet pairs; es ruidosa → margen amplio).
        if s.bandwidthMbps > 0.5 {
            let ceiling = Int(s.bandwidthMbps * 1_000_000 * 0.75)
            if target > ceiling { target = ceiling; lastReason = "techo por capacidad" }
        }

        target = min(max(target, minBitrate), maxBitrate)
        guard target != current else { return nil }
        current = target
        return target
    }

    private func hold(_ now: Date) {
        stableSamples = 0
        holdUntil = now.addingTimeInterval(4)
    }
}
