//
//  AudioPanel.swift
//  MojoLive — Módulo 1
//
//  Selector de entrada de micrófono (incorporado / USB / Bluetooth / cableado)
//  y ganancia de entrada cuando el hardware la expone.
//

import SwiftUI

struct AudioPanel: View {
    @ObservedObject var vm: ProductionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ENTRADA DE AUDIO").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button { vm.refreshAudioInputs() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }

            ForEach(vm.audioInputs) { input in
                Button { vm.selectAudioInput(input) } label: {
                    HStack {
                        Image(systemName: input.kind.symbol).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(input.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(input.kind.rawValue) · \(input.channels == 1 ? "mono" : "\(input.channels) canales")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vm.currentInput?.id == input.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .padding(8)
                    .background(vm.currentInput?.id == input.id ? Color.green.opacity(0.15) : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            if vm.currentInput?.kind == .bluetooth {
                Label("Bluetooth (HFP) transmite en banda angosta (16 kHz). Para entrevistas preferí USB o cableado.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.yellow)
            }

            if vm.isGainSettable {
                HStack {
                    Text("Ganancia").font(.caption)
                    Slider(value: Binding(get: { Double(vm.inputGain) }, set: { vm.setInputGain(Float($0)) }), in: 0...1)
                    Text("\(Int(vm.inputGain * 100)) %").font(.caption.monospacedDigit()).frame(width: 44)
                }
            } else {
                Text("La ganancia de esta entrada se ajusta en el propio micrófono/interfaz.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text("Referencia: diálogo con RMS ≈ −18 dBFS y picos por debajo de −6 dBFS.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }
}
