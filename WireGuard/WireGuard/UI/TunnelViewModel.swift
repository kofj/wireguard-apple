// SPDX-License-Identifier: MIT
// Copyright © 2018 WireGuard LLC. All rights reserved.

import UIKit

class TunnelViewModel {

    enum InterfaceField: String {
        case name = "Name"
        case privateKey = "Private key"
        case publicKey = "Public key"
        case generateKeyPair = "Generate keypair"
        case copyPublicKey = "Copy public key"
        case addresses = "Addresses"
        case listenPort = "Listen port"
        case mtu = "MTU"
        case dns = "DNS servers"
    }

    static let interfaceFieldsWithControl: Set<InterfaceField> = [
        .generateKeyPair, .copyPublicKey
    ]

    enum PeerField: String {
        case publicKey = "Public key"
        case preSharedKey = "Pre-shared key"
        case endpoint = "Endpoint"
        case persistentKeepAlive = "Persistent Keepalive"
        case allowedIPs = "Allowed IPs"
        case excludePrivateIPs = "Exclude private IPs"
        case deletePeer = "Delete peer"
    }

    static let peerFieldsWithControl: Set<PeerField> = [
        .excludePrivateIPs, .deletePeer
    ]

    static let keyLengthInBase64 = 44

    class InterfaceData {
        var scratchpad: [InterfaceField: String] = [:]
        var fieldsWithError: Set<InterfaceField> = []
        var validatedConfiguration: InterfaceConfiguration? = nil

        subscript(field: InterfaceField) -> String {
            get {
                if (scratchpad.isEmpty) {
                    // When starting to read a config, setup the scratchpad.
                    // The scratchpad shall serve as a cache of what we want to show in the UI.
                    populateScratchpad()
                }
                return scratchpad[field] ?? ""
            }
            set(stringValue) {
                if (scratchpad.isEmpty) {
                    // When starting to edit a config, setup the scratchpad and remove the configuration.
                    // The scratchpad shall be the sole source of the being-edited configuration.
                    populateScratchpad()
                }
                validatedConfiguration = nil
                if (stringValue.isEmpty) {
                    scratchpad.removeValue(forKey: field)
                } else {
                    scratchpad[field] = stringValue
                }
                if (field == .privateKey) {
                    if (stringValue.count == TunnelViewModel.keyLengthInBase64),
                        let privateKey = Data(base64Encoded: stringValue),
                        privateKey.count == 32 {
                        let publicKey = Curve25519.generatePublicKey(fromPrivateKey: privateKey)
                        scratchpad[.publicKey] = publicKey.base64EncodedString()
                    } else {
                        scratchpad.removeValue(forKey: .publicKey)
                    }
                }
            }
        }

        func populateScratchpad() {
            // Populate the scratchpad from the configuration object
            guard let config = validatedConfiguration else { return }
            scratchpad[.name] = config.name
            scratchpad[.privateKey] = config.privateKey.base64EncodedString()
            scratchpad[.publicKey] = config.publicKey.base64EncodedString()
            if (!config.addresses.isEmpty) {
                scratchpad[.addresses] = config.addresses.map { $0.stringRepresentation() }.joined(separator: ", ")
            }
            if let listenPort = config.listenPort {
                scratchpad[.listenPort] = String(listenPort)
            }
            if let mtu = config.mtu {
                scratchpad[.mtu] = String(mtu)
            }
            if (!config.dns.isEmpty) {
                scratchpad[.dns] = config.dns.map { $0.stringRepresentation() }.joined(separator: ", ")
            }
        }

