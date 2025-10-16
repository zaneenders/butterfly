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
        #expect(id == 69)
        try await remoteClient.sendResult("\(id)")
        let result = try await serverConnection.getResult(id)
        #expect("\(id)" == result)

        let messagesToSend = 10_000
        let count = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<messagesToSend {
                group.addTask {
                    let id = try? await serverConnection.doWork()
                    if let id {
                        print(id)
                        return 1
                    } else {
                        return 0
                    }
                }
            }
            var total = 0
            for await result in group {
                total += result
            }
            return total
        }
        #expect(count == messagesToSend)
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
