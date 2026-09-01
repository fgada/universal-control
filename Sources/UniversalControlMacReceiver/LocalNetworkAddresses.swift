import Darwin
import Foundation

enum LocalNetworkAddresses {
    static func printIPv4Addresses(listenPort: UInt16) {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let firstInterface = interfaceList else {
            fputs("Unable to enumerate local network interfaces.\n", stderr)
            return
        }
        defer { freeifaddrs(firstInterface) }

        var results: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interfacePointer = cursor {
            let interface = interfacePointer.pointee
            cursor = interface.ifa_next

            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var address = addressPointer.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &address) { pointer in
                getnameinfo(
                    pointer,
                    socklen_t(addressPointer.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard result == 0 else { continue }

            let addressString = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            results.append((
                name: String(cString: interface.ifa_name),
                address: addressString
            ))
        }

        if results.isEmpty {
            print("No non-loopback IPv4 address found.")
            return
        }

        print("Local IPv4 addresses:")
        for result in results.sorted(by: { ($0.name, $0.address) < ($1.name, $1.address) }) {
            print("  \(result.address) (\(result.name))")
        }
        print("Use one from the sender with --target-host <IP> --target-port \(listenPort)")
    }
}
