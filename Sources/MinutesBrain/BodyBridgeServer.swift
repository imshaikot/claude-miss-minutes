import Foundation
import MinutesCore
import Network

/// A loopback-only TCP server the Node MCP bridge calls into. One request per
/// connection, newline-delimited JSON: `{"token", "tool", "args"}` in,
/// `{"ok", "text", "image"?}` out. A per-launch random token keeps other local
/// processes from driving her.
@MainActor
public final class BodyBridgeServer {
    public typealias Handler = (_ tool: String, _ args: [String: Any], _ reply: @escaping (BodyReply) -> Void) -> Void

    public private(set) var port: UInt16?
    public let token = UUID().uuidString
    public var handler: Handler?

    private var listener: NWListener?

    public init() {}

    public func start(ready: @escaping (UInt16?) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: .any) else { ready(nil); return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        var reported = false
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard !reported else { return }
                switch state {
                case .ready:
                    reported = true
                    self?.port = listener.port?.rawValue
                    ready(listener.port?.rawValue)
                case .failed, .cancelled:
                    reported = true
                    ready(nil)
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    self?.process(buffer[buffer.startIndex..<newline], on: connection)
                } else if complete || error != nil || buffer.count > 1 << 20 {
                    connection.cancel()
                } else {
                    self?.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func process(_ line: Data, on connection: NWConnection) {
        func respond(_ reply: BodyReply) {
            connection.send(content: reply.jsonLine(), completion: .contentProcessed { _ in connection.cancel() })
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["token"] as? String == token,
              let tool = object["tool"] as? String else {
            respond(.error("Unauthorized or malformed request."))
            return
        }
        guard let handler else { respond(.error("Miss Minutes is not ready yet.")); return }
        handler(tool, object["args"] as? [String: Any] ?? [:], respond)
    }
}
