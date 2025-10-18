import Distributed
import Logging
import Testing

@testable import WebSocketSystem

let logLevel: Logger.Level = .error
@Suite
struct WebSocketTests {

    @Test func setup() async throws {
        let host = "::1"
        let port = 7000
        // Setup networking
        let serverSystem = try await WebSocketSystem(
            .server(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        serverSystem.background()

        let clientSystem = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem.background()

        // Create actor instances and assign them to an actorsystem.
        let server = Backend(actorSystem: serverSystem)
        let client = Client(actorSystem: clientSystem)

        // Get remote references. Simulating a another computer being able to perform remote calls on another node.
        // For now the id is just the host and port of the node.
        let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
        let remoteClient = try Client.resolve(id: client.id, using: serverSystem)
        // Various remote calls that are server through the WebSocket connection.
        let id = try await serverConnection.doWork(69)
        #expect(id == 69)
        try await remoteClient.sendResult("\(id)")
        let result = try await serverConnection.getResult(id)
        #expect("\(id)" == result)

        // Takes about 1.7 seconds right now. Not great but the code is pretty crap.
        let messagesToSend = 10_000
        let count = await withTaskGroup(of: Int.self) { group in
            for c in 0..<messagesToSend {
                group.addTask {
                    let id = try? await serverConnection.doWork(c)
                    if let id {
                        if c == id {
                            return 1
                        }
                    }
                    return 0
                }
            }
            var total = 0
            for await result in group {
                total += result
            }
            return total
        }
        #expect(count == messagesToSend)
        clientSystem.shutdown()
        serverSystem.shutdown()
    }

    @Test func twoClients() async throws {
        let host = "::1"
        let port = 7001
        let serverSystem = try await WebSocketSystem(
            .server(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        serverSystem.background()

        let clientSystem = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem.background()

        // Create actor instances and assign them to an actorsystem.
        let server = Backend(actorSystem: serverSystem)

        // Get remote references. Simulating a another computer being able to perform remote calls on another node.
        // For now the id is just the host and port of the node.
        let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
        // Various remote calls that are server through the WebSocket connection.
        let id = try await serverConnection.doWork(69)
        #expect(id == 69)
        let clientSystem2 = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem2.background()
        let serverConnection2 = try Backend.resolve(id: server.id, using: clientSystem2)
        // Create actor instances and assign them to an actorsystem.
        let id2 = try await serverConnection2.doWork(69)
        #expect(id2 == id)
        let messagesToSend = 420
        let count = await withTaskGroup(of: Int.self) { group in
            for c in 0..<messagesToSend {
                group.addTask {
                    let id: Int?
                    if c.isMultiple(of: 2) {
                        id = try? await serverConnection.doWork(c)
                    } else {
                        id = try? await serverConnection2.doWork(c)
                    }
                    if let id {
                        if c == id {
                            return 1
                        }
                    }
                    return 0
                }
            }
            var total = 0
            for await result in group {
                total += result
            }
            return total
        }
        #expect(count == messagesToSend)

        clientSystem.shutdown()
        clientSystem2.shutdown()
        serverSystem.shutdown()
    }

    // TODO: Still some issues with tear down I think.
    @Test(.disabled("Websocket cleaup/reconnection problem")) func connectDisconnect() async throws
    {
        let host = "::1"
        let port = 7002
        let serverSystem = try await WebSocketSystem(
            .server(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        serverSystem.background()
        // This isn't needed i don't think.
        let server = Backend(actorSystem: serverSystem)

        let clientSystem = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem.background()
        let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
        let id = try await serverConnection.doWork(69)
        #expect(id == 69)
        clientSystem.shutdown()
        try await Task.sleep(for: .milliseconds(200))

        let clientSystem2 = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem2.background()
        let serverConnection2 = try Backend.resolve(id: server.id, using: clientSystem2)
        let id2 = try await serverConnection2.doWork(69)
        #expect(id2 == id)
        clientSystem2.shutdown()
        serverSystem.shutdown()
    }
}

distributed actor Backend {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }

    distributed func doWork(_ work: Int) -> Int {
        switch logLevel {
        case .error:
            ()
        default:
            print("Backend", actorSystem.host, actorSystem.port, "Doing work...")
        }
        return work
    }

    distributed func getResult(_ id: Int) -> String {
        return "\(id)"
    }
}

distributed actor Client {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }

    distributed func sendResult(_ msg: String) {
        switch logLevel {
        case .error:
            ()
        default:
            print("Client", actorSystem.host, actorSystem.port, "Recieved result: \(msg)")
        }
    }
}
