import Foundation

public struct ForwirohError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A Sendable escape hatch for new commands and event fields in the core protocol.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }
    public subscript(key: String) -> JSONValue? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }
    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public struct Status: Decodable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let peers: [Peer]
    public let tunnels: [Tunnel]
}

public struct Peer: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let device: String
    public let connected: Bool
    public let path: String?
    public let policy: PeerPolicy
}

public struct Tunnel: Decodable, Sendable, Identifiable {
    public let id: String
    public let peer: String
    public let kind: String
    public let detail: String
}

public struct Invitation: Decodable, Sendable, Identifiable {
    public let id: String
    public let uri: String
    /// Unix timestamp in seconds.
    public let expires: UInt64
}

public struct PairingRequest: Decodable, Sendable, Identifiable {
    public let id: String
    public let peer: String
    public let name: String
    public let device: String
}

/// Policies apply to incoming requests from this peer. Pairing defaults to open access.
public struct PeerPolicy: Codable, Sendable, Equatable {
    public var restricted: Bool
    public var services: [String: String]
    public var socksNetworks: [String]
    public var socksPorts: [UInt16]
    public var reversePorts: [UInt16]
    public var vpn: VPNPolicy?

    public init(restricted: Bool = false, services: [String: String] = [:],
                socksNetworks: [String] = [], socksPorts: [UInt16] = [],
                reversePorts: [UInt16] = [], vpn: VPNPolicy? = nil) {
        self.restricted = restricted
        self.services = services
        self.socksNetworks = socksNetworks
        self.socksPorts = socksPorts
        self.reversePorts = reversePorts
        self.vpn = vpn
    }
    enum CodingKeys: String, CodingKey {
        case restricted, services, vpn
        case socksNetworks = "socks_networks", socksPorts = "socks_ports", reversePorts = "reverse_ports"
    }
}

public struct VPNPolicy: Codable, Sendable, Equatable {
    public var routes: [String]
    public var localIP: String
    public var peerIP: String
    public var tun: String
    public init(routes: [String], localIP: String, peerIP: String, tun: String = "") {
        self.routes = routes; self.localIP = localIP; self.peerIP = peerIP; self.tun = tun
    }
    enum CodingKeys: String, CodingKey {
        case routes, tun
        case localIP = "local_ip", peerIP = "peer_ip"
    }
}

public struct VPNSession: Decodable, Sendable, Identifiable {
    public let id: String
    public let localIP: String
    public let remoteIP: String
    public let localIPv6: String
    public let remoteIPv6: String
    public let forwardIP: String
    public let routes: [String]
    public let mtu: Int
    enum CodingKeys: String, CodingKey {
        case id, routes, mtu
        case localIP = "local_ip", remoteIP = "remote_ip"
        case localIPv6 = "local_ipv6", remoteIPv6 = "remote_ipv6", forwardIP = "forward_ip"
    }
}

public struct QRCode: Decodable, Sendable {
    public let width: Int
    /// Row-major matrix; true is a dark module. Add a quiet zone when drawing.
    public let pixels: [Bool]
}

public struct CoreEvent: Sendable {
    public let name: String
    public let payload: JSONValue
}
