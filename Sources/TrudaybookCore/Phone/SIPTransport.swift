import Foundation
import Network

public enum SIPTransportKind: String, Codable, CaseIterable, Sendable {
    case udp, tcp, tls

    public var defaultPort: Int { self == .tls ? 5061 : 5060 }
    /// Как писать в Via: `SIP/2.0/UDP`.
    public var viaName: String { rawValue.uppercased() }
}

/// Адрес и порт: куда слать и откуда пришло.
public struct SIPEndpoint: Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Как SIP уходит в сеть. Всё вызывается на очереди агента.
public protocol SIPTransport: AnyObject {
    var kind: SIPTransportKind { get }
    /// Свой адрес, как его видит сеть до сервера: для Via и Contact.
    var local: SIPEndpoint? { get }
    func start(queue: DispatchQueue,
               ready: @escaping () -> Void,
               receive: @escaping (SIPMessage, SIPEndpoint?) -> Void,
               failure: @escaping (String) -> Void)
    /// `to` — для UDP ответ туда, откуда пришёл запрос; `nil` — серверу.
    func send(_ data: Data, to: SIPEndpoint?)
    func stop()
}

// MARK: - UDP

/// UDP — сокетом BSD, не `NWConnection`: соединённый UDP принимает только
/// от одного адреса, а АТС бывает отвечает с другого порта или узла.
public final class UDPTransport: SIPTransport {
    public let kind = SIPTransportKind.udp
    public private(set) var local: SIPEndpoint?
    private let server: SIPEndpoint
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    private var serverAddress: sockaddr_in?

    public init(server: SIPEndpoint) {
        self.server = server
    }

    public func start(queue: DispatchQueue, ready: @escaping () -> Void,
                      receive: @escaping (SIPMessage, SIPEndpoint?) -> Void,
                      failure: @escaping (String) -> Void) {
        guard let address = UDPSocket.resolve(server.host, port: server.port) else {
            failure(String(localized: "Сервер «\(server.host)» не найден"))
            return
        }
        serverAddress = address
        guard let socket = UDPSocket.open(port: 0) else {
            failure(String(localized: "Не открыть сетевой порт для SIP"))
            return
        }
        self.socket = socket
        let port = UDPSocket.port(of: socket) ?? 0
        local = UDPSocket.localAddress(toward: address).map { SIPEndpoint(host: $0, port: port) }
        let serverHost = UDPSocket.string(address.sin_addr)
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while let (data, from) = UDPSocket.receive(self.socket) {
                // Только от своей АТС: сканеры сети шлют INVITE на всё
                // подряд, и телефон звонил бы «призраками» без номера.
                guard from.host == serverHost else { continue }
                // Пустые и CRLF-пинги — не сообщения.
                guard data.count > 4, let message = SIPMessage.parse(data) else { continue }
                receive(message, from)
            }
        }
        source.setCancelHandler { close(socket) }
        source.resume()
        self.source = source
        ready()
    }

    public func send(_ data: Data, to endpoint: SIPEndpoint?) {
        guard socket >= 0 else { return }
        if let endpoint, let address = UDPSocket.resolve(endpoint.host, port: endpoint.port) {
            UDPSocket.send(socket, data, to: address)
        } else if let serverAddress {
            UDPSocket.send(socket, data, to: serverAddress)
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        socket = -1
    }
}

/// Мелочи сокетов BSD — общие для SIP и RTP.
public enum UDPSocket {
    /// Неблокирующий сокет UDP на всех адресах; `port` 0 — любой свободный.
    public static func open(port: Int) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    public static func port(of fd: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// Имя или адрес IPv4 → адрес сокета.
    public static func resolve(_ host: String, port: Int) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let pointer = first.pointee.ai_addr else { return nil }
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    /// Свой адрес в сторону узла: соединённый UDP-сокет без отправки —
    /// система выбирает интерфейс по таблице маршрутов.
    public static func localAddress(toward remote: sockaddr_in) -> String? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var target = remote
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return string(address.sin_addr)
    }

    static func string(_ address: in_addr) -> String {
        var copy = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    public static func send(_ fd: Int32, _ data: Data, to address: sockaddr_in) {
        var target = address
        data.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Одна датаграмма и откуда она; `nil` — ждать больше нечего.
    public static func receive(_ fd: Int32) -> (Data, SIPEndpoint)? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0 else { return nil }
        return (Data(buffer.prefix(count)), SIPEndpoint(host: string(address.sin_addr), port: Int(UInt16(bigEndian: address.sin_port))))
    }
}

// MARK: - TCP и TLS

/// TCP и TLS — через `NWConnection`. TLS — с обычной проверкой сертификата
/// системой; ослаблять её нельзя (правила приложения).
public final class StreamTransport: SIPTransport {
    public let kind: SIPTransportKind
    public private(set) var local: SIPEndpoint?
    private let server: SIPEndpoint
    private var connection: NWConnection?
    private var parser = SIPStreamParser()

    public init(server: SIPEndpoint, tls: Bool) {
        self.server = server
        kind = tls ? .tls : .tcp
    }

    public func start(queue: DispatchQueue, ready: @escaping () -> Void,
                      receive: @escaping (SIPMessage, SIPEndpoint?) -> Void,
                      failure: @escaping (String) -> Void) {
        let parameters: NWParameters = kind == .tls ? .tls : .tcp
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)) else {
            failure(String(localized: "Неверный порт сервера"))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: parameters)
        self.connection = connection
        var announced = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.localEndpoint {
                    let text: String = switch host {
                    case let .ipv4(address): "\(address)".components(separatedBy: "%").first ?? ""
                    case let .ipv6(address): "\(address)".components(separatedBy: "%").first ?? ""
                    case let .name(name, _): name
                    @unknown default: ""
                    }
                    self.local = SIPEndpoint(host: text, port: Int(port.rawValue))
                }
                guard !announced else { return }
                announced = true
                self.read(connection, receive: receive, failure: failure)
                ready()
            case let .waiting(error), let .failed(error):
                failure(error.localizedDescription)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func read(_ connection: NWConnection, receive: @escaping (SIPMessage, SIPEndpoint?) -> Void,
                      failure: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for message in self.parser.append(data) { receive(message, nil) }
            }
            if let error {
                failure(error.localizedDescription)
            } else if complete {
                failure(String(localized: "Сервер закрыл соединение"))
            } else {
                self.read(connection, receive: receive, failure: failure)
            }
        }
    }

    public func send(_ data: Data, to: SIPEndpoint?) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }
}
