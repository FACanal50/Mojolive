//
//  GraphicsPanel.swift
//  MojoLive — Módulo 1
//
//  Editor de zócalo y logo. Es un panel lateral (no una hoja modal) para que el
//  monitor de programa siga visible mientras se edita: lo que se ve es lo que sale.
//

import SwiftUI
import PhotosUI

struct GraphicsPanel: View {
    @ObservedObject var vm: ProductionViewModel
    @State private var logoItem: PhotosPickerItem?
    @FocusState private var focused: Field?

    enum Field { case name, subtitle }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Zócalo
                Text("ZÓCALO").font(.caption.bold()).foregroundStyle(.secondary)
                TextField("Nombre del entrevistado", text: $vm.graphics.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .subtitle }
                TextField("Cargo / Ubicación", text: $vm.graphics.subtitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .subtitle)
                    .submitLabel(.done)

                Button {
                    focused = nil
                    vm.toggleLowerThird()
                } label: {
                    Label(vm.graphics.showLowerThird ? "SACAR ZÓCALO" : "ZÓCALO AL AIRE",
                          systemImage: vm.graphics.showLowerThird ? "rectangle.slash" : "rectangle.bottomthird.inset.filled")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.graphics.showLowerThird ? .red : .blue)
                .disabled(vm.graphics.name.isEmpty && vm.graphics.subtitle.isEmpty)

                HStack {
                    ColorPicker("Banda", selection: colorBinding(\.primary))
                    ColorPicker("Acento", selection: colorBinding(\.accent))
                }
                .font(.caption)

                Divider()

                // Logo
                Text("LOGO DEL CANAL").font(.caption.bold()).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ZStack {
                        Checkerboard().clipShape(RoundedRectangle(cornerRadius: 6))
                        if let logo = vm.graphics.logo {
                            Image(uiImage: logo).resizable().scaledToFit().padding(4)
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 48)

                    VStack(alignment: .leading, spacing: 6) {
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            Label("Elegir PNG", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        if vm.graphics.logo != nil {
                            Button(role: .destructive) { vm.setLogo(nil) } label: { Label("Quitar", systemImage: "trash") }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                Toggle("Logo visible", isOn: $vm.graphics.showLogo)
                Picker("Posición", selection: $vm.graphics.style.logoCorner) {
                    ForEach(LogoCorner.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Tamaño").font(.caption)
                    Slider(value: $vm.graphics.style.logoScale, in: 0.05...0.20)
                }
                HStack {
                    Text("Opacidad").font(.caption)
                    Slider(value: $vm.graphics.style.logoOpacity, in: 0.3...1.0)
                }
            }
            .padding(14)
        }
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .onChange(of: logoItem) { item in
            guard let item else { return }
            Task {
                // Se cargan los bytes originales para preservar el canal alfa del PNG.
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    vm.setLogo(img)
                } else {
                    vm.errorMessage = "No se pudo cargar la imagen del logo."
                }
                logoItem = nil
            }
        }
    }

    private func colorBinding(_ kp: WritableKeyPath<LowerThirdStyle, RGBAColor>) -> Binding<Color> {
        Binding(get: { Color(vm.graphics.style[keyPath: kp].uiColor) },
                set: { vm.graphics.style[keyPath: kp] = RGBAColor(UIColor($0)) })
    }
}

/// Fondo de damero para visualizar transparencias.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.45)))
                }
            }
        }
        .background(Color.gray.opacity(0.2))
    }
}
