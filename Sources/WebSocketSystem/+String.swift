import AsyncDNSResolver
import RegexBuilder

extension String {
  package func resolveToIP() async throws -> String {
    // TODO regex
    let ipv6Splits = self.split(separator: ":")
    if ipv6Splits.count > 2 {
      // IPV6 address?
      return self
    }
    let ipv4Splits = self.split(separator: ".")
    if ipv4Splits.count == 3 {
      // IpV4 address
      let ipv4 = IPAddress.IPv4(address: self)
      return ipv4.address
    }
    let resolver = try AsyncDNSResolver()
    let aRecords = try await resolver.queryA(name: self)
    let record = aRecords[0]
    return record.address.address
  }
}
