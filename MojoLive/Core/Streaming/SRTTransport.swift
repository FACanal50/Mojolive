//
//  SRTTransport.swift
//  MojoLive — Módulo 1
//
//  Wrapper Swift sobre la API C oficial de Haivision SRT (libsrt).
//   • Modos Caller y Listener.
//   • Cifrado AES-128/192/256 (passphrase + PBKEYLEN).
//   • Latencia configurable (120–2000 ms), Stream ID.
//   • Reconexión automática con backoff (Caller) / vuelta a accept (Listener).
//   • Estadísticas cada 1 s (RTT, ancho de banda estimado, pérdidas,
//     retransmisiones, buffer de envío) para el control de bitrate.
//
//  Hilos:
//   - `controlQueue`: conexión/desconexión (llamadas bloqueantes de libsrt).
//   - `send(_:)`: se llama desde la cola del muxer; es no bloqueante (SRTO_SNDSYN = 0).
//

import Foundation

enum SRTConnectionState: Equatable {
    case idle
    case connecting
    case listening(port: UInt16)
    case connected(peer: String)
    case reconnecting(attempt: Int)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }

    var label: String {
        switch self {
        case .idle: return "Inactivo"
        case .connecting: return "Conectando…"
        case .listening(let p): return "Esperando conexión :\(p)"
        case .connected(let peer): return "Conectado \(peer)"
        case .reconnecting(let n): return "Reconectando (\(n))…"
        case .failed(let e): return "Error: \(e)"
        }
    }
}

struct SRTStats: Equatable {
    var rttMs: Double = 0
    var bandwidthMbps: Double = 0          // estimación de capacidad del enlace
    var sendRateMbps: Double = 0           // tasa de envío real (incluye retransmisiones)
    var sndBufMs: Int = 0                  // tiempo de datos no confirmados en el buffer de envío
    var sndBufPackets: Int = 0
    var lossPercent: Double = 0            // pérdidas en el intervalo
    var retransPercent: Double = 0
    var droppedPacketsTotal: Int = 0       // paquetes descartados por llegar tarde (≥ latencia)
    var lostPacketsTotal: Int = 0
    var sentPacketsTotal: Int64 = 0
    var localDrops: Int = 0                // bloques que no entraron en el buffer SRT
}

final class SRTTransport {

    var stateHandler: ((SRTConnectionState) -> Void)?   // main thread
    var statsHandler: ((SRTStats) -> Void)?             // main thread
    /// Se llama (en controlQueue) cada vez que se establece una conexión nueva.
    var connectedHandler: (() -> Void)?

    static let payloadSize = 1316                      // 7 × 188 (TS)

    private let controlQueue = DispatchQueue(label: "mojolive.srt.control", qos: .userInitiated)
    private let lock = NSLock()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var listenSocket: SRTSOCKET = SRT_INVALID_SOCK
    /// Socket en srt_connect() (aún no conectado). Se separa de `socket` para que
    /// send() nunca escriba en un socket a medio conectar.
    private var connectingSocket: SRTSOCKET = SRT_INVALID_SOCK
    private var config = SRTConfiguration()
    private var maxInputBitrate = 10_000_000
    private var running = false
    private var statsTimer: DispatchSourceTimer?
    private var localDrops = 0
    private var reconnectAttempt = 0

    private static let startup: Void = {
        srt_startup()
        srt_setloglevel(3)   // LOG_ERR
    }()

    init() { _ = Self.startup }

    deinit {
        // Sin publish(): no se puede capturar self en un closure durante deinit.
        statsTimer?.cancel()
        for s in [socket, connectingSocket, listenSocket] where s != SRT_INVALID_SOCK { srt_close(s) }
    }

    // MARK: API pública

    /// Inicia la sesión. `maxBitrate` (bits/s) se usa para dimensionar el overhead de retransmisión.
    func start(config: SRTConfiguration, maxBitrate: Int) {
        lock.lock()
        self.config = config
        self.maxInputBitrate = maxBitrate
        running = true
        reconnectAttempt = 0
        localDrops = 0
        lock.unlock()
        controlQueue.async { self.establish() }
    }