        func save() -> SaveResult<InterfaceConfiguration> {
            fieldsWithError.removeAll()
            guard let name = scratchpad[.name], (!name.isEmpty) else {
                fieldsWithError.insert(.name)
                return .error("Interface name is required")
            }
            guard let privateKeyString = scratchpad[.privateKey] else {
                fieldsWithError.insert(.privateKey)
                return .error("Interface's private key is required")
            }
            guard let privateKey = Data(base64Encoded: privateKeyString), privateKey.count == 32 else {
                fieldsWithError.insert(.privateKey)
                return .error("Interface's private key should be a 32-byte key in base64 encoding")
            }
            var config = InterfaceConfiguration(name: name, privateKey: privateKey)
            var errorMessages: [String] = []
            if let addressesString = scratchpad[.addresses] {
                var addresses: [IPAddressRange] = []
                for addressString in addressesString.split(separator: ",") {
                    let trimmedString = addressString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if let address = IPAddressRange(from: trimmedString) {
                        addresses.append(address)
                    } else {
                        fieldsWithError.insert(.addresses)
                        errorMessages.append("Interface addresses should be a list of comma-separated IP addresses in CIDR notation")
                    }
                }
                config.addresses = addresses
            }
            if let listenPortString = scratchpad[.listenPort] {
                if let listenPort = UInt16(listenPortString) {
                    config.listenPort = listenPort
                } else {
                    fieldsWithError.insert(.listenPort)
                    errorMessages.append("Interface's listen port should be a 16-bit integer (0 to 65535)")
                }
            }
            if let mtuString = scratchpad[.mtu] {
                if let mtu = UInt16(mtuString) {
                    config.mtu = mtu
                } else {
                    fieldsWithError.insert(.mtu)
                    errorMessages.append("Interface's MTU should be a 16-bit integer (0 to 65535)")
                }
            }
            if let dnsString = scratchpad[.dns] {
                var dnsServers: [DNSServer] = []
                for dnsServerString in dnsString.split(separator: ",") {
                    let trimmedString = dnsServerString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if let dnsServer = DNSServer(from: trimmedString) {
                        dnsServers.append(dnsServer)
                    } else {
                        fieldsWithError.insert(.dns)
                        errorMessages.append("Interface's DNS should be a list of comma-separated IP addresses")
                    }
                }
                config.dns = dnsServers
            }

            guard (errorMessages.isEmpty) else {
                return .error(errorMessages.first!)
            }
            validatedConfiguration = config
            return .saved(config)
        }

        func filterFieldsWithValueOrControl(interfaceFields: [InterfaceField]) -> [InterfaceField] {
            return interfaceFields.filter { (field) -> Bool in
                if (TunnelViewModel.interfaceFieldsWithControl.contains(field)) {
                    return true
                }
                return (!self[field].isEmpty)
            }
            // TODO: Cache this to avoid recomputing
        }
    }

    class PeerData {
        var index: Int
        var scratchpad: [PeerField: String] = [:]
        var fieldsWithError: Set<PeerField> = []
        var validatedConfiguration: PeerConfiguration? = nil

        // For exclude private IPs
        var shouldAllowExcludePrivateIPsControl: Bool = false
        var excludePrivateIPsValue: Bool = false
        var numberOfPeers: Int = 0 {
            didSet { updateExcludePrivateIPsFieldState() }
        }

        init(index: Int) {
            self.index = index
        }

        subscript(field: PeerField) -> String {
            get {
                if (scratchpad.isEmpty) {
                    // When starting to read a config, setup the scratchpad.
                    // The scratchpad shall serve as a cache of what we want to show in the UI.
                    populateScratchpad()
                }
                return scratchpad[field] ?? ""
            }
            set(stringValue) {
                if (scratchpad.isEmpty) {
                    // When starting to edit a config, setup the scratchpad and remove the configuration.
                    // The scratchpad shall be the sole source of the being-edited configuration.
                    populateScratchpad()
                }
                validatedConfiguration = nil
                if (stringValue.isEmpty) {
                    scratchpad.removeValue(forKey: field)
                } else {
                    scratchpad[field] = stringValue
                }
                if (field == .allowedIPs) {
                    updateExcludePrivateIPsFieldState()
                }
            }
        }

        func populateScratchpad() {
            // Populate the scratchpad from the configuration object
            guard let config = validatedConfiguration else { return }
            scratchpad[.publicKey] = config.publicKey.base64EncodedString()
            if let preSharedKey = config.preSharedKey {
                scratchpad[.preSharedKey] = preSharedKey.base64EncodedString()
            }
            if (!config.allowedIPs.isEmpty) {
                scratchpad[.allowedIPs] = config.allowedIPs.map { $0.stringRepresentation() }.joined(separator: ", ")
            }
            if let endpoint = config.endpoint {
                scratchpad[.endpoint] = endpoint.stringRepresentation()
            }
            if let persistentKeepAlive = config.persistentKeepAlive {
                scratchpad[.persistentKeepAlive] = String(persistentKeepAlive)
            }
            updateExcludePrivateIPsFieldState()
        }

