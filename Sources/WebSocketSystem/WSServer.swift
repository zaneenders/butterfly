import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import SystemPackage

enum ServerUpgradeResult {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded(WebSocketSystemError)
}

public struct ServerConfig {
  let host: String
  let port: Int
  let sslConfig: ServerSSLConfig?
  public init(host: String, port: Int, sslConfig: ServerSSLConfig? = nil) {
    self.host = host
    self.port = port
    self.sslConfig = sslConfig
  }
}

public struct ServerSSLConfig {
  let ip: String
  let tlsConfiguration: TLSConfiguration
  public init(ip: String, tlsConfiguration: TLSConfiguration) {
    self.ip = ip
    self.tlsConfiguration = tlsConfiguration
  }
}

func boot(config: ServerConfig, logger: Logger) async throws -> NIOAsyncChannel<
  EventLoopFuture<ServerUpgradeResult>, Never
> {

  let sslContext: NIOSSLContext?

  if let tls = config.sslConfig?.tlsConfiguration {
    sslContext = try NIOSSLContext(configuration: tls)
    logger.trace("SSL setup")
  } else {
    sslContext = nil
  }

  // TODO: can I remove the EventLoopFuture for an NIOAsyncChannel
  let channel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never> =
    try await ServerBootstrap(
      group: .singletonMultiThreadedEventLoopGroup
    )
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .bind(
      host: config.host,
      port: config.port
    ) { channel in
      channel.eventLoop.makeCompletedFuture {
        let upgrader = NIOTypedWebSocketServerUpgrader<ServerUpgradeResult>(
          shouldUpgrade: { (channel, head) in
            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
          },
          upgradePipelineHandler: { (channel, _) in
            channel.eventLoop.makeCompletedFuture {
              let asyncChannel = try NIOAsyncChannel<
                WebSocketFrame, WebSocketFrame
              >(
                wrappingChannelSynchronously: channel
              )
              return ServerUpgradeResult.websocket(asyncChannel)
            }
          }
        )

        if let sslContext {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSLServerHandler(context: sslContext))
        }

        let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
          upgraders: [upgrader],
          notUpgradingCompletionHandler: { channel in
            channel.eventLoop.makeCompletedFuture {
              ServerUpgradeResult.notUpgraded(
                WebSocketSystemError.message("Unable to upgrade")
              )
            }
          }
        )

        let negotiationResultFuture = try channel.pipeline.syncOperations
          .configureUpgradableHTTPServerPipeline(
            configuration: .init(upgradeConfiguration: serverUpgradeConfiguration)
          )
        return negotiationResultFuture
      }
    }
  return channel
}
