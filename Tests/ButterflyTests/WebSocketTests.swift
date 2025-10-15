import Distributed
import Logging
import Testing

@testable import Butterfly

@Suite
struct WebSocketTests {
    @Test func setup() async throws {
        let serverSystem = try await WebSocketSystem(
            .server(host: "localhost", port: 7000, uri: "/"))
        let clientSystem = try await WebSocketSystem(
            .client(host: "localhost", port: 7000, uri: "/"))
        let server = Backend(actorSystem: serverSystem)
        let client = Client(actorSystem: clientSystem)
        try await Task.sleep(for: .milliseconds(100))
        let serverConnection = try Backend.resolve(id: server.id, using: clientSystem)
        let remoteClient = try Client.resolve(id: client.id, using: serverSystem)
        Issue.record("Hello")
    }
}

distributed actor Backend {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }
}

distributed actor Client {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }
}
