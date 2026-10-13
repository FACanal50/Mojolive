//
//  VUMeterView.swift
//  MojoLive — Módulo 1
//
//  Vúmetro estéreo vertical (dBFS, −60…0):
//   • Barra sólida = RMS (sonoridad percibida).
//   • Barra tenue = pico instantáneo.
//   • Línea = peak-hold.  • Indicador CLIP latcheado.
//  Zonas: verde < −18 dBFS (nivel de referencia EBU) · ámbar −18…−6 · rojo > −6.
//

import SwiftUI

struct VUMeterView: View {
    let meter: MeterBallistics
    var height: CGFloat = 220

    private let marks: [Float] = [0, -6, -12, -18, -24, -36, -48, -60]

    var body: some View {
        VStack(spacing: 4) {
            Text("CLIP")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(meter.clip ? Color.white : Color.white.opacity(0.35))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(meter.clip ? Color.red : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))

            HStack(alignment: .bottom, spacing: 3) {
                scale
                bar(channel: 0)
                bar(channel: 1)
            }
            .frame(height: height)

            HStack(spacing: 3) {
                Text("").frame(width: 18)
                Text("L").frame(width: 10)
                Text("R").frame(width: 10)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nivel de audio: izquierda \(Int(meter.rms[0])) dB, derecha \(Int(meter.rms[1])) dB")
    }

    private var scale: some View {
        GeometryReader { geo in
            ForEach(marks, id: \.self) { m in
                Text(m == 0 ? "0" : "\(Int(m))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .position(x: 9, y: geo.size.height * CGFloat(1 - Self.norm(m)))
            }
        }
        .frame(width: 18)
    }

    /// Barra dibujada con Canvas: los colores de cada zona quedan fijos en su
    /// posición de escala (no se "estiran" con el nivel) y el costo es mínimo a 30 Hz.
    private func bar(channel ch: Int) -> some View {
        Canvas { ctx, size in
            let h = size.height, w = size.width
            func y(_ db: Float) -> CGFloat { h * CGFloat(1 - Self.norm(db)) }
            let zones: [(lo: Float, hi: Float, color: Color)] = [(-60, -18, .green), (-18, -6, .yellow), (-6, 0, .red)]

            for z in zones {   // fondo tenue por zona
                ctx.fill(Path(CGRect(x: 0, y: y(z.hi), width: w, height: y(z.lo) - y(z.hi))), with: .color(z.color.opacity(0.13)))
            }
            for (level, alpha) in [(meter.peak[ch], 0.35), (meter.rms[ch], 1.0)] {
                for z in zones where level > z.lo {
                    let top = y(min(level, z.hi))
                    ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: y(z.lo) - top)), with: .color(z.color.opacity(alpha)))
                }
            }
            let holdY = y(meter.peakHold[ch])
            ctx.fill(Path(CGRect(x: 0, y: max(holdY - 1, 0), width: w, height: 2)), with: .color(Self.color(for: meter.peakHold[ch])))
        }
        .frame(width: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    static func norm(_ db: Float) -> Float {
        min(max((db - MeterBallistics.floor) / -MeterBallistics.floor, 0), 1)
    }

    static func color(for db: Float) -> Color {
        db > -6 ? .red : (db > -18 ? .yellow : .green)
    }
}
