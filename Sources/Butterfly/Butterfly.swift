import Distributed
import Logging

/// This encapsulates the ActorSystem as a networking abstraction.
public struct Butterfly: Sendable {

    let logger: Logger
    public let system: ButterflyActorSystem
    let id: ButterflyId

    public init(host: String, port: Int, logLevel: Logger.Level) async throws {
        self.logger = Logger.create(label: "Butterfly[\(host):\(port)]", logLevel: logLevel)
        self.id = ButterflyId(host: host, port: port)
        self.system = try await ButterflyActorSystem(host: host, port: port, logLevel: logLevel)
    }

    public var host: String {
        id.host
    }

    public var port: Int {
        id.port
    }

    public func boot() async throws {
        logger.trace(#function)
        try await self.system.boot()
    }

    public func background() {
        logger.trace(#function)
        Task {
            try await self.boot()
        }
    }
}
