import Foundation
import Network
import dnssd

/// HTTP server for the remote page on the local network, advertised over Bonjour as `_musicsync._tcp` and `_http._tcp`.
/// Each request gets one response and the connection closes, except event streams, which stay open for `broadcast`.
/// All state lives on `queue`.
public final class RemoteServer: @unchecked Sendable {
    public enum Reply: Sendable {
        case response(HTTPResponse)
        /// An event stream of the device `owner`, starting with `first`.
        case events(owner: String, first: Data)
    }

    public typealias Handler = @Sendable @MainActor (HTTPRequest) async -> Reply

    static let maxConnections = 32, maxStreams = 16
    /// Time a client gets to send its request; the answer itself may take longer (a cover from a slow server).
    var requestTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "dev.cofob.musicsync.remote")
    private let port: UInt16
    private let name: String
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Open event streams in start order, with their owners.
    private var streams: [(connection: NWConnection, owner: String)] = []
    /// Connections whose request came in and is being answered.
    private var answering: Set<ObjectIdentifier> = []
    private var adverts: [DNSServiceRef] = []
    private var ping: DispatchSourceTimer?

    /// `onFailure` gets a listener error (port in use, no permission), on the main queue.
    public init(port: UInt16, name: String, handler: @escaping Handler) {
        self.port = port
        self.name = name
        self.handler = handler
        queue.setSpecific(key: Self.key, value: true)
    }

    public func start(onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            self?.stop()
            DispatchQueue.main.async { onFailure(error.localizedDescription) }
        }
        queue.sync {
            self.listener = listener
            listener.start(queue: queue)
            advertise()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 20, repeating: 20)
            timer.setEventHandler { [weak self] in self?.broadcastNow(ServerSentEvent.ping) }
            timer.resume()
            ping = timer
        }
    }

    /// Closes the listener, all connections and the Bonjour records.
    public func stop() {
        let work = { [self] in
            listener?.cancel()
            listener = nil
            ping?.cancel()
            ping = nil
            for ref in adverts { DNSServiceRefDeallocate(ref) }
            adverts = []
            for c in connections.values { c.cancel() }
            connections = [:]
            streams = []
        }
        if DispatchQueue.getSpecific(key: Self.key) != nil { work() } else { queue.sync(execute: work) }
    }

    /// Sends an event to every open stream.
    public func broadcast(_ event: Data) { queue.async { self.broadcastNow(event) } }

    /// Ends the streams of a revoked device.
    public func closeStreams(owner: String) {
        queue.async {
            for s in self.streams where s.owner == owner { s.connection.cancel() }
        }
    }

    private static let key = DispatchSpecificKey<Bool>()

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        guard Self.isLocal(c.endpoint), connections.count < Self.maxConnections else { return c.cancel() }
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(id)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, Data())
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, !answering.contains(id), !streams.contains(where: { $0.connection === c }) else { return }
            c.cancel()  // a slow or stuck client; a finished request is closed already
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
        answering.remove(id)
        streams.removeAll { ObjectIdentifier($0.connection) == id }
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            switch HTTPRequest.parse(buffer) {
            case .incomplete: if done || error != nil { c.cancel() } else { self.receive(c, buffer) }
            case .invalid(let status): self.send(.error(status), on: c)
            case .request(let request, _):
                self.answering.insert(ObjectIdentifier(c))
                let handler = self.handler
                Task {
                    let reply = await handler(request)
                    self.queue.async { self.answer(reply, head: request.method == "HEAD", on: c) }
                }
            }
        }
    }

    private func answer(_ reply: Reply, head: Bool, on c: NWConnection) {
        switch reply {
        case .response(var response):
            if head { response.body = Data() }
            send(response, on: c)
        case .events(let owner, let first):
            guard connections[ObjectIdentifier(c)] != nil else { return }
            if streams.count >= Self.maxStreams { streams.removeFirst().connection.cancel() }
            streams.append((c, owner))
            c.send(content: HTTPResponse.eventStreamHead + first, completion: .contentProcessed { if $0 != nil { c.cancel() } })
        }
    }

    private func send(_ response: HTTPResponse, on c: NWConnection) {
        c.send(content: response.data, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    private func broadcastNow(_ event: Data) {
        for s in streams {
            let c = s.connection
            c.send(content: event, completion: .contentProcessed { if $0 != nil { c.cancel() } })
        }
    }

    private static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return LocalAddress.isLocal([UInt8](a.rawValue))
        case .ipv6(let a): return LocalAddress.isLocal([UInt8](a.rawValue))
        default: return false
        }
    }

    // MARK: Bonjour

    private func advertise() {
        let path: [UInt8] = Array("path=/".utf8)
        let txt = [UInt8(path.count)] + path
        for type in ["_musicsync._tcp", "_http._tcp"] {
            var ref: DNSServiceRef?
            let status = txt.withUnsafeBytes { bytes in
                DNSServiceRegister(&ref, 0, 0, name, type, nil, nil, port.bigEndian, UInt16(bytes.count), bytes.baseAddress, nil, nil)
            }
            guard status == kDNSServiceErr_NoError, let ref else { continue }
            DNSServiceSetDispatchQueue(ref, queue)
            adverts.append(ref)
        }
    }
}
