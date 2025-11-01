import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

#if SSL
import NIOSSL
import Configuration
import SystemPackage
#endif

enum ServerUpgradeResult {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded(WebSocketSystemError)
}

func boot(host: String, port: Int, logger: Logger) async throws -> NIOAsyncChannel<
  EventLoopFuture<ServerUpgradeResult>, Never
> {
  #if SSL
  print("Server using SSL")
  let config = try await ConfigReader(
    provider: EnvironmentVariablesProvider(
      environmentFilePath: ".env",
    ))
  guard
    let certPath = config.string(forKey: "SSL_CERT_CHAIN_PATH", as: FilePath.self)?
      .description
  else {
    throw WSClientError.noCerts
  }
  guard
    let keyPath = config.string(forKey: "SSL_PRIVATE_KEY_PATH", as: FilePath.self)?
      .description
  else {
    throw WSClientError.noCerts
  }

  logger.trace("\(certPath) \(keyPath)")

  let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)

  let tlsConfiguration = TLSConfiguration.makeServerConfiguration(
    certificateChain: try NIOSSLCertificate.fromPEMFile(certPath)
      .map {
        .certificate($0)
      },
    privateKey: .privateKey(key)
  )

  logger.trace("SSL setup")
  let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
  #endif

  // TODO: can I remove the EventLoopFuture for an NIOAsyncChannel
  let channel: NIOAsyncChannel<EventLoopFuture<ServerUpgradeResult>, Never> =
    try await ServerBootstrap(
      group: .singletonMultiThreadedEventLoopGroup
    )
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .bind(
      host: host,
      port: port
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

        #if SSL
        try channel.pipeline.syncOperations.addHandler(
          NIOSSLServerHandler(context: sslContext))
        #endif

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