    func stop() {
        lock.lock()
        running = false
        let sockets = [socket, connectingSocket, listenSocket]
        socket = SRT_INVALID_SOCK
        connectingSocket = SRT_INVALID_SOCK
        listenSocket = SRT_INVALID_SOCK
        lock.unlock()
        stopStatsTimer()
        // Cerrar desbloquea srt_accept()/srt_connect() en curso en controlQueue.
        for s in sockets where s != SRT_INVALID_SOCK { srt_close(s) }
        publish(.idle)
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket != SRT_INVALID_SOCK && srt_getsockstate(socket) == SRTS_CONNECTED
    }

    /// Envía un bloque TS (múltiplo de 188). Se fragmenta en mensajes de 1316 bytes.
    /// No bloquea: si el buffer de SRT está lleno, el bloque se descarta y se cuenta.
    func send(_ data: Data) {
        lock.lock(); let s = socket; lock.unlock()
        guard s != SRT_INVALID_SOCK else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            var offset = 0
            while offset < raw.count {
                let len = min(Self.payloadSize, raw.count - offset)
                let r = srt_sendmsg2(s, base + offset, Int32(len), nil)
                if r == SRT_ERROR {
                    let code = srt_getlasterror(nil)
                    if code == Int32(SRT_EASYNCSND.rawValue) {
                        localDrops += 1          // congestión local: buffer lleno
                    } else if code == Int32(SRT_ENOCONN.rawValue) {
                        return                   // todavía no conectado: se descarta sin cortar
                    } else {
                        appLog.warning("srt_sendmsg2: \(String(cString: srt_getlasterror_str()))")
                        controlQueue.async { self.handleDisconnect(socket: s) }
                        return
                    }
                }
                offset += len
            }
        }
    }

    // MARK: Conexión

    private func establish() {
        guard isRunning else { return }
        switch config.mode {
        case .caller:   connectAsCaller()
        case .listener: acceptAsListener()
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func connectAsCaller() {
        publish(reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt))

        let s = srt_create_socket()
        guard s != SRT_INVALID_SOCK else { return fail("No se pudo crear el socket SRT") }
        if let err = applyOptions(s, isListener: false) { srt_close(s); return fail(err) }

        guard let (addr, len) = Self.resolve(host: config.host, port: config.port) else {
            srt_close(s)
            return retryOrFail("No se pudo resolver \(config.host)")
        }
        lock.lock(); connectingSocket = s; lock.unlock()

        let result = addr.withUnsafeBytes { raw in
            srt_connect(s, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), len)
        }
        lock.lock()
        let stillOurs = connectingSocket == s
        connectingSocket = SRT_INVALID_SOCK
        lock.unlock()
        guard isRunning, stillOurs else { if stillOurs { srt_close(s) }; return }   // stop() ya lo cerró

        if result == SRT_ERROR {
            let reason = Self.rejectDescription(s)
            srt_close(s)
            return retryOrFail(reason)
        }
        didConnect(s, peer: "\(config.host):\(config.port)")
    }

    private func acceptAsListener() {
        lock.lock(); var l = listenSocket; lock.unlock()
        if l == SRT_INVALID_SOCK {
            l = srt_create_socket()
            guard l != SRT_INVALID_SOCK else { return fail("No se pudo crear el socket SRT") }
            if let err = applyOptions(l, isListener: true) { srt_close(l); return fail(err) }

            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = config.port.bigEndian
            sin.sin_addr.s_addr = INADDR_ANY
            let bindResult = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    srt_bind(l, $0, Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult != SRT_ERROR else {
                let msg = String(cString: srt_getlasterror_str())
                srt_close(l)
                return fail("No se pudo abrir el puerto \(config.port): \(msg)")
            }
            guard srt_listen(l, 1) != SRT_ERROR else {
                srt_close(l); return fail("srt_listen falló")
            }
            lock.lock(); listenSocket = l; lock.unlock()
        }

        publish(.listening(port: config.port))

        var peer = sockaddr_storage()
        var peerLen = Int32(MemoryLayout<sockaddr_storage>.size)
        let s = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_accept(l, $0, &peerLen) }
        }
        guard isRunning else { if s != SRT_INVALID_SOCK { srt_close(s) }; return }
        guard s != SRT_INVALID_SOCK else {
            appLog.warning("srt_accept: \(String(cString: srt_getlasterror_str()))")
            controlQueue.asyncAfter(deadline: .now() + 0.5) { self.establish() }
            return
        }
        lock.lock(); socket = s; lock.unlock()
        didConnect(s, peer: Self.describe(peer))
    }

    private func didConnect(_ s: SRTSOCKET, peer: String) {
        lock.lock(); socket = s; lock.unlock()
        reconnectAttempt = 0
        appLog.info("SRT conectado con \(peer)")
        publish(.connected(peer: peer))
        startStatsTimer()
        connectedHandler?()
    }

    private func handleDisconnect(socket s: SRTSOCKET) {
        lock.lock()
        guard socket == s, s != SRT_INVALID_SOCK else { lock.unlock(); return }
        socket = SRT_INVALID_SOCK
        lock.unlock()
        stopStatsTimer()
        srt_close(s)
        guard isRunning else { return }
        appLog.warning("SRT: enlace perdido")
        if config.mode == .caller {
            retryOrFail("Enlace perdido")
        } else {
            establish()    // listener: volver a esperar al receptor
        }
    }

    private func retryOrFail(_ reason: String) {
        guard isRunning else { return }
        guard config.autoReconnect else { return fail(reason) }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 5.0)   // 1, 2, 4, 5, 5… s
        publish(.reconnecting(attempt: reconnectAttempt))
        appLog.info("SRT: \(reason). Reintento en \(delay) s")
        controlQueue.asyncAfter(deadline: .now() + delay) { self.establish() }
    }

    private func fail(_ reason: String) {
        lock.lock(); running = false; lock.unlock()
        publish(.failed(reason))
    }

    // MARK: Opciones de socket

    /// Devuelve un mensaje de error o nil si todo se aplicó.
    private func applyOptions(_ s: SRTSOCKET, isListener: Bool) -> String? {
        var transtype = SRTT_LIVE
        guard setOpt(s, SRTO_TRANSTYPE, &transtype, MemoryLayout<SRT_TRANSTYPE>.size) else { return "SRTO_TRANSTYPE" }

        var latency = Int32(config.latencyMs)
        guard setOpt(s, SRTO_LATENCY, &latency) else { return "SRTO_LATENCY" }

        var no: Int32 = 0                    // envío no bloqueante
        _ = setOpt(s, SRTO_SNDSYN, &no)

        var connTimeout: Int32 = 4000
        _ = setOpt(s, SRTO_CONNTIMEO, &connTimeout)

        var peerIdle: Int32 = 5000
        _ = setOpt(s, SRTO_PEERIDLETIMEO, &peerIdle)

        // Control de ancho de banda en modo live:
        // MAXBW = 0 → relativo a INPUTBW (estimado) + OHEADBW (% para retransmisiones).
        var maxBW: Int64 = 0
        _ = setOpt(s, SRTO_MAXBW, &maxBW)
        var inputBW: Int64 = 0
        _ = setOpt(s, SRTO_INPUTBW, &inputBW)
        var minInputBW = Int64(maxInputBitrate / 8)
        _ = setOpt(s, SRTO_MININPUTBW, &minInputBW)
        var overhead: Int32 = 25
        _ = setOpt(s, SRTO_OHEADBW, &overhead)

        if config.encryptionEnabled {
            var keyLen = Int32(config.keyLength.rawValue)
            guard setOpt(s, SRTO_PBKEYLEN, &keyLen) else { return "Longitud de clave inválida" }
            let pass = Array(config.passphrase.utf8)
            let ok = pass.withUnsafeBufferPointer {
                srt_setsockflag(s, SRTO_PASSPHRASE, $0.baseAddress, Int32(pass.count)) != SRT_ERROR
            }
            guard ok else { return "Passphrase inválida (10–79 caracteres)" }
        }

        if !isListener, !config.streamID.isEmpty {
            let sid = Array(config.streamID.utf8)
            _ = sid.withUnsafeBufferPointer {
                srt_setsockflag(s, SRTO_STREAMID, $0.baseAddress, Int32(sid.count))
            }
        }
        return nil
    }

    @discardableResult
    private func setOpt<T>(_ s: SRTSOCKET, _ opt: SRT_SOCKOPT, _ value: inout T, _ size: Int = MemoryLayout<T>.size) -> Bool {
        let r = srt_setsockflag(s, opt, &value, Int32(size))
        if r == SRT_ERROR {
            appLog.warning("srt_setsockflag(\(opt.rawValue)) falló: \(String(cString: srt_getlasterror_str()))")
            return false
        }
        return true
    }

    // MARK: Estadísticas

    private func startStatsTimer() {
        stopStatsTimer()
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.collectStats() }
        timer.resume()
        lock.lock(); statsTimer = timer; lock.unlock()
    }

    private func stopStatsTimer() {
        lock.lock(); let t = statsTimer; statsTimer = nil; lock.unlock()
        t?.cancel()
    }

    private func collectStats() {
        lock.lock(); let s = socket; lock.unlock()
        guard s != SRT_INVALID_SOCK else { return }

        let state = srt_getsockstate(s)
        if state == SRTS_BROKEN || state == SRTS_CLOSED || state == SRTS_NONEXIST {
            handleDisconnect(socket: s)
            return
        }

        var perf = SRT_TRACEBSTATS()
        guard srt_bstats(s, &perf, 1) != SRT_ERROR else { return }   // clear = 1 → valores por intervalo

        var st = SRTStats()
        st.rttMs = perf.msRTT
        st.bandwidthMbps = perf.mbpsBandwidth
        st.sendRateMbps = perf.mbpsSendRate
        st.sndBufMs = Int(perf.msSndBuf)
        st.sndBufPackets = Int(perf.pktSndBuf)
        let sent = max(Double(perf.pktSent), 1)
        st.lossPercent = Double(perf.pktSndLoss) / sent * 100
        st.retransPercent = Double(perf.pktRetrans) / sent * 100
        st.droppedPacketsTotal = Int(perf.pktSndDropTotal)
        st.lostPacketsTotal = Int(perf.pktSndLossTotal)
        st.sentPacketsTotal = perf.pktSentTotal
        st.localDrops = localDrops

        DispatchQueue.main.async { self.statsHandler?(st) }
    }

    // MARK: Utilidades

    private func publish(_ state: SRTConnectionState) {
        DispatchQueue.main.async { self.stateHandler?(state) }
    }

    /// Resuelve host/IP (IPv4 preferido) a sockaddr.
    private static func resolve(host: String, port: UInt16) -> (Data, Int32)? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        // Preferimos IPv4 (redes celulares con NAT64 devuelven ambas).
        var chosen = first
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            if cur.pointee.ai_family == AF_INET { chosen = cur; break }
            p = cur.pointee.ai_next
        }
        guard let addr = chosen.pointee.ai_addr else { return nil }
        let len = chosen.pointee.ai_addrlen
        return (Data(bytes: addr, count: Int(len)), Int32(len))
    }

    private static func describe(_ storage: sockaddr_storage) -> String {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let r = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t($0.pointee.sa_len), &host, socklen_t(host.count),
                            &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        return r == 0 ? "\(String(cString: host)):\(String(cString: serv))" : "peer"
    }

    private static func rejectDescription(_ s: SRTSOCKET) -> String {
        let reason = srt_getrejectreason(s)
        if reason == Int32(SRT_REJ_BADSECRET.rawValue) { return "Passphrase incorrecta" }
        if reason == Int32(SRT_REJ_UNSECURE.rawValue) { return "El receptor exige cifrado" }
        if reason != 0, let str = srt_rejectreason_str(reason) {
            let text = String(cString: str)
            if !text.isEmpty { return text }
        }
        return String(cString: srt_getlasterror_str())
    }
}
