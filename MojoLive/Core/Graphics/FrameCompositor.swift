//
//  FrameCompositor.swift
//  MojoLive — Módulo 1
//
//  Composición en GPU (Core Image sobre Metal) de la capa gráfica sobre cada
//  frame de cámara, ANTES del encoder: la gráfica sale "quemada" en el SRT.
//
//  Ruta de datos (zero-copy, todo en IOSurface):
//    CVPixelBuffer 420v (cámara) ─► CIImage ─► composite(logo, zócalo) ─►
//    CVPixelBuffer 420v (pool propio) ─► VideoEncoder + Preview de programa
//
//  Cuando no hay gráfica visible ni animación en curso, el frame de cámara
//  pasa directo al encoder sin tocar la GPU (pass-through).
//

import CoreImage
import CoreVideo
import CoreMedia
import Metal
import UIKit

final class FrameCompositor {

    private let ciContext: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    private var canvas: CGSize = CGSize(width: 1920, height: 1080)
    private var fps: Double = 30

    // Estado gráfico (escrito desde main, leído en la cola de video)
    private let lock = NSLock()
    private var state = GraphicsState()
    private var raster = RasterizedGraphics()
    private let rasterQueue = DispatchQueue(label: "mojolive.graphics.raster", qos: .userInitiated)
    private var rasterGeneration = 0

    // Animaciones (solo cola de video)
    private var lowerThirdProgress: CGFloat = 0   // 0 = oculto, 1 = visible
    private var logoProgress: CGFloat = 0
    /// Duración de la transición (entrada/salida) del zócalo.
    var transitionDuration: Double = 0.35

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            // Sin gestión de color: el video ya está en Rec.709 y la gráfica se
            // compone en espacio gamma, como en un mezclador broadcast.
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(),
                .cacheIntermediates: false,
                .name: "MojoLive.Compositor"
            ])
        } else {
            ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        }
    }

    // MARK: Configuración

    func configure(width: Int, height: Int, fps: Int) {
        lock.lock()
        canvas = CGSize(width: width, height: height)
        self.fps = Double(fps)
        lock.unlock()
        rerasterize()
    }

    /// Actualiza la gráfica. Llamar desde main; la rasterización ocurre en background.
    func update(graphics: GraphicsState) {
        lock.lock()
        let changedContent = graphics.name != state.name || graphics.subtitle != state.subtitle ||
                             graphics.logo !== state.logo || graphics.style != state.style
        state = graphics
        lock.unlock()
        if changedContent { rerasterize() }
    }

    private func rerasterize() {
        lock.lock()
        rasterGeneration += 1
        let gen = rasterGeneration
        let snapshot = state
        let size = canvas
        lock.unlock()

        rasterQueue.async {
            let r = OverlayRenderer.rasterize(snapshot, canvas: size)
            self.lock.lock()
            if gen == self.rasterGeneration { self.raster = r }   // descarta rasterizaciones obsoletas
            self.lock.unlock()
        }
    }

    // MARK: Composición por frame (cola de video)

    /// Devuelve el buffer a encodear/mostrar. Puede ser el mismo de entrada (pass-through).
    func process(_ input: CVPixelBuffer) -> CVPixelBuffer {
        lock.lock()
        let r = raster
        let showLT = state.showLowerThird && r.lowerThird != nil
        let showLogo = state.showLogo && r.logo != nil
        let step = CGFloat(1.0 / max(transitionDuration * fps, 1))
        lock.unlock()

        lowerThirdProgress = approach(lowerThirdProgress, target: showLT ? 1 : 0, step: step)
        logoProgress = approach(logoProgress, target: showLogo ? 1 : 0, step: step)

        guard lowerThirdProgress > 0 || logoProgress > 0 else { return input }   // pass-through

        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard let output = makeOutputBuffer(width: width, height: height) else { return input }

        var image = CIImage(cvPixelBuffer: input)

        if logoProgress > 0, let logo = r.logo {
            image = fade(logo.image, alpha: logoProgress).composited(over: image)
        }
        if lowerThirdProgress > 0, let lt = r.lowerThird {
            // Entrada: fade + leve desplazamiento horizontal (ease-out).
            let eased = 1 - pow(1 - lowerThirdProgress, 3)
            let dx = -(1 - eased) * lt.frame.width * 0.08
            let moved = lt.image.transformed(by: CGAffineTransform(translationX: dx, y: 0))
            image = fade(moved, alpha: eased).composited(over: image)
        }

        // Copia metadatos de color (matriz YCbCr 709, primarios, transferencia) al buffer de salida.
        CVBufferPropagateAttachments(input, output)
        ciContext.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return output
    }

    private func approach(_ v: CGFloat, target: CGFloat, step: CGFloat) -> CGFloat {
        v < target ? min(v + step, target) : max(v - step, target)
    }

    /// Multiplica la opacidad de una imagen (CIColorMatrix trabaja des-premultiplicado).
    private func fade(_ image: CIImage, alpha: CGFloat) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if status != kCVReturnSuccess {
            appLog.warning("Pool de composición agotado (\(status)); frame en pass-through")
        }
        return buffer
    }
}

// MARK: - Helpers de CMSampleBuffer para la vista previa

enum SampleBufferFactory {
    /// Envuelve un CVPixelBuffer en un CMSampleBuffer marcado "display immediately"
    /// para AVSampleBufferDisplayLayer.
    static func make(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pixelBuffer,
                                                       formatDescription: format,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
