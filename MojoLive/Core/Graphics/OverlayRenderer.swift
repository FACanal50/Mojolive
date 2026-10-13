//
//  OverlayRenderer.swift
//  MojoLive — Módulo 1
//
//  Rasteriza la capa gráfica (zócalo + logo) a CIImage. Se ejecuta SOLO cuando
//  cambia el contenido (texto, logo, estilo, resolución), nunca por frame.
//  Cada elemento se rasteriza en su propio bounding box (no a canvas completo)
//  para que la composición por frame en GPU mueva la menor cantidad de píxeles.
//
//  Layout pensado para 16:9 con márgenes "title safe" (≈ 90 %).
//

import UIKit
import CoreImage

/// Un elemento gráfico ya rasterizado y posicionado en coordenadas Core Image
/// (origen abajo-izquierda).
struct OverlayLayer {
    let image: CIImage        // ya trasladada a su posición final
    let frame: CGRect         // en coordenadas CI del canvas
}

struct RasterizedGraphics {
    var lowerThird: OverlayLayer?
    var logo: OverlayLayer?
}

enum OverlayRenderer {

    static func rasterize(_ state: GraphicsState, canvas: CGSize) -> RasterizedGraphics {
        var out = RasterizedGraphics()
        if !state.name.isEmpty || !state.subtitle.isEmpty {
            out.lowerThird = renderLowerThird(state, canvas: canvas)
        }
        if let logo = state.logo {
            out.logo = renderLogo(logo, style: state.style, canvas: canvas)
        }
        return out
    }

    // MARK: Zócalo

    private static func renderLowerThird(_ state: GraphicsState, canvas: CGSize) -> OverlayLayer? {
        let H = canvas.height, W = canvas.width
        let style = state.style

        let nameFont = UIFont.systemFont(ofSize: H * 0.046, weight: .bold)
        let subFont  = UIFont.systemFont(ofSize: H * 0.030, weight: .semibold)
        let padX = H * 0.025
        let accentW = H * 0.012
        let nameBandH = H * 0.078
        let subBandH  = state.subtitle.isEmpty ? 0 : H * 0.052
        let maxTextW  = W * 0.70

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: style.textColor.uiColor, .paragraphStyle: para]
        let subAttrs:  [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: style.textColor.uiColor, .paragraphStyle: para]

        let name = state.name.uppercased(with: Locale(identifier: "es_AR"))
        let nameW = min(ceil((name as NSString).size(withAttributes: nameAttrs).width), maxTextW)
        let subW  = min(ceil((state.subtitle as NSString).size(withAttributes: subAttrs).width), maxTextW)

        let nameBandW = max(nameW + padX * 2, W * 0.28)
        let subBandW  = state.subtitle.isEmpty ? 0 : subW + padX * 2
        let size = CGSize(width: accentW + max(nameBandW, subBandW), height: nameBandH + subBandH)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1          // 1 pt = 1 píxel del canvas de video
        format.opaque = false
        format.preferredRange = .standard
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Acento vertical
            cg.setFillColor(style.accent.uiColor.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: accentW, height: size.height))
            // Banda del nombre
            cg.setFillColor(style.primary.uiColor.cgColor)
            cg.fill(CGRect(x: accentW, y: 0, width: nameBandW, height: nameBandH))
            let nameRect = CGRect(x: accentW + padX, y: (nameBandH - nameFont.lineHeight) / 2,
                                  width: nameW, height: nameFont.lineHeight)
            (name as NSString).draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: nameAttrs, context: nil)
            // Banda del cargo / ubicación
            if subBandH > 0 {
                cg.setFillColor(style.accent.uiColor.withAlphaComponent(0.92).cgColor)
                cg.fill(CGRect(x: accentW, y: nameBandH, width: subBandW, height: subBandH))
                let subRect = CGRect(x: accentW + padX, y: nameBandH + (subBandH - subFont.lineHeight) / 2,
                                     width: subW, height: subFont.lineHeight)
                (state.subtitle as NSString).draw(with: subRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                  attributes: subAttrs, context: nil)
            }
        }
        guard let cgImage = img.cgImage else { return nil }

        // Posición: margen izquierdo 6 % W, margen inferior 9 % H (title safe).
        let originX = W * 0.06
        let originYFromBottom = H * 0.09
        let frame = CGRect(x: originX, y: originYFromBottom, width: size.width, height: size.height)
        let ci = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
        return OverlayLayer(image: ci, frame: frame)
    }

    // MARK: Logo (bug del canal)

    private static func renderLogo(_ logo: UIImage, style: LowerThirdStyle, canvas: CGSize) -> OverlayLayer? {
        let H = canvas.height, W = canvas.width
        let targetH = H * CGFloat(min(max(style.logoScale, 0.04), 0.25))
        let aspect = logo.size.width / max(logo.size.height, 1)
        let size = CGSize(width: (targetH * aspect).rounded(), height: targetH.rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            logo.draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: CGFloat(style.logoOpacity))
        }
        guard let cgImage = img.cgImage else { return nil }

        let marginX = W * 0.05, marginY = H * 0.06
        let origin: CGPoint
        switch style.logoCorner {  // coordenadas CI: y crece hacia arriba
        case .topLeft:     origin = CGPoint(x: marginX, y: H - marginY - size.height)
        case .topRight:    origin = CGPoint(x: W - marginX - size.width, y: H - marginY - size.height)
        case .bottomRight: origin = CGPoint(x: W - marginX - size.width, y: marginY)
        }
        let frame = CGRect(origin: origin, size: size)
        let ci = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        return OverlayLayer(image: ci, frame: frame)
    }
}
