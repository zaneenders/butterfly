import Distributed
import Logging
import Testing

@testable import Butterfly

@Suite
struct WebSocketTests {
    @Test func setup() throws {
        let clientSystem = WebSocketSystem(.client)
        let client = Client(actorSystem: clientSystem)
        let serverSystem = WebSocketSystem(.server)
        let remoteClient = try Client.resolve(id: client.id, using: serverSystem)
        Issue.record("Hello")
    }
}

distributed actor Client {
    typealias ActorSystem = WebSocketSystem
    init(actorSystem: WebSocketSystem) {
        self.actorSystem = actorSystem
    }
}
