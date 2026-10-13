//
//  ProductionView.swift
//  MojoLive — Módulo 1
//
//  Pantalla principal de producción (horizontal):
//
//  ┌──────────────────────────────────────────────────────────────┐
//  │ ● AL AIRE 00:12:31  1080p30·H.264  6.0 Mbps  RTT 48 ms …     │
//  │┌──┐                                                     [CAM]│
//  ││VU│            MONITOR DE PROGRAMA (con gráfica)        [GFX]│
//  ││  │                                                     [AUD]│
//  │└──┘                                                     [SET]│
//  │                 [ ZÓCALO ]              [ ● SALIR AL AIRE ]  │
//  └──────────────────────────────────────────────────────────────┘
//

import SwiftUI

struct ProductionView: View {
    @StateObject private var vm = ProductionViewModel()
    @State private var panel: SidePanel?
    @State private var showSettings = false
    @State private var confirmStop = false

    enum SidePanel { case camera, graphics, audio }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ProgramPreviewView(sink: vm.previewSink) { point in
                vm.tapToFocus(normalized: point)
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                StatusBarView(vm: vm)
                HStack(alignment: .top, spacing: 10) {
                    VUMeterView(meter: vm.meter, height: 200)
                    Spacer()
                    if let panel {
                        sidePanel(panel)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    controlRail
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.2), value: panel)

            if !vm.isReady && vm.errorMessage == nil {
                ProgressView("Preparando cámara…").tint(.white).foregroundStyle(.white)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await vm.start() }
        .sheet(isPresented: $showSettings) { StreamSettingsView(vm: vm) }
        .alert("MojoLive", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog("¿Cortar la transmisión?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Cortar transmisión", role: .destructive) { vm.toggleLive() }
            Button("Seguir al aire", role: .cancel) {}
        }
    }

    // MARK: Paneles

    @ViewBuilder
    private func sidePanel(_ p: SidePanel) -> some View {
        switch p {
        case .camera:   ManualControlsPanel(vm: vm)
        case .graphics: GraphicsPanel(vm: vm)
        case .audio:    AudioPanel(vm: vm)
        }
    }

    private var controlRail: some View {
        VStack(spacing: 10) {
            railButton("camera.aperture", "CAM", active: panel == .camera) { toggle(.camera) }
            railButton("textformat", "GFX", active: panel == .graphics) { toggle(.graphics) }
            railButton("mic", "AUD", active: panel == .audio) { toggle(.audio) }
            railButton("gearshape", "SRT", active: false) { showSettings = true }
                .disabled(vm.isLive)
                .opacity(vm.isLive ? 0.4 : 1)
        }
    }

    private func toggle(_ p: SidePanel) { panel = (panel == p) ? nil : p }

    private func railButton(_ icon: String, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(label).font(.system(size: 9, weight: .bold))
            }
            .frame(width: 52, height: 48)
            .foregroundStyle(active ? Color.black : Color.white)
            .background(active ? Color.yellow : Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Barra inferior

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Zócalo rápido (sin abrir el panel)
            Button { vm.toggleLowerThird() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(vm.graphics.name.isEmpty ? "Sin zócalo" : vm.graphics.name).font(.caption.bold()).lineLimit(1)
                        Text(vm.graphics.showLowerThird ? "EN PANTALLA" : "OCULTO").font(.system(size: 9, weight: .heavy))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(vm.graphics.showLowerThird ? Color.blue : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(vm.graphics.name.isEmpty && vm.graphics.subtitle.isEmpty)

            Spacer()

            if case .failed(let reason) = vm.status.connection, vm.isLive {
                Text(reason).font(.caption.bold()).foregroundStyle(.white)
                    .padding(6).background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            }

            Button {
                if vm.isLive { confirmStop = true } else { vm.toggleLive() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(vm.isLive ? Color.white : Color.red).frame(width: 12, height: 12)
                    Text(vm.isLive ? "CORTAR" : "SALIR AL AIRE").font(.headline.weight(.heavy))
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(vm.isLive ? Color.red : Color.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(Color.red, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .disabled(!vm.isReady)
        }
    }
}
