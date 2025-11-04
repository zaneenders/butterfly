import Distributed
import Logging
import SystemPackage
import WebSocketSystem

#if SSL
import Configuration
#endif

func makeServerConfig(host: String, port: Int) async throws -> ServerConfig {
  #if SSL
  let config = try await ConfigReader(provider: EnvironmentVariablesProvider(environmentFilePath: ".env"))
  let keyPath: FilePath = config.string(forKey: "SSL_PRIVATE_KEY_PATH", as: FilePath.self)!
  let certPath: FilePath = config.string(forKey: "SSL_CERT_CHAIN_PATH", as: FilePath.self)!
  let serverConfig = ServerConfig(
    host: host, port: port, sslConfig: ServerSSLConfig(ip: host, certPath: certPath, keyPath: keyPath))
  #else
  let serverConfig = ServerConfig(host: host, port: port)
  #endif
  return serverConfig
}

func makeClientConfig(host: String, port: Int) async throws -> ClientConfig {
  #if SSL
  let config = try await ConfigReader(provider: EnvironmentVariablesProvider(environmentFilePath: ".env"))
  let certPath: FilePath = config.string(forKey: "SSL_CERT_CHAIN_PATH", as: FilePath.self)!
  let clientConfig = ClientConfig(
    host: host, port: port, sslConfig: ClientSSLConfig(domain: "localhost", certChainPath: certPath))
  #else
  let clientConfig = ClientConfig(host: host, port: port)
  #endif
  return clientConfig
}

distributed actor Human {
  typealias ActorSystem = WebSocketSystem
  init(actorSystem: WebSocketSystem) {
    self.actorSystem = actorSystem
  }
  var contactedLastBy: String?

  distributed func greet(_ name: String) {
    contactedLastBy = name
  }
}

distributed actor Ai {
  typealias ActorSystem = WebSocketSystem

  var human: Human? = nil
  init(actorSystem: WebSocketSystem) {
    self.actorSystem = actorSystem
  }

  distributed func hello(_ id: WebSocketActorId) throws {
    do {
      self.human = try Human.resolve(id: id, using: actorSystem.self)
      if let human {
        Task {
          try await human.greet("Ai")
        }
      }
    } catch {
      print(error)
      throw AiError.failedToResovle
    }
  }

  distributed func talk(over id: ActorSystem.ActorID) async throws {
    self.human = try Human.resolve(id: id, using: actorSystem.self)
    if let human {
      try await human.greet("Ai")
    }
  }
}

enum AiError: Error {
  case failedToResovle
}

distributed actor Backend {
  typealias ActorSystem = WebSocketSystem
  let logLevel: Logger.Level
  init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
    self.actorSystem = actorSystem
    self.logLevel = logLevel
  }

  distributed func doWork(_ work: Int) -> Int {
    testLog("Backend \(actorSystem.host) \(actorSystem.port)Received Doing work...", logLevel)
    return work
  }

  distributed func getResult(_ id: Int) -> String {
    return "\(id)"
  }
}

distributed actor Client {
  typealias ActorSystem = WebSocketSystem
  let logLevel: Logger.Level
  init(actorSystem: WebSocketSystem, logLevel: Logger.Level) {
    self.actorSystem = actorSystem
    self.logLevel = logLevel
  }

  distributed func sendResult(_ msg: String) {
    testLog("Client \(actorSystem.host) \(actorSystem.port)Received result: \(msg)", logLevel)
  }

  deinit {
    testLog("Client \(actorSystem.host) \(actorSystem.port)DEINIT", logLevel)
  }
}

func testLog(_ message: String, _ logLevel: Logger.Level) {
  if logLevel <= .debug {
    print(message)
  }
}
