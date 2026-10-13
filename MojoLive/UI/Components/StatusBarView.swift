//
//  StatusBarView.swift
//  MojoLive — Módulo 1
//
//  Barra superior de telemetría: estado AL AIRE, duración, formato, bitrate,
//  RTT, pérdidas, buffer SRT, fps reales y temperatura del equipo.
//

import SwiftUI

struct StatusBarView: View {
    @ObservedObject var vm: ProductionViewModel

    var body: some View {
        HStack(spacing: 10) {
            onAirBadge

            chip(icon: "film", "\(vm.profile.resolution.label) \(vm.profile.frameRate) · \(vm.profile.codec.rawValue)")
            chip(icon: "speedometer", String(format: "%.0f fps", vm.status.captureFPS),
                 tint: vm.status.captureFPS > 0 && vm.status.captureFPS < Double(vm.profile.frameRate) * 0.9 ? .orange : nil)

            if vm.isLive {
                let st = vm.status.stats
                chip(icon: "arrow.up.circle", String(format: "%.1f Mbps", Double(vm.status.videoBitrate) / 1_000_000))
                chip(icon: "timer", String(format: "RTT %.0f ms", st.rttMs), tint: st.rttMs > Double(vm.srtConfig.latencyMs) / 4 ? .orange : nil)
                chip(icon: "exclamationmark.arrow.triangle.2.circlepath", String(format: "%.1f %%", st.lossPercent),
                     tint: st.lossPercent > 5 ? .red : (st.lossPercent > 1 ? .orange : nil))
                chip(icon: "tray.full", "\(st.sndBufMs) ms", tint: st.sndBufMs > vm.srtConfig.latencyMs / 2 ? .red : nil)
                if st.droppedPacketsTotal > 0 {
                    chip(icon: "xmark.octagon", "drop \(st.droppedPacketsTotal)", tint: .red)
                }
            }

            Spacer(minLength: 0)

            if vm.thermal == .serious || vm.thermal == .critical {
                chip(icon: "thermometer.high", vm.thermal == .critical ? "CRÍTICO" : "CALIENTE", tint: .red)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
    }

    private var onAirBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 9, height: 9)
            Text(badgeText)
            if vm.isLive {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(vm.liveDurationText)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(vm.status.connection.isConnected ? Color.red : Color.black.opacity(0.6), in: Capsule())
    }

    private var badgeText: String {
        guard vm.isLive else { return "PREVIO" }
        switch vm.status.connection {
        case .connected: return "AL AIRE"
        case .connecting: return "CONECTANDO"
        case .listening: return "ESPERANDO"
        case .reconnecting(let n): return "RECONECTANDO \(n)"
        case .failed: return "ERROR"
        case .idle: return "PREVIO"
        }
    }

    private var badgeColor: Color {
        switch vm.status.connection {
        case .connected: return .white
        case .failed: return .red
        case .idle: return .gray
        default: return .yellow
        }
    }

    private func chip(icon: String, _ text: String, tint: Color? = nil) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((tint ?? .black).opacity(tint == nil ? 0.55 : 0.75), in: Capsule())
    }
}
