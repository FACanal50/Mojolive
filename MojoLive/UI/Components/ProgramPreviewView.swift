//
//  ProgramPreviewView.swift
//  MojoLive — Módulo 1
//
//  Monitor de PROGRAMA: muestra exactamente lo que sale por SRT (video + gráfica
//  quemada), no la preview cruda de la cámara.
//

import SwiftUI
import AVFoundation

/// Recibe CMSampleBuffers desde la cola de video y los presenta. No es una UIView
/// para no quedar aislado al main actor.
final class PreviewSink {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        } else {
            if layer.status == .failed { layer.flush() }
            if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
        }
    }
}

final class PreviewContainerView: UIView {
    var sink: PreviewSink? {
        didSet {
            oldValue?.layer.removeFromSuperlayer()
            if let sink { layer.addSublayer(sink.layer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sink?.layer.frame = bounds
        CATransaction.commit()
    }
}

struct ProgramPreviewView: UIViewRepresentable {
    let sink: PreviewSink
    /// Tap normalizado (0…1) dentro del área de video, para tap-to-focus.
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewContainerView {
        let v = PreviewContainerView()
        v.backgroundColor = .black
        v.sink = sink
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint) -> Void)?
        init(onTap: ((CGPoint) -> Void)?) { self.onTap = onTap }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            // Rectángulo 16:9 efectivo dentro de la vista (resizeAspect).
            let b = view.bounds
            let videoAspect: CGFloat = 16.0 / 9.0
            var rect = b
            if b.width / b.height > videoAspect {
                rect.size.width = b.height * videoAspect
                rect.origin.x = (b.width - rect.width) / 2
            } else {
                rect.size.height = b.width / videoAspect
                rect.origin.y = (b.height - rect.height) / 2
            }
            let p = g.location(in: view)
            guard rect.contains(p) else { return }
            onTap?(CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
        }
    }
}