        func save() -> SaveResult<PeerConfiguration> {
            fieldsWithError.removeAll()
            guard let publicKeyString = scratchpad[.publicKey] else {
                fieldsWithError.insert(.publicKey)
                return .error("Peer's public key is required")
            }
            guard let publicKey = Data(base64Encoded: publicKeyString), publicKey.count == 32 else {
                fieldsWithError.insert(.publicKey)
                return .error("Peer's public key should be a 32-byte key in base64 encoding")
            }
            var config = PeerConfiguration(publicKey: publicKey)
            var errorMessages: [String] = []
            if let preSharedKeyString = scratchpad[.preSharedKey] {
                if let preSharedKey = Data(base64Encoded: preSharedKeyString), preSharedKey.count == 32 {
                    config.preSharedKey = preSharedKey
                } else {
                    fieldsWithError.insert(.preSharedKey)
                    errorMessages.append("Peer's pre-shared key should be a 32-byte key in base64 encoding")
                }
            }
            if let allowedIPsString = scratchpad[.allowedIPs] {
                var allowedIPs: [IPAddressRange] = []
                for allowedIPString in allowedIPsString.split(separator: ",") {
                    let trimmedString = allowedIPString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if let allowedIP = IPAddressRange(from: trimmedString) {
                        allowedIPs.append(allowedIP)
                    } else {
                        fieldsWithError.insert(.allowedIPs)
                        errorMessages.append("Peer's allowedIPs should be a list of comma-separated IP addresses in CIDR notation")
                    }
                }
                config.allowedIPs = allowedIPs
            }
            if let endpointString = scratchpad[.endpoint] {
                if let endpoint = Endpoint(from: endpointString) {
                    config.endpoint = endpoint
                } else {
                    fieldsWithError.insert(.endpoint)
                    errorMessages.append("Peer's endpoint should be of the form 'host:port' or '[host]:port'")
                }
            }
            if let persistentKeepAliveString = scratchpad[.persistentKeepAlive] {
                if let persistentKeepAlive = UInt16(persistentKeepAliveString) {
                    config.persistentKeepAlive = persistentKeepAlive
                } else {
                    fieldsWithError.insert(.persistentKeepAlive)
                    errorMessages.append("Peer's persistent keepalive should be a 16-bit integer (0 to 65535)")
                }
            }

            guard (errorMessages.isEmpty) else {
                return .error(errorMessages.first!)
            }
            validatedConfiguration = config
            return .saved(config)
        }

        func filterFieldsWithValueOrControl(peerFields: [PeerField]) -> [PeerField] {
            return peerFields.filter { (field) -> Bool in
                if (TunnelViewModel.peerFieldsWithControl.contains(field)) {
                    return true
                }
                return (!self[field].isEmpty)
            }
            // TODO: Cache this to avoid recomputing
        }

        static let ipv4DefaultRouteString = "0.0.0.0/0"
        static let ipv4DefaultRouteModRFC1918String = [ // Set of all non-private IPv4 IPs
            "0.0.0.0/5", "8.0.0.0/7", "11.0.0.0/8", "12.0.0.0/6", "16.0.0.0/4", "32.0.0.0/3",
            "64.0.0.0/2", "128.0.0.0/3", "160.0.0.0/5", "168.0.0.0/6", "172.0.0.0/12",
            "172.32.0.0/11", "172.64.0.0/10", "172.128.0.0/9", "173.0.0.0/8", "174.0.0.0/7",
            "176.0.0.0/4", "192.0.0.0/9", "192.128.0.0/11", "192.160.0.0/13", "192.169.0.0/16",
            "192.170.0.0/15", "192.172.0.0/14", "192.176.0.0/12", "192.192.0.0/10",
            "193.0.0.0/8", "194.0.0.0/7", "196.0.0.0/6", "200.0.0.0/5", "208.0.0.0/4"
        ]

