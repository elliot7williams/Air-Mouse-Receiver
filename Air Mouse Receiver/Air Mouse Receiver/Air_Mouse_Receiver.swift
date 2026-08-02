//
//  ContentView.swift
//  Air Mouse Receiver
//
//  Created by Elliot Williams on 2025-07-14.
//

import SwiftUI
import MultipeerConnectivity
import CoreGraphics
import Combine
import ApplicationServices

struct ContentView: View {
    @StateObject private var receiver = MouseReceiver()
    @State private var hasAccessibilityPermission = false
    @State private var isCheckingPermission = false
    
    var body: some View {
        VStack {
            if !hasAccessibilityPermission {
                VStack {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                        .padding()
                    
                    Text("Accessibility Permission Required")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.bottom, 5)
                    
                    Text("This app needs Accessibility permissions to control your mouse cursor.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                    
                    Button("Request Permission") {
                        requestAccessibilityPermission()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(6)
                    .padding(.bottom, 5)
                    
                    Button("Open System Preferences") {
                        openSystemPreferences()
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                    .padding(.bottom, 10)
                    
                    if isCheckingPermission {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Checking permissions...")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding()
                    }
                }
            } else {
                VStack {
                    Text(receiver.connected ? "Connected to iPhone" : "Waiting for iPhone connection...")
                        .padding()
                    
                    if receiver.connected {
                        Text("System mouse control active")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Move your iPhone to control the mouse cursor")
                            .foregroundColor(.gray)
                            .font(.caption2)
                    } else {
                        VStack(spacing: 10) {
                            Button("Try Again") {
                                receiver.tryAgain()
                            }
                            .padding(.top, 10)
                            
                            Button("Debug Connection") {
                                receiver.debugConnection()
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    }
                }
            }
            
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .frame(width: 400, height: 350)
        .onAppear {
            checkAccessibilityPermission()
            if hasAccessibilityPermission {
                receiver.start()
                receiver.setupBackgroundProcessing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            receiver.handleAppWillResignActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            receiver.handleAppDidBecomeActive()
            // Check permissions again when app becomes active (user might have granted them)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                checkAccessibilityPermission()
                if hasAccessibilityPermission && !receiver.connected {
                    receiver.start()
                    receiver.setupBackgroundProcessing()
                }
            }
        }
    }
    
    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        hasAccessibilityPermission = trusted
        print("🔒 Accessibility permission status: \(trusted)")
    }
    
    private func requestAccessibilityPermission() {
        print("🔐 Requesting Accessibility permission...")
        isCheckingPermission = true
        
        // Request permission with prompt
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        print("📋 Initial permission check result: \(trusted)")
        
        if trusted {
            // Permission was already granted
            print("✅ Permission already granted!")
            hasAccessibilityPermission = true
            isCheckingPermission = false
            receiver.start()
            receiver.setupBackgroundProcessing()
        } else {
            // Permission dialog was shown, check again after a delay
            print("⏳ Permission dialog shown, checking again...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                checkAccessibilityPermission()
                isCheckingPermission = false
                
                if hasAccessibilityPermission {
                    print("🎉 Permission granted by user!")
                    receiver.start()
                    receiver.setupBackgroundProcessing()
                } else {
                    print("❌ Permission denied or dialog dismissed")
                }
            }
        }
    }
    
    private func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

class MouseReceiver: NSObject, ObservableObject {
    private let peerID = MCPeerID(displayName: Host.current().name ?? "Mac")
    private var session: MCSession!
    private var browser: MCNearbyServiceBrowser!
    private var advertiser: MCNearbyServiceAdvertiser!
    private let serviceType = "mouse-control"
    @Published var connected = false
    
    // Background processing
    private var keepAliveTimer: Timer?
    private var backgroundTask: NSBackgroundActivityScheduler?
    private var cancellables = Set<AnyCancellable>()
    
    // Browser state tracking
    private var isBrowsing = false
    private var isAdvertising = false
    
    
    func start() {
        print("🚀 Starting MouseReceiver...")
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
        
        // Set up browser
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        isBrowsing = true
        
        // Set up advertiser with discovery info
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, 
                                              discoveryInfo: ["type": "mac-receiver", "version": "1.0"],
                                              serviceType: serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        isAdvertising = true
        
        // Start keep-alive timer
        startKeepAliveTimer()
        print("✅ MouseReceiver started - browsing for peers and advertising")
        print("💻 Mac is advertising as: \(peerID.displayName)")
        print("🔍 Mac is browsing for service: \(serviceType)")
        print("📝 Mac discovery info: [\"type\": \"mac-receiver\", \"version\": \"1.0\"]")
    }
    
    func setupBackgroundProcessing() {
        print("🔧 Setting up background processing...")
        
        // Create background activity scheduler
        backgroundTask = NSBackgroundActivityScheduler(identifier: "com.imagix.mouse-receiver")
        backgroundTask?.repeats = true
        backgroundTask?.interval = 30 // Check every 30 seconds
        backgroundTask?.qualityOfService = .userInitiated
        
        backgroundTask?.schedule { [weak self] completion in
            self?.maintainConnection()
            completion(.finished)
        }
    }
    
    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendKeepAlive()
        }
    }
    
    private func sendKeepAlive() {
        guard connected, let session = session, !session.connectedPeers.isEmpty else { return }
        
        let keepAliveData = "keepalive".data(using: .utf8)!
        do {
            try session.send(keepAliveData, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("⚠️ Failed to send keep-alive: \(error)")
        }
    }
    
    private func maintainConnection() {
        print("🔄 Maintaining connection...")
        if !connected && !isBrowsing {
            print("📡 Restarting browser...")
            // Check if browser is initialized before using it
            if let browser = browser {
                browser.startBrowsingForPeers()
                isBrowsing = true
            } else {
                print("⚠️ Browser not initialized, calling start() to initialize")
                start()
            }
        }
    }
    
    func handleAppWillResignActive() {
        print("⚠️ App will resign active - maintaining connection")
        // Don't stop any services when app loses focus
        sendKeepAlive()
    }
    
    func handleAppDidBecomeActive() {
        print("✅ App became active - checking connection")
        maintainConnection()
    }
    
    func stopBrowsing() {
        if isBrowsing {
            // Check if browser is initialized before using it
            if let browser = browser {
                browser.stopBrowsingForPeers()
                isBrowsing = false
                print("🚫 Stopped browsing for peers")
            } else {
                // Browser was nil, just reset the state
                isBrowsing = false
                print("⚠️ Browser was nil when trying to stop browsing")
            }
        }
        
        if isAdvertising {
            // Check if advertiser is initialized before using it
            if let advertiser = advertiser {
                advertiser.stopAdvertisingPeer()
                isAdvertising = false
                print("🚫 Stopped advertising")
            } else {
                // Advertiser was nil, just reset the state
                isAdvertising = false
                print("⚠️ Advertiser was nil when trying to stop advertising")
            }
        }
    }
    
    func tryAgain() {
        print("🔄 Try Again button pressed - restarting connection...")
        
        // Stop current browsing
        stopBrowsing()
        
        // Disconnect any existing sessions
        session.disconnect()
        
        // Wait a moment for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Restart the connection process
            self.start()
        }
    }
    
    func debugConnection() {
        print("🔍 === DEBUG CONNECTION STATUS ===")
        print("📱 Peer ID: \(peerID.displayName)")
        print("🔗 Service Type: \(serviceType)")
        print("🌐 Connected: \(connected)")
        print("🔍 Is Browsing: \(isBrowsing)")
        print("📡 Is Advertising: \(isAdvertising)")
        
        if let session = session {
            print("📋 Session connected peers: \(session.connectedPeers.count)")
            for peer in session.connectedPeers {
                print("  - \(peer.displayName)")
            }
        } else {
            print("❌ Session is nil")
        }
        
        if let browser = browser {
            print("🔍 Browser exists and is configured")
        } else {
            print("❌ Browser is nil")
        }
        
        if let advertiser = advertiser {
            print("📡 Advertiser exists and is configured")
        } else {
            print("❌ Advertiser is nil")
        }
        
        print("🔍 === END DEBUG ===")
        
        // Force a connection attempt
        if !connected {
            print("🔄 Forcing connection attempt...")
            stopBrowsing()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.start()
            }
        }
    }
    
    deinit {
        stopBrowsing()
        keepAliveTimer?.invalidate()
        backgroundTask?.invalidate()
    }
    
    private func handleMessage(_ message: String) {
        print("📨 Received message: \(message)")
        let components = message.components(separatedBy: ":")
        guard !components.isEmpty else { return }
        
        switch components[0] {
        case "move":
            handleMove(components)
        case "left":
            if components.count > 1 {
                let state = components[1]
                if state == "down" {
                    simulateMouseEvent(button: .left, state: .leftMouseDown)
                } else if state == "up" {
                    simulateMouseEvent(button: .left, state: .leftMouseUp)
                }
            }
        case "right":
            if components.count > 1 {
                let state = components[1]
                if state == "down" {
                    simulateMouseEvent(button: .right, state: .rightMouseDown)
                } else if state == "up" {
                    simulateMouseEvent(button: .right, state: .rightMouseUp)
                }
            }
        case "middle":
            if components.count > 1 {
                let state = components[1]
                if state == "down" {
                    simulateMouseEvent(button: .center, state: .otherMouseDown)
                } else if state == "up" {
                    simulateMouseEvent(button: .center, state: .otherMouseUp)
                }
            }
        case "scroll":
            if components.count > 1, let scrollAmount = Double(components[1]) {
                handleScroll(scrollAmount)
            }
        default:
            print("⚠️ Unknown message type: \(components[0])")
            break
        }
    }
    
    private func handleMove(_ components: [String]) {
        guard components.count >= 2 else {
            print("⚠️ Invalid move command: not enough components")
            return
        }
        
        // Parse move data
        let moveString = components[1]
        let moveComponents = moveString.split(separator: ",")
        guard moveComponents.count == 2,
              let dx = Double(moveComponents[0]),
              let dy = Double(moveComponents[1]) else {
            print("⚠️ Invalid move data: \(moveString)")
            return
        }
        
        // Filter out very small movements to reduce jitter (lowered threshold for better responsiveness)
        let threshold = 0.3
        guard abs(dx) > threshold || abs(dy) > threshold else {
            return
        }
        
        // Apply cursor movement with bounds checking
        if let currentLocation = CGEvent(source: nil)?.location {
            // Get screen bounds to prevent cursor from going off-screen
            let screenBounds = CGDisplayBounds(CGMainDisplayID())
            
            let newX = min(max(currentLocation.x + CGFloat(dx), screenBounds.minX), screenBounds.maxX - 1)
            let newY = min(max(currentLocation.y + CGFloat(dy), screenBounds.minY), screenBounds.maxY - 1)
            
            let newLocation = CGPoint(x: newX, y: newY)
            
            // Only print debug info for significant movements
            if abs(dx) > 2 || abs(dy) > 2 {
                print("🎯 Moving mouse by dx=\(String(format: "%.1f", dx)), dy=\(String(format: "%.1f", dy))")
                print("📍 Current: (\(Int(currentLocation.x)), \(Int(currentLocation.y))) -> New: (\(Int(newLocation.x)), \(Int(newLocation.y)))")
            }
            
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: newLocation, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    
    private func simulateMouseEvent(button: CGMouseButton, state: CGEventType) {
        guard let position = CGEvent(source: nil)?.location else { return }
        
        print("🖱️ Simulating mouse event: button=\(button.rawValue), state=\(state.rawValue)")
        let event = CGEvent(mouseEventSource: nil, mouseType: state, mouseCursorPosition: position, mouseButton: button)
        event?.post(tap: .cghidEventTap)
    }
    
    private func handleScroll(_ amount: Double) {
        print("🔄 Handling scroll: \(amount)")
        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        scrollEvent?.post(tap: .cghidEventTap)
    }
}

extension MouseReceiver: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("🔗 Session state changed for \(peerID.displayName): \(state.rawValue)")
        DispatchQueue.main.async {
            self.connected = (state == .connected)
            if state == .connected {
                print("✅ Successfully connected to \(peerID.displayName)")
            } else if state == .notConnected {
                print("🔴 Disconnected from \(peerID.displayName)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let message = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async {
                self.handleMessage(message)
            }
        } else {
            print("⚠️ Received invalid data from \(peerID.displayName)")
        }
    }
    
    // Required stubs
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MouseReceiver: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("🔍 Found peer: \(peerID.displayName)")
        if let info = info {
            print("📋 Discovery info: \(info)")
        }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        print("📤 Invited \(peerID.displayName) to session")
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("📍 Lost peer: \(peerID.displayName)")
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("❌ Browser failed to start: \(error.localizedDescription)")
        isBrowsing = false
    }
}

extension MouseReceiver: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("📨 Received invitation from \(peerID.displayName)")
        // Accept all invitations automatically
        invitationHandler(true, session)
        print("✅ Accepted invitation from \(peerID.displayName)")
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("❌ Failed to start advertising: \(error.localizedDescription)")
        isAdvertising = false
    }
}

@main
struct Air_Mouse_ReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
