//
//  SystemInfo.swift
//  MojoLive — Módulo 1
//
//  Utilidades de sistema: reloj de host, IPs locales (para modo Listener)
//  y logging unificado.
//

import Foundation
import CoreMedia
import os

let appLog = Logger(subsystem: "coop.coopmorteros.mojolive", category: "broadcast")

enum HostClock {
    /// Convierte un `mach_absolute_time` (AVAudioTime.hostTime) a CMTime en el
    /// reloj de host, que es el mismo `synchronizationClock` de AVCaptureSession.
    /// Así audio (AVAudioEngine) y video (AVCaptureSession) comparten base de tiempo.
    static func time(fromHostTime hostTime: UInt64) -> CMTime {
        CMClockMakeHostTimeFromSystemUnits(hostTime)
    }

    static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
}

enum NetworkInfo {
    /// Direcciones IPv4 de las interfaces activas (Wi-Fi en0, celular pdp_ip*, USB/Ethernet en*).
    /// Se muestran en la UI cuando el móvil está en modo Listener.
    static func localIPv4Addresses() -> [(interface: String, address: String)] {
        var result: [(interface: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append((interface: name, address: String(cString: host)))
            }
        }
        return result
    }
}
