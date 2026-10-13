//
//  ManualControlsPanel.swift
//  MojoLive — Módulo 1
//
//  Panel lateral de controles manuales de cámara: ISO, obturación, enfoque y
//  balance de blancos (Kelvin). Cada parámetro tiene modo AUTO independiente y
//  muestra el valor real del sensor mientras está en automático.
//

import SwiftUI

struct ManualControlsPanel: View {
    @ObservedObject var vm: ProductionViewModel
    @State private var tab: Tab = .iso

    enum Tab: String, CaseIterable, Identifiable {
        case iso = "ISO", shutter = "SHUTTER", focus = "FOCO", wb = "WB"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .iso:     isoControl
            case .shutter: shutterControl
            case .focus:   focusControl
            case .wb:      wbControl
            }

            lensSelector
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }

    // MARK: ISO

    private static let isoStops: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                            1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]

    private var isoValues: [Float] {
        let r = vm.capabilities.isoRange
        let v = Self.isoStops.filter { r.contains($0) }
        return v.isEmpty ? [r.lowerBound, r.upperBound] : v
    }

    private var isoControl: some View {
        let values = isoValues
        let shown = vm.exposureAuto ? vm.readout.iso : vm.manualISO
        return ControlBlock(title: "ISO", value: "\(Int(shown.rounded()))",
                            isAuto: vm.exposureAuto, autoEnabled: true,
                            supported: vm.capabilities.supportsManualExposure,
                            onAuto: { vm.setExposureAuto($0) }) {
            SteppedSlider(values: values, current: shown) { vm.setISO($0) }
            Text("Exposición AUTO controla ISO y obturación juntos.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Obturación

    private static let shutterDenominators: [Double] = [24, 25, 30, 48, 50, 60, 80, 100, 120, 125, 160, 200, 250,
                                                         320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 3200, 4000, 8000]

    private var shutterValues: [Double] {
        let r = vm.capabilities.shutterRange
        let v = Self.shutterDenominators.map { 1 / $0 }.filter { r.contains($0) }.sorted()
        return v.isEmpty ? [r.lowerBound, r.upperBound] : v
    }

    private var shutterControl: some View {
        let values = shutterValues
        let shown = vm.exposureAuto ? vm.readout.shutterSeconds : vm.manualShutter
        let ideal = 1.0 / Double(vm.profile.frameRate * 2)   // regla de 180°
        return ControlBlock(title: "OBTURACIÓN", value: Self.shutterLabel(shown),
                            isAuto: vm.exposureAuto, autoEnabled: true,
                            supported: vm.capabilities.supportsManualExposure,
                            onAuto: { vm.setExposureAuto($0) }) {
            SteppedSlider(values: values.reversed(), current: shown) { vm.setShutter($0) }
            HStack {
                Text("180° → \(Self.shutterLabel(ideal))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Aplicar 180°") { vm.setShutter(ideal) }
                    .font(.caption.bold()).buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }

    static func shutterLabel(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        return s >= 0.5 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded()))"
    }

    // MARK: Enfoque

    private var focusControl: some View {
        let shown = vm.focusAuto ? vm.readout.lensPosition : vm.manualFocus
        return ControlBlock(title: "ENFOQUE", value: String(format: "%.2f", shown),
                            isAuto: vm.focusAuto, autoEnabled: true,
                            supported: vm.capabilities.supportsManualFocus,
                            onAuto: { vm.setFocusAuto($0) }) {
            Slider(value: Binding(get: { Double(shown) }, set: { vm.setFocus(Float($0)) }), in: 0...1)
            HStack {
                Text("CERCA").font(.caption2)
                Spacer()
                Text("∞").font(.caption)
            }
            .foregroundStyle(.secondary)
            if vm.focusAuto {
                Text("Tocá la imagen para enfocar/exponer en un punto.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Balance de blancos

    private var wbControl: some View {
        let shown = vm.whiteBalanceAuto ? vm.readout.kelvin : vm.manualKelvin
        let range = vm.capabilities.kelvinRange
        return ControlBlock(title: "BALANCE DE BLANCOS", value: "\(Int((shown / 10).rounded() * 10)) K",
                            isAuto: vm.whiteBalanceAuto, autoEnabled: true,
                            supported: vm.capabilities.supportsManualWhiteBalance,
                            onAuto: { vm.setWhiteBalanceAuto($0) }) {
            Slider(value: Binding(get: { Double(min(max(shown, range.lowerBound), range.upperBound)) },
                                  set: { vm.setKelvin(Float(($0 / 50).rounded() * 50)) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            HStack(spacing: 6) {
                preset("3200", 3200, "lightbulb")
                preset("4300", 4300, "light.panel")
                preset("5600", 5600, "sun.max")
                preset("6500", 6500, "cloud")
            }
        }
    }

    private func preset(_ label: String, _ k: Float, _ symbol: String) -> some View {
        Button { vm.setKelvin(k) } label: {
            Label(label, systemImage: symbol).labelStyle(.titleAndIcon).font(.caption2.bold())
        }
        .buttonStyle(.bordered).controlSize(.mini)
    }

    // MARK: Lentes

    private var lensSelector: some View {
        HStack(spacing: 6) {
            Text("LENTE").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(vm.availableLenses) { lens in
                Button(lens.shortLabel) { Task { await vm.selectLens(lens) } }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .tint(vm.lens == lens ? Color.accentColor : Color.gray.opacity(0.4))
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Bloques reutilizables

struct ControlBlock<Content: View>: View {
    let title: String
    let value: String
    let isAuto: Bool
    let autoEnabled: Bool
    let supported: Bool
    let onAuto: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(isAuto ? Color.white.opacity(0.75) : Color.yellow)
                Toggle("AUTO", isOn: Binding(get: { isAuto }, set: onAuto))
                    .toggleStyle(.button).font(.caption.bold()).controlSize(.small)
                    .disabled(!autoEnabled || !supported)
            }
            if supported {
                content()
            } else {
                Text("Esta lente no admite control manual de este parámetro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Slider sobre una lista discreta de valores (pasos de ISO / obturación).
struct SteppedSlider<V: BinaryFloatingPoint>: View {
    let values: [V]
    let current: V
    let onChange: (V) -> Void

    var body: some View {
        let idx = nearestIndex
        Slider(value: Binding(get: { Double(idx) },
                              set: { onChange(values[min(max(Int($0.rounded()), 0), values.count - 1)]) }),
               in: 0...Double(max(values.count - 1, 1)), step: 1)
            .disabled(values.count < 2)
    }

    private var nearestIndex: Int {
        values.indices.min(by: { abs(Double(values[$0] - current)) < abs(Double(values[$1] - current)) }) ?? 0
    }
}
