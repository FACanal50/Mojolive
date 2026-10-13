//
//  MojoLiveApp.swift
//  MojoLive — Contribución de video para periodismo móvil
//  Módulo 1: Cámara, UI de producción, zócalos y transmisión SRT.
//

import SwiftUI

@main
struct MojoLiveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ProductionView()
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Producción siempre en horizontal (coincide con la orientación nativa del sensor).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .landscapeRight
    }
}
