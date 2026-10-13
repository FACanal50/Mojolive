//
//  StreamSettingsView.swift
//  MojoLive — Módulo 1
//
//  Configuración de transmisión: destino SRT, cifrado, latencia y perfil de video.
//  Se edita sobre borradores locales; nada se aplica hasta "Guardar".
//

import SwiftUI

struct StreamSettingsView: View {
    @ObservedObject var vm: ProductionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var srt = SRTConfiguration()
    @State private var video = VideoProfile()
    @State private var portText = ""
    @State private var showPassphrase = false
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            Form {
                srtSection
                encryptionSection
                videoSection
                bitrateSection
                if let validation {
                    Section { Label(validation, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Transmisión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.bold() }
            }
            .disabled(vm.isLive)
            .onAppear {
                srt = vm.srtConfig
                video = vm.profile
                portText = String(srt.port)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Secciones

    private var srtSection: some View {
        Section {
            Picker("Modo", selection: $srt.mode) {
                ForEach(SRTMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if srt.mode == .caller {
                LabeledContent("Destino") {
                    TextField("IP o host", text: $srt.host)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            LabeledContent(srt.mode == .caller ? "Puerto" : "Puerto local") {
                TextField("9000", text: $portText)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            if srt.mode == .caller {
                LabeledContent("Stream ID") {
                    TextField("opcional", text: $srt.streamID)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Latencia")
                    Spacer()
                    Text("\(srt.latencyMs) ms").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(srt.latencyMs) },
                                      set: { srt.latencyMs = Int(($0 / 10).rounded()) * 10 }),
                       in: Double(SRTConfiguration.latencyRange.lowerBound)...Double(SRTConfiguration.latencyRange.upperBound))
                HStack(spacing: 8) {
                    ForEach([120, 250, 500, 1000, 2000], id: \.self) { ms in
                        Button("\(ms)") { srt.latencyMs = ms }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            Toggle("Reconexión automática", isOn: $srt.autoReconnect)
            Toggle("Bitrate adaptativo", isOn: $srt.adaptiveBitrate)
        } header: {
            Text("SRT")
        } footer: {
            if srt.mode == .listener {
                let ips = NetworkInfo.localIPv4Addresses().map { "\($0.address) (\($0.interface))" }.joined(separator: ", ")
                Text("El receptor debe llamar a srt://\(ips.isEmpty ? "<IP del móvil>" : ips):\(portText). En redes celulares con CGNAT el modo Listener no es alcanzable desde Internet.")
            } else {
                Text("Regla práctica: latencia ≥ 4 × RTT. En 4G/5G, 800–1500 ms da margen para retransmisiones.")
            }
        }
    }

    private var encryptionSection: some View {
        Section("Cifrado") {
            Toggle("Cifrado AES", isOn: $srt.encryptionEnabled)
            if srt.encryptionEnabled {
                Picker("Clave", selection: $srt.keyLength) {
                    ForEach(SRTKeyLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Group {
                        if showPassphrase { TextField("Passphrase (10–79)", text: $srt.passphrase) }
                        else { SecureField("Passphrase (10–79)", text: $srt.passphrase) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button { showPassphrase.toggle() } label: {
                        Image(systemName: showPassphrase ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Text("\(srt.passphrase.count) caracteres · guardada en el Llavero del dispositivo")
                    .font(.caption2).foregroundStyle(srt.passphrase.count >= 10 ? Color.secondary : Color.orange)
            }
        }
    }

    private var videoSection: some View {
        Section {
            Picker("Resolución", selection: $video.resolution) {
                ForEach(VideoResolution.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            Picker("Cuadros por segundo", selection: $video.frameRate) {
                ForEach(VideoProfile.supportedFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Códec", selection: $video.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Keyframe (GOP)", selection: $video.keyframeIntervalSeconds) {
                Text("0,5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0)
            }
            Button("Usar bitrates recomendados") {
                let gop = video.keyframeIntervalSeconds
                video = .recommended(resolution: video.resolution, fps: video.frameRate, codec: video.codec)
                video.keyframeIntervalSeconds = gop
            }
        } header: {
            Text("Video")
        } footer: {
            let caps = vm.capabilities
            let max = video.resolution == .uhd4K ? caps.maxFrameRate4K : caps.maxFrameRate1080
            Text("Esta lente admite hasta \(max) fps en \(video.resolution.label). HEVC reduce ~40 % el bitrate, pero verificá que el decoder lo soporte.")
        }
    }

    private var bitrateSection: some View {
        Section("Bitrate de video") {
            bitrateRow("Inicial", value: $video.startBitrate)
            bitrateRow("Mínimo", value: $video.minBitrate)
            bitrateRow("Máximo", value: $video.maxBitrate)
        }
    }

    private func bitrateRow(_ title: String, value: Binding<Int>) -> some View {
        let upper = video.resolution == .uhd4K ? 50_000_000.0 : 20_000_000.0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f Mbps", Double(value.wrappedValue) / 1_000_000)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int(($0 / 100_000).rounded()) * 100_000 }),
                   in: 300_000...upper)
        }
    }

    // MARK: Guardar

    private func save() {
        guard let port = UInt16(portText), port > 0 else { validation = "Puerto inválido."; return }
        srt.port = port
        if let err = srt.validationError() { validation = err; return }

        // Coherencia de bitrates
        video.minBitrate = min(video.minBitrate, video.maxBitrate)
        video.startBitrate = min(max(video.startBitrate, video.minBitrate), video.maxBitrate)

        let caps = vm.capabilities
        let maxFps = video.resolution == .uhd4K ? caps.maxFrameRate4K : caps.maxFrameRate1080
        if video.frameRate > maxFps { validation = "La lente actual no soporta \(video.frameRate) fps en \(video.resolution.label)."; return }

        vm.srtConfig = srt
        SettingsStore.shared.saveSRT(srt)
        let newVideo = video
        Task {
            if newVideo != vm.profile { await vm.applyVideoProfile(newVideo) }
            dismiss()
        }
    }
}
