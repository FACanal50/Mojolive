//
//  VideoProfile.swift
//  MojoLive — Módulo 1
//
//  Perfil de captura + codificación de video. Es la "fuente de verdad" que
//  comparten CameraController (formato del sensor), FrameCompositor (tamaño
//  del canvas) y VideoEncoder (resolución / fps / bitrate).
//

import Foundation
import CoreMedia
import VideoToolbox

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K  = "2160p"

    var id: String { rawValue }

    var dimensions: CMVideoDimensions {
        switch self {
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        case .uhd4K:  return CMVideoDimensions(width: 3840, height: 2160)
        }
    }

    var label: String {
        switch self {
        case .hd1080: return "1080p"
        case .uhd4K:  return "4K UHD"
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }

    var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    /// stream_type de la PMT (ISO/IEC 13818-1, tabla 2-34)
    var mpegTSStreamType: UInt8 {
        switch self {
        case .h264: return 0x1B
        case .hevc: return 0x24
        }
    }
}

struct VideoProfile: Codable, Equatable {
    var resolution: VideoResolution = .hd1080
    var frameRate: Int = 30                 // 25, 30, 50 o 60
    var codec: VideoCodec = .h264
    /// Intervalo de keyframe (GOP) en segundos. 1–2 s es lo habitual en contribución.
    var keyframeIntervalSeconds: Double = 1.0

    // Bitrate de video (bits/s). El controlador adaptativo se mueve dentro de [min, max].
    var startBitrate: Int = 6_000_000
    var minBitrate: Int   = 1_000_000
    var maxBitrate: Int   = 10_000_000

    static let supportedFrameRates = [25, 30, 50, 60]

    /// Valores por defecto razonables según resolución/códec.
    static func recommended(resolution: VideoResolution, fps: Int, codec: VideoCodec) -> VideoProfile {
        var p = VideoProfile(resolution: resolution, frameRate: fps, codec: codec)
        let highFps = fps > 30
        switch (resolution, codec) {
        case (.hd1080, .h264):
            p.startBitrate = highFps ? 8_000_000 : 6_000_000
            p.maxBitrate   = highFps ? 12_000_000 : 10_000_000
            p.minBitrate   = 1_000_000
        case (.hd1080, .hevc):
            p.startBitrate = highFps ? 5_000_000 : 4_000_000
            p.maxBitrate   = highFps ? 8_000_000 : 6_000_000
            p.minBitrate   = 800_000
        case (.uhd4K, .h264):
            p.startBitrate = highFps ? 25_000_000 : 18_000_000
            p.maxBitrate   = highFps ? 35_000_000 : 25_000_000
            p.minBitrate   = 4_000_000
        case (.uhd4K, .hevc):
            p.startBitrate = highFps ? 16_000_000 : 12_000_000
            p.maxBitrate   = highFps ? 22_000_000 : 16_000_000
            p.minBitrate   = 3_000_000
        }
        return p
    }
}
