import Distributed
import Logging
import Testing
import WebSocketSystem

@Suite
struct PublicWebSocketTests {
  let logLevel: Logger.Level = .error

  @Test func chatting() async throws {

    let host = "::1"
    let port = 8000
    let serverSystem = try await WebSocketSystem(
      .server(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    serverSystem.background()

    let clientSystem = try await WebSocketSystem(
      .client(host: host, port: port, uri: "/"), logLevel: logLevel
    )
    clientSystem.background()

    let _ai = Ai(actorSystem: serverSystem)
    let _human = Human(actorSystem: clientSystem)

    // Human connects to AI
    let ai = try Ai.resolve(id: _ai.id, using: clientSystem)
    // Says hello
    try await ai.hello(_human.id)

    try await Task.sleep(for: .milliseconds(10))
    await _human.whenLocal { h in
      // Assert response
      #expect(
        h.contactedLastBy
          == "Ai")
    }
  }

  @Test(.timeLimit(.minutes(1))) func setup() async throws {
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
    let server = Backend(actorSystem: serverSystem, logLevel: logLevel)
    let client = Client(actorSystem: clientSystem, logLevel: logLevel)

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
    let messagesToSend = 1000
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

  @Test(.timeLimit(.minutes(1))) func twoClients() async throws {
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
    let server = Backend(actorSystem: serverSystem, logLevel: logLevel)

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
}
