import Logging
import NIOCore
import NIOPosix

struct Client: Sendable {

  let host: String
  let port: Int
  let logger: Logger

  init(
    host: String, port: Int, logger: Logger
  ) {
    self.host = host
    self.port = port
    self.logger = logger
  }

  /// Create a new connection and send a single command then close down.
  func send(command: ButterflyCommand) async throws(ButterflyMessageError) -> ButterflyCommand? {
    // NOTE: This is wasteful but defers some swift-nio stuff I don't want to figure out right now.
    /*
    If we ant to send multiple messages to this client this client has to hadnle that.
    Maybe this should be an actor and you submit commands and actor wakes up if there is a command
    sends all the commands then shuts down or something.
    */
    do {
      let channel: NIOAsyncChannel<ButterflyCommand, ButterflyCommand> = try await Client.connect(
        host: host, port: port, logger: logger)
      return try await channel.executeThenClose {
        inbound,
        outbound in
        try await outbound.write(command)
        for try await cmd in inbound {
          return cmd
        }
        return nil  // return nil for void functions
      }
    } catch let scribe_error as ButterflyMessageError {
      throw scribe_error
    } catch {
      throw ButterflyMessageError.networking("\(error)")
    }
  }

  private static func connect(
    host: String, port: Int, logger: Logger
  ) async throws(ButterflyMessageError)
    -> NIOAsyncChannel<ButterflyCommand, ButterflyCommand>
  {
    let group: MultiThreadedEventLoopGroup = .singleton
    let bootstrap: NIOAsyncChannel<ButterflyCommand, ButterflyCommand>
    do {
      bootstrap = try await ClientBootstrap(group: group)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .connect(host: host, port: port) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
              ByteToMessageHandler(BufferCoder(logger: logger)))
            try channel.pipeline.syncOperations.addHandler(
              MessageToByteHandler(BufferCoder(logger: logger)))
            return try NIOAsyncChannel(
              wrappingChannelSynchronously: channel,
              configuration: NIOAsyncChannel.Configuration(
                inboundType: ButterflyCommand.self,
                outboundType: ButterflyCommand.self
              )
            )
          }
        }
    } catch {
      throw ButterflyMessageError.networking("\(error)")
    }
    return bootstrap
  }
}
