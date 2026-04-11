import Foundation
import MultipeerConnectivity

/// Apple's Wi-Fi P2P mesh — iOS equivalent of Android's Nearby Connections.
/// Range ~60m. Sends/receives raw Data payloads. All peers auto-accepted.
///
/// MCPeerID.displayName is limited to 63 bytes (UTF-8). Nostr pubkeys are
/// 64 hex chars, so we use a UUID as the displayName and put the full pubkey
/// in discovery info under key "pk".
class MultipeerService: NSObject {
    private static let serviceType = "bitchat-mesh"

    private var myPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Maps MCPeerID → full pubkey (resolved from discoveryInfo)
    private var peerPubkeyMap: [MCPeerID: String] = [:]
    // Peers that connected before their pubkey was resolved via browser discovery.
    // Kept until browser fires foundPeer for them, at which point onPeerConnected fires.
    private var pendingPubkeyPeers: Set<MCPeerID> = []

    var onDataReceived: ((Data, String) -> Void)?    // (data, fromPubkey)
    var onPeerConnected: ((String) -> Void)?         // pubkey
    var onPeerDisconnected: ((String) -> Void)?      // pubkey

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start(pubkey: String) -> Bool {
        guard !isRunning else { return true }

        // UUID as displayName (stays within 63-byte limit); pubkey goes in discoveryInfo
        let myPeerID = MCPeerID(displayName: UUID().uuidString)
        self.myPeerID = myPeerID

        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        session?.delegate = self

        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["pk": pubkey],
            serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        isRunning = true
        return true
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        myPeerID = nil
        peerPubkeyMap.removeAll()
        pendingPubkeyPeers.removeAll()
        isRunning = false
    }

    /// Send bytes to ALL connected peers. Returns true if at least one peer received it.
    func send(data: Data) -> Bool {
        guard let session = session, !session.connectedPeers.isEmpty else { return false }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            return true
        } catch {
            return false
        }
    }

    func getConnectedPubkeys() -> [String] {
        guard let session = session else { return [] }
        return session.connectedPeers.compactMap { peerPubkeyMap[$0] }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            if let pubkey = peerPubkeyMap[peerID] {
                // Pubkey already known (browser found this peer before session connected)
                DispatchQueue.main.async { self.onPeerConnected?(pubkey) }
            } else {
                // Browser hasn't fired foundPeer for this peer yet — defer the callback.
                // This happens when we're the advertiser and the other side invited us
                // before our browser discovered them. onPeerConnected will fire from
                // browser(_:foundPeer:withDiscoveryInfo:) once the pubkey arrives.
                pendingPubkeyPeers.insert(peerID)
            }
        case .notConnected:
            let pubkey = peerPubkeyMap.removeValue(forKey: peerID)
            pendingPubkeyPeers.remove(peerID)
            if let pubkey = pubkey {
                DispatchQueue.main.async { self.onPeerDisconnected?(pubkey) }
            }
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let pubkey = peerPubkeyMap[peerID] ?? peerID.displayName
        DispatchQueue.main.async { self.onDataReceived?(data, pubkey) }
    }

    // Required stubs
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Auto-accept all invitations — open mesh
        // Resolve pubkey from context (context carries discoveryInfo from inviting side? No — context is custom)
        // We'll resolve the pubkey when we see their discoveryInfo in browser foundPeer.
        // For now accept and the peerPubkeyMap will be populated when browser finds them,
        // or we fall back to displayName.
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        // Silently ignore — BLE is still running
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard let session = session else { return }

        // Store full pubkey from discoveryInfo
        if let pubkey = info?["pk"] {
            peerPubkeyMap[peerID] = pubkey

            // If this peer already connected before we discovered their pubkey
            // (i.e. they invited us as advertiser before our browser found them),
            // fire the deferred onPeerConnected now that we have the real pubkey.
            if pendingPubkeyPeers.remove(peerID) != nil {
                DispatchQueue.main.async { self.onPeerConnected?(pubkey) }
            }
        }

        // Invite only if not already connected or connecting
        if !session.connectedPeers.contains(peerID) {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Session delegate handles the state change when the peer actually disconnects
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        // Silently ignore — BLE is still running
    }
}
