import Distributed
import Logging
import Testing

@testable import WebSocketSystem

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
        let id = try await serverConnection.doWork()
        try await remoteClient.sendResult("\(id)")
        let result = try await serverConnection.getResult(id)
        #expect("\(id)" == result)
    }
}

distributed actor Backend {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }

    distributed func doWork() -> Int {
        print("Backend", actorSystem.host, actorSystem.port, "Doing work...")
        return 69
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
        print("Client", actorSystem.host, actorSystem.port, "Recieved result: \(msg)")
    }
}
