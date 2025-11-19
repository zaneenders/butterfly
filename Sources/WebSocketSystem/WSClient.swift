import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import SystemPackage

enum ClientUpgradeResult {
  case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  case notUpgraded
}

enum WSClientError: Error {
  case notUpgraded
  case noCerts
}

public struct ClientConfig {
  let host: String
  let port: Int
  let uri: String
  let sslConfig: ClientSSLConfig?

  public init(host: String, port: Int, uri: String = "/", sslConfig: ClientSSLConfig? = nil) {
    self.host = host
    self.port = port
    self.uri = uri
    self.sslConfig = sslConfig
  }
}

public struct ClientSSLConfig {
  let domain: String
  let certChainPath: FilePath?

  public init(domain: String, certChainPath: FilePath?) {
    self.domain = domain
    self.certChainPath = certChainPath
  }
}

func connect(config: ClientConfig) async throws
  -> ClientUpgradeResult
{
  let sslContext: NIOSSLContext?
  let domain: String?

  if let sslConfig = config.sslConfig {
    domain = sslConfig.domain
    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    if let certChainPath = sslConfig.certChainPath {
      let caCerts = try NIOSSLCertificate.fromPEMFile(certChainPath.string)
      tlsConfig.trustRoots = .certificates(caCerts)
      tlsConfig.certificateVerification = .fullVerification
    }
    sslContext = try NIOSSLContext(configuration: tlsConfig)
  } else {
    domain = nil
    sslContext = nil
  }

  let uri = config.uri

  let upgradeResult: EventLoopFuture<ClientUpgradeResult> = try await ClientBootstrap(
    group: .singletonMultiThreadedEventLoopGroup
  )
  .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
  .connect(
    host: config.host,
    port: config.port
  ) { channel in
    channel.eventLoop.makeCompletedFuture {
      let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgradeResult>(
        upgradePipelineHandler: { (channel, _) in
          channel.eventLoop.makeCompletedFuture {
            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
              wrappingChannelSynchronously: channel
            )
            return ClientUpgradeResult.websocket(asyncChannel)
          }
        }
      )

      var headers = HTTPHeaders()
      headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
      headers.add(name: "Content-Length", value: "0")

      let requestHead = HTTPRequestHead(
        version: .http1_1,
        method: .GET,
        uri: uri,
        headers: headers
      )

      if let sslContext, let domain {
        try channel.pipeline.syncOperations.addHandler(
          try NIOSSLClientHandler(context: sslContext, serverHostname: domain)
        )
      }

      let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
        upgradeRequestHead: requestHead,
        upgraders: [upgrader],
        notUpgradingCompletionHandler: { channel in
          channel.eventLoop.makeCompletedFuture {
            ClientUpgradeResult.notUpgraded
          }
        }
      )

      let negotiationResultFuture = try channel.pipeline.syncOperations
        .configureUpgradableHTTPClientPipeline(
          configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
        )

      return negotiationResultFuture
    }
  }
  return try await upgradeResult.get()
}
