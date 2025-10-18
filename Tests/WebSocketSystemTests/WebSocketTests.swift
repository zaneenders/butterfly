import Distributed
import Logging
import Testing

@testable import WebSocketSystem

@Suite(.disabled())  // TODO: Still working on concurrency bug.
struct WebSocketSystemTests {
    let logLevel: Logger.Level = .trace

    // TODO: Still some issues with tear down I think.
    @Test func connectDisconnect() async throws {
        let host = "::1"
        let port = 7002
        let serverSystem = try await WebSocketSystem(
            .server(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        serverSystem.background()
        // This isn't needed i don't think.
        let server = Backend(actorSystem: serverSystem, logLevel: logLevel)

        let clientSystem = try await WebSocketSystem(
            .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem.background()
        let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
        let id = try await serverConnection.doWork(69)
        #expect(id == 69)
        clientSystem.shutdown()

        serverSystem.lockedActors.withLock { actors in
            #expect(actors.count == 0)
        }

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
