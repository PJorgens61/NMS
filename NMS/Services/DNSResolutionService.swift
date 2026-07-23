import Foundation

/// Resolves a hostname via the POSIX `getaddrinfo` call — a real DNS lookup
/// through the system resolver (respects system DNS settings), isolated
/// from any actual network I/O beyond the lookup itself. This is what lets
/// "DNS is broken" be distinguished from "IP connectivity is broken":
/// `getaddrinfo` can succeed or fail independently of whether a ping to a
/// raw IP address succeeds.
struct DNSResolutionService {
    enum ResolutionError: Error {
        case failed(Int32)
    }

    func resolve(_ hostname: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &resultPointer)
        guard status == 0, let resultPointer else {
            throw ResolutionError.failed(status)
        }
        defer { freeaddrinfo(resultPointer) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = resultPointer
        while let ptr = current {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(ptr.pointee.ai_addr, ptr.pointee.ai_addrlen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                addresses.append(String(cString: hostBuffer))
            }
            current = ptr.pointee.ai_next
        }
        return addresses
    }
}
