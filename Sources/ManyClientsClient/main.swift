import Distributed
import Foundation
import Logging
import TestWorker
import WebSocketSystem

@main
struct ManyClientsClient {
  static func main() async {
    let logLevel: Logger.Level = .warning
    let host = "::1"
    let port = 8002
    let numClients = 200

    print("Connecting \(numClients) clients to server...")
    do {
      // First, connect one client to get the server actor
      let firstClientSystem = try await WebSocketSystem(
        .client(host: host, port: port, uri: "/"), logLevel: logLevel
      )
      firstClientSystem.background()

      // Assume server actor ID is known or discover it
      let serverId = WebSocketActorId(host: host, port: port)
      let server = try TestWorker.resolve(id: serverId, using: firstClientSystem)

      print("Creating \(numClients) client systems...")
      var clientSystems: [WebSocketSystem] = [firstClientSystem]
      var serverConnections: [TestWorker] = [server]

      for i in 1..<numClients {
        if i % 50 == 0 { print("Created \(i) clients...") }
        let clientSystem = try await WebSocketSystem(
          .client(host: host, port: port, uri: "/"), logLevel: logLevel
        )
        clientSystem.background()
        clientSystems.append(clientSystem)
        let serverConnection = try TestWorker.resolve(id: serverId, using: clientSystem)
        serverConnections.append(serverConnection)
        // Test initial call
        let response = try await serverConnection.doWork(i)
        assert(response == i)
      }
      print("All clients created and initial calls completed.")
      let connections = serverConnections

      let messagesToSend = 100_000
      print("Sending \(messagesToSend) messages across \(numClients) clients...")
      let count = await withTaskGroup(of: Int.self) { group in
        let sendStart = ContinuousClock.now
        for c in 0..<messagesToSend {
          if c % 10000 == 0 { print("Sent \(c) messages...") }
          let clientIndex = c % numClients
          group.addTask {
            let id = try? await connections[clientIndex].doWork(c)
            if let id, id == c {
              return 1
            }
            return 0
          }
        }
        let sendStop = ContinuousClock.now
        print("send time: \(sendStop - sendStart)")
        var total = 0
        for await result in group {
          total += result
        }
        let end = ContinuousClock.now
        print("recieve time: \(end - sendStop)")
        return total
      }
      print("All messages sent. Successful: \(count)/\(messagesToSend)")

      print("Shutting down client systems...")
      for clientSystem in clientSystems {
        clientSystem.shutdown()
      }
    } catch {
      print("Error: \(error)")
    }
  }
}
