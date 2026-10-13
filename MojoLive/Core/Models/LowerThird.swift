//
//  LowerThird.swift
//  MojoLive — Módulo 1
//
//  Plantilla de zócalo (lower third) + bug de logo del canal.
//

import UIKit

struct LowerThirdStyle: Codable, Equatable {
    /// Color de la banda principal (nombre). RGBA 0–1.
    var primary: RGBAColor = RGBAColor(r: 0.05, g: 0.09, b: 0.20, a: 0.92)
    /// Color del acento lateral y de la banda secundaria.
    var accent: RGBAColor  = RGBAColor(r: 0.00, g: 0.55, b: 0.85, a: 1.00)
    var textColor: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    /// Posición del logo (bug) del canal.
    var logoCorner: LogoCorner = .topRight
    /// Tamaño del logo relativo a la altura del canvas (0.05–0.20).
    var logoScale: Double = 0.11
    var logoOpacity: Double = 0.95
}

enum LogoCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft = "Sup. izq.", topRight = "Sup. der.", bottomRight = "Inf. der."
    var id: String { rawValue }
}

struct RGBAColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
}

/// Estado completo de la capa gráfica. Es un value type: el compositor
/// recibe "snapshots" inmutables y re-rasteriza solo cuando cambia.
struct GraphicsState: Equatable {
    var name: String = ""          // Nombre del entrevistado
    var subtitle: String = ""      // Cargo / Ubicación
    var showLowerThird: Bool = false
    var showLogo: Bool = true
    var logo: UIImage? = nil       // PNG con transparencia
    var style = LowerThirdStyle()

    static func == (lhs: GraphicsState, rhs: GraphicsState) -> Bool {
        lhs.name == rhs.name && lhs.subtitle == rhs.subtitle &&
        lhs.showLowerThird == rhs.showLowerThird && lhs.showLogo == rhs.showLogo &&
        lhs.logo === rhs.logo && lhs.style == rhs.style
    }
}
