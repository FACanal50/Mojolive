//
//  SettingsStore.swift
//  MojoLive — Módulo 1
//
//  Persistencia de configuración: UserDefaults (JSON) para parámetros y
//  Keychain para la passphrase SRT. El logo se guarda como PNG en
//  Application Support para conservar el canal alfa.
//

import Foundation
import Security
import UIKit

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let srt = "mojolive.srt.v1"
        static let video = "mojolive.video.v1"
        static let style = "mojolive.lowerthird.style.v1"
        static let lastName = "mojolive.lowerthird.name"
        static let lastSubtitle = "mojolive.lowerthird.subtitle"
    }

    // MARK: SRT

    func loadSRT() -> SRTConfiguration {
        var cfg: SRTConfiguration = decode(Key.srt) ?? SRTConfiguration()
        cfg.passphrase = Keychain.read(account: "srt.passphrase") ?? ""
        return cfg
    }

    func saveSRT(_ cfg: SRTConfiguration) {
        encode(cfg, Key.srt)
        if cfg.passphrase.isEmpty {
            Keychain.delete(account: "srt.passphrase")
        } else {
            Keychain.write(cfg.passphrase, account: "srt.passphrase")
        }
    }

    // MARK: Video

    func loadVideo() -> VideoProfile { decode(Key.video) ?? VideoProfile() }
    func saveVideo(_ p: VideoProfile) { encode(p, Key.video) }

    // MARK: Gráfica

    func loadGraphics() -> GraphicsState {
        var g = GraphicsState()
        g.style = decode(Key.style) ?? LowerThirdStyle()
        g.name = defaults.string(forKey: Key.lastName) ?? ""
        g.subtitle = defaults.string(forKey: Key.lastSubtitle) ?? ""
        if let data = try? Data(contentsOf: logoURL) { g.logo = UIImage(data: data) }
        return g
    }

    func saveGraphics(_ g: GraphicsState) {
        encode(g.style, Key.style)
        defaults.set(g.name, forKey: Key.lastName)
        defaults.set(g.subtitle, forKey: Key.lastSubtitle)
    }

    /// Guarda el logo como PNG (preserva transparencia).
    func saveLogo(_ image: UIImage?) {
        if let image, let png = image.pngData() {
            try? png.write(to: logoURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: logoURL)
        }
    }

    private var logoURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("channel-logo.png")
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

// MARK: - Keychain mínimo

enum Keychain {
    private static let service = "coop.coopmorteros.mojolive"

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; attrs.forEach { add[$0.key] = $0.value }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
