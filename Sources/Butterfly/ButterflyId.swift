public struct ButterflyId: Hashable, Sendable, Equatable, Codable {

    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    package var id: String {
        ButterflyId.makeId(host, port)
    }

    static func makeId(_ host: String, _ port: Int) -> String {
        "\(host):\(port)"
    }

    public static func == (lhs: ButterflyId, rhs: ButterflyId) -> Bool {
        return lhs.host == rhs.host && lhs.port == rhs.port
    }
}