        func updateExcludePrivateIPsFieldState() {
            guard (numberOfPeers == 1) else {
                shouldAllowExcludePrivateIPsControl = false
                excludePrivateIPsValue = false
                return
            }
            let allowedIPStrings = Set<String>(
                (scratchpad[.allowedIPs] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            )
            if (allowedIPStrings.contains(TunnelViewModel.PeerData.ipv4DefaultRouteString)) {
                shouldAllowExcludePrivateIPsControl = true
                excludePrivateIPsValue = false
            } else if (allowedIPStrings.isSuperset(of: TunnelViewModel.PeerData.ipv4DefaultRouteModRFC1918String)) {
                shouldAllowExcludePrivateIPsControl = true
                excludePrivateIPsValue = true
            } else {
                shouldAllowExcludePrivateIPsControl = false
                excludePrivateIPsValue = false
            }
        }

        func excludePrivateIPsValueChanged(isOn: Bool, dnsServers: String) {
            let allowedIPStrings = (scratchpad[.allowedIPs] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            let dnsServerStrings = dnsServers
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            let ipv6Addresses = allowedIPStrings.filter { $0.contains(":") }
            let modifiedAllowedIPStrings: [String]
            if (isOn) {
                modifiedAllowedIPStrings = ipv6Addresses +
                    TunnelViewModel.PeerData.ipv4DefaultRouteModRFC1918String + dnsServerStrings
            } else {
                modifiedAllowedIPStrings = ipv6Addresses +
                    [TunnelViewModel.PeerData.ipv4DefaultRouteString]
            }
            scratchpad[.allowedIPs] = modifiedAllowedIPStrings.joined(separator: ", ")
            excludePrivateIPsValue = isOn
        }
    }

    enum SaveResult<Configuration> {
        case saved(Configuration)
        case error(String) // TODO: Localize error messages
    }

    var interfaceData: InterfaceData
    var peersData: [PeerData]

    init(tunnelConfiguration: TunnelConfiguration?) {
        interfaceData = InterfaceData()
        peersData = []
        if let tunnelConfiguration = tunnelConfiguration {
            interfaceData.validatedConfiguration = tunnelConfiguration.interface
            for (i, peerConfiguration) in tunnelConfiguration.peers.enumerated() {
                let peerData = PeerData(index: i)
                peerData.validatedConfiguration = peerConfiguration
                peersData.append(peerData)
            }
        }
    }

    func appendEmptyPeer() {
        let peer = PeerData(index: peersData.count)
        peersData.append(peer)
        for p in peersData {
            p.numberOfPeers = peersData.count
        }
    }

    func deletePeer(peer: PeerData) {
        let removedPeer = peersData.remove(at: peer.index)
        assert(removedPeer.index == peer.index)
        for p in peersData[peer.index ..< peersData.count] {
            assert(p.index > 0)
            p.index = p.index - 1
        }
        for p in peersData {
            p.numberOfPeers = peersData.count
        }
    }

    func save() -> SaveResult<TunnelConfiguration> {
        // Attempt to save the interface and all peers, so that all erroring fields are collected
        let interfaceSaveResult = interfaceData.save()
        let peerSaveResults = peersData.map { $0.save() }
        // Collate the results
        switch (interfaceSaveResult) {
        case .error(let errorMessage):
            return .error(errorMessage)
        case .saved(let interfaceConfiguration):
            var peerConfigurations: [PeerConfiguration] = []
            peerConfigurations.reserveCapacity(peerSaveResults.count)
            for peerSaveResult in peerSaveResults {
                switch (peerSaveResult) {
                case .error(let errorMessage):
                    return .error(errorMessage)
                case .saved(let peerConfiguration):
                    peerConfigurations.append(peerConfiguration)
                }
            }
            let tunnelConfiguration = TunnelConfiguration(interface: interfaceConfiguration)
            tunnelConfiguration.peers = peerConfigurations
            return .saved(tunnelConfiguration)
        }
    }
}
