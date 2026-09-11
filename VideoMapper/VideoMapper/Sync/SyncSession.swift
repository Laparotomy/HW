import Foundation
import MultipeerConnectivity
import UIKit
import os

/// What this device does in an ensemble.
enum SyncRole: String, Codable, CaseIterable, Identifiable {
    case solo, host, follower

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .solo: return "Solo"
        case .host: return "Host"
        case .follower: return "Join"
        }
    }
}

struct SyncPeer: Identifiable, Equatable {
    var id: String { peerID.displayName }
    let peerID: MCPeerID
    var isConnected: Bool
}

protocol SyncSessionDelegate: AnyObject {
    func syncSession(_ session: SyncSession, didReceive message: SyncMessage, from peer: MCPeerID)
    /// Called on the host when a device joins, so it can push current state.
    func syncSessionDidConnectPeer(_ session: SyncSession, peer: MCPeerID)
}

/// Peer-to-peer link between devices running the same show.
///
/// Multipeer Connectivity is used rather than a server because the whole point is
/// two phones on a table with no infrastructure: it will bridge Wi-Fi and
/// peer-to-peer Wi-Fi automatically, and needs no pairing step.
final class SyncSession: NSObject, ObservableObject {
    /// Must be 15 characters or fewer and match the Bonjour services in Info.plist.
    static let serviceType = "vmapper-sync"

    @Published private(set) var role: SyncRole = .solo
    @Published private(set) var peers: [SyncPeer] = []
    @Published private(set) var clockOffset: Double = 0
    @Published private(set) var roundTrip: Double = 0
    @Published private(set) var isSynchronized = false
    @Published private(set) var lastError: String?

    weak var delegate: SyncSessionDelegate?

    let clock = ClockSynchronizer()

    private let log = Logger(subsystem: "app.videomapper", category: "Sync")
    private let localPeerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var probeTimer: Timer?
    private var probesSent = 0

    override init() {
        // Peer display names are limited to 63 bytes.
        let name = String(UIDevice.current.name.prefix(40))
        localPeerID = MCPeerID(displayName: name.isEmpty ? "iPhone" : name)
        super.init()
    }

    deinit {
        probeTimer?.invalidate()
    }

    var localName: String { localPeerID.displayName }

    var connectedPeers: [MCPeerID] { session?.connectedPeers ?? [] }

    // MARK: - Lifecycle

    func setRole(_ newRole: SyncRole) {
        guard newRole != role else { return }
        teardown()
        role = newRole
        switch newRole {
        case .solo:
            break
        case .host:
            startSession()
            let advertiser = MCNearbyServiceAdvertiser(peer: localPeerID,
                                                       discoveryInfo: ["role": "host"],
                                                       serviceType: Self.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        case .follower:
            startSession()
            let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
            startProbing()
        }
    }

    private func startSession() {
        let session = MCSession(peer: localPeerID, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        self.session = session
    }

    private func teardown() {
        probeTimer?.invalidate()
        probeTimer = nil
        probesSent = 0
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        clock.reset()
        DispatchQueue.main.async { [weak self] in
            self?.peers = []
            self?.isSynchronized = false
            self?.clockOffset = 0
            self?.roundTrip = 0
        }
    }

    // MARK: - Sending

    func send(_ message: SyncMessage, reliable: Bool = true) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        do {
            let data = try message.encoded()
            try session.send(data, toPeers: session.connectedPeers,
                             with: reliable ? .reliable : .unreliable)
        } catch {
            log.error("Send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func send(_ message: SyncMessage, to peer: MCPeerID) {
        guard let session else { return }
        do {
            try session.send(try message.encoded(), toPeers: [peer], with: .reliable)
        } catch {
            log.error("Direct send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Clock probing (followers)

    private func startProbing() {
        probeTimer?.invalidate()
        // Probe quickly at first to converge, then settle into a slow keep-alive
        // that tracks drift without flooding the link.
        probeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.role == .follower, let session = self.session,
                  !session.connectedPeers.isEmpty else { return }
            if self.probesSent > 10, self.probesSent % 5 != 0 {
                self.probesSent += 1
                return
            }
            self.sendProbe()
            self.probesSent += 1
        }
    }

    private func sendProbe() {
        let id = UUID()
        let now = HostClock.now
        clock.noteProbeSent(id: id, at: now)
        // Unreliable: a dropped probe is cheaper than a retransmitted one that
        // arrives late and skews the estimate.
        send(.ping(id: id, t0: now), reliable: false)
    }

    /// Handles clock traffic; returns true when the message was consumed here.
    private func handleClockMessage(_ message: SyncMessage, from peer: MCPeerID) -> Bool {
        switch message {
        case .ping(let id, let t0):
            guard role == .host else { return true }
            send(.pong(id: id, t0: t0, t1: HostClock.now), to: peer)
            return true
        case .pong(let id, _, let t1):
            guard role == .follower else { return true }
            clock.noteReply(id: id, hostTime: t1, localNow: HostClock.now)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clockOffset = self.clock.offset
                self.roundTrip = self.clock.roundTrip
                self.isSynchronized = self.clock.isSynchronized
            }
            return true
        default:
            return false
        }
    }

    private func refreshPeers() {
        let connected = session?.connectedPeers ?? []
        DispatchQueue.main.async { [weak self] in
            self?.peers = connected.map { SyncPeer(peerID: $0, isConnected: true) }
        }
    }
}

// MARK: - MCSessionDelegate

extension SyncSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        refreshPeers()
        guard state == .connected else { return }
        send(.hello(name: localPeerID.displayName, isHost: role == .host), to: peerID)
        if role == .follower {
            // Get a first estimate immediately rather than waiting for the timer.
            sendProbe()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncSessionDidConnectPeer(self, peer: peerID)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let message = try SyncMessage.decode(data)
            // Answer probes on the receiving thread; a hop to main would add
            // several milliseconds of error to every measurement.
            if handleClockMessage(message, from: peerID) { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.syncSession(self, didReceive: message, from: peerID)
            }
        } catch {
            log.error("Bad message from \(peerID.displayName, privacy: .public)")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Discovery

extension SyncSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log.error("Advertising failed: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.lastError = "Could not host: \(error.localizedDescription)"
        }
    }
}

extension SyncSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let session, info?["role"] == "host" else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        refreshPeers()
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.lastError = "Could not join: \(error.localizedDescription). Check Local Network permission."
        }
    }
}
