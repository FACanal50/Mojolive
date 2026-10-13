//
//  SRTConfiguration.swift
//  MojoLive — Módulo 1
//
//  Parámetros de la sesión SRT. La passphrase NO se persiste en UserDefaults:
//  se guarda en el Keychain (ver SettingsStore).
//

import Foundation

enum SRTMode: String, Codable, CaseIterable, Identifiable {
    case caller   = "Caller"     // el móvil llama al receptor (caso típico: decoder en la emisora)
    case listener = "Listener"   // el móvil escucha y el estudio se conecta a él
    var id: String { rawValue }
}

enum SRTKeyLength: Int, Codable, CaseIterable, Identifiable {
    case aes128 = 16
    case aes192 = 24
    case aes256 = 32
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .aes128: return "AES-128"
        case .aes192: return "AES-192"
        case .aes256: return "AES-256"
        }
    }
}

struct SRTConfiguration: Codable, Equatable {
    var mode: SRTMode = .caller
    /// Host o IP del receptor (Caller). En Listener se ignora y se usa `port` local.
    var host: String = "192.168.0.10"
    var port: UInt16 = 9000
    /// Latencia SRT en ms (buffer de recuperación ARQ). Regla práctica: ≥ 4 × RTT.
    var latencyMs: Int = 500
    var encryptionEnabled: Bool = false
    var keyLength: SRTKeyLength = .aes128
    /// Opcional: Stream ID (p.ej. "#!::r=live/movil01,m=publish").
    var streamID: String = ""
    /// Reintentar automáticamente si cae el enlace (solo Caller).
    var autoReconnect: Bool = true
    /// Control de bitrate dinámico según estadísticas SRT.
    var adaptiveBitrate: Bool = true

    // Passphrase: transitoria, se carga/guarda en Keychain.
    var passphrase: String = ""

    static let latencyRange: ClosedRange<Int> = 120...2000

    enum CodingKeys: String, CodingKey {
        case mode, host, port, latencyMs, encryptionEnabled, keyLength, streamID, autoReconnect, adaptiveBitrate
    }

    /// Valida la configuración antes de salir al aire. Devuelve un mensaje de error legible o nil.
    func validationError() -> String? {
        if mode == .caller && host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Ingresá la IP o el host de destino."
        }
        if port == 0 { return "Puerto inválido." }
        if !Self.latencyRange.contains(latencyMs) {
            return "La latencia debe estar entre \(Self.latencyRange.lowerBound) y \(Self.latencyRange.upperBound) ms."
        }
        if encryptionEnabled && !(10...79).contains(passphrase.count) {
            return "La passphrase SRT debe tener entre 10 y 79 caracteres."
        }
        if streamID.utf8.count > 512 {
            return "El Stream ID no puede superar 512 bytes."
        }
        return nil
    }
}
