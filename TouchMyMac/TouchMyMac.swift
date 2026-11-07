//
//  Model.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
import IOKit.hid

/// Looks up the UI text for the user's language. The keys are the English text, so a missing
/// translation falls back to English.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// The language picked in Settings. Stored as this app's own AppleLanguages, which macOS reads at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Language names stay in their own language, so they can be found whatever the UI language is.
    var title: String {
        switch self {
        case .system: return L("System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    static var saved: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let first = languages.first else {
            return .system
        }
        return first.hasPrefix("zh") ? .simplifiedChinese : (first.hasPrefix("en") ? .english : .system)
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
import ServiceManagement
import TouchUpCore

struct DiagnosticsEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

struct TouchManagerDiagnosticsSnapshot {
    let inputProcessFrameID: Int
    let inputActiveTouchCount: Int
    let threeFingerTracking: Bool
    let threeFingerTriggered: Bool
    let threeFingerTouchCount: Int
    let threeFingerUpwardTouchCount: Int
    let threeFingerVerticalTravelMM: CGFloat
    let threeFingerHorizontalTravelMM: CGFloat
}

class TouchMyMac: NSObject, ObservableObject {
    
    let touchManager: TUCTouchInputManager
    @Published var touches = [TUCTouch]()
    
    
    var observers = [AnyCancellable]()
    
    
    @Published var isPublishingMouseEventsEnabled = true

    /// Mirrors the system's login item for this app, which the user can also change in System Settings.
    @Published private(set) var opensAtLogin = false
    @Published private(set) var openAtLoginNote: String?
    
    /// Derived from `touchscreenDeviceName` and the assigned display; set it through `updateConnectionState()`.
    @Published private(set) var connectionState: ConnectionState = .disconnected

    /// Product name of the connected touchscreen (HID device), nil while none is connected.
    @Published private(set) var touchscreenDeviceName: String?

    /// Bumped whenever the screen list or the assigned display changes, so the menu can refresh.
    @Published private(set) var screenAssignmentRevision = 0

    
    
    @Published var holdDuration: TimeInterval = 0.4
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    
    
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isThreeFingerSwipeEnabled = true
    @Published var isThreeFingerSwipeSpacesEnabled = true
    @Published var isControlDragEnabled = true
    @Published var isFourFingerSwipeUpKeyboardEnabled = true
    @Published var fiveFingerHoldShortcutSpec: String = "fn"
    @Published var fourFingerSwipeLeftSequenceSpec: String = "cmd+a, delete"

    @Published var isScrollInertiaEnabled = true

    /// The language picked in Settings, and the one this launch runs in; they differ until a restart.
    @Published private(set) var appLanguage = AppLanguage.saved
    let launchLanguage = AppLanguage.saved
    @Published var isCursorHiddenWhileScrolling = true
    @Published var scrollSpeedMultiplier: CGFloat = 1.0
    @Published var pinchZoomSpeed: CGFloat = 1.5
    @Published var scrollInertiaDecelerationPerFrame: CGFloat = 0.92
    @Published var scrollInertiaVelocityMultiplier: CGFloat = 1.0
    
    
    
    @Published var connectedScreens = [TUCScreen]()
    var connectedTouchscreen: TUCScreen?

    weak var floatingKeyboard: FloatingKeyboardPanel?
    
    var lastDateUSBAdded: Date?
    var lastDateScreenAdded: Date?
    var idOfLastAddedScreen: UInt?
    
    let hotPlugTimeInterval: TimeInterval = 10
    
    
    @Published var isAccessibilityAccessGranted = false
    /// Input Monitoring lets the app read HID reports from touchscreens macOS treats as private input
    /// (likely those that also report keys).
    @Published private(set) var isInputMonitoringGranted = false
    /// True when reading the touchscreen failed and Input Monitoring is missing, so it is the likely cause.
    /// Most touchscreens work without the permission, so nobody else is asked for it.
    @Published private(set) var isInputMonitoringNeeded = false
    private var inputMonitoringTimer: Timer?
    @Published var touchUpdateCount: Int = 0
    @Published var lastTouchUpdateAt: Date?
    @Published var lastActiveTouchCount: Int = 0
    @Published var gestureDecisionCount: Int = 0
    @Published var lastGestureName: String = "-"
    @Published var lastActionName: String = "-"
    @Published var lastGestureDecisionAt: Date?
    @Published var currentGestureName: String = "-"
    @Published var currentActionName: String = "-"
    @Published var recentGestureEvents: [DiagnosticsEvent] = []
    @Published var hidConnectCount: Int = 0
    @Published var hidDisconnectCount: Int = 0
    @Published var diagnosticsEvents: [DiagnosticsEvent] = []
    @Published var inputProcessFrameID: Int = 0
    @Published var inputActiveTouchCount: Int = 0
    @Published var threeFingerTracking: Bool = false
    @Published var threeFingerTriggered: Bool = false
    @Published var threeFingerTouchCount: Int = 0
    @Published var threeFingerUpwardTouchCount: Int = 0
    @Published var threeFingerVerticalTravelMM: CGFloat = 0
    @Published var threeFingerHorizontalTravelMM: CGFloat = 0
    
    private var lastGestureLogAt: Date?
    private var lastGestureSignature: String = ""
    
    // MARK: - Attempt to automatically determine touch screen
    
    
    
    var identificationCues: (name:String, id:UInt) {
        get {
            let name = UserDefaults.standard.string(forKey: "touchscreenNameCue") ?? "Digital"
            let id   = UserDefaults.standard.integer(forKey: "touchscreenIDCue")
            return (name, UInt(id))
        }
    }
    
    func rememeberCues() {
        if let connectedTouchscreen = self.touchscreen() {
            UserDefaults.standard.set(connectedTouchscreen.name, forKey: "touchscreenNameCue")
            UserDefaults.standard.set(connectedTouchscreen.id,   forKey: "touchscreenIDCue")
        }
        updateConnectionState()
    }

    /// Whether the user picked the assigned display (remembered), rather than it being chosen automatically.
    var isAssignedScreenRemembered: Bool {
        guard let screen = connectedTouchscreen else { return false }
        let cues = identificationCues
        return screen.matching(name: cues.name, id: cues.id) == 1
    }

    /// Forgets the picked display and lets the app choose the touchscreen's display again.
    func useAutomaticTouchscreenDisplay() {
        UserDefaults.standard.removeObject(forKey: "touchscreenNameCue")
        UserDefaults.standard.removeObject(forKey: "touchscreenIDCue")
        connectedTouchscreen = Self.likelyTouchscreen(in: connectedScreens)
        updateConnectionState()
        addDiagnosticsEvent("Touchscreen display set to automatic")
    }

    func assignTouchscreen(toScreenWithID id: UInt) {
        guard let screen = connectedScreens.first(where: { $0.id == id }) else { return }
        connectedTouchscreen = screen
        rememeberCues()
        addDiagnosticsEvent("Assigned touchscreen to \(screen.name)")
    }

    /// The connection state follows the HID device: connected while one is, whichever display it maps to.
    func updateConnectionState() {
        let state: ConnectionState
        if touchscreenDeviceName == nil {
            state = .disconnected
        } else if connectedTouchscreen == nil {
            state = .uncertain
        } else {
            state = isAssignedScreenRemembered ? .connectedPreferred : .connectedAuto
        }
        if connectionState != state {
            connectionState = state
        }
        screenAssignmentRevision += 1
    }


    /**
     returns true, if the screen list contained the preferred screen which is now assigned the touch screen.
     if screen list empty, it removes the assigned touch screen.
     */
    @discardableResult func identifyPreferredOrNoScreen() -> Bool {
        let cues = identificationCues

        if connectedScreens.count == 0 {
            self.connectedTouchscreen = nil
            return true
        }

        if let perfectMatch = connectedScreens.first(where: { $0.matching(name: cues.name, id: cues.id) == 1}) {
            self.connectedTouchscreen = perfectMatch
            return true
        }

        // Display IDs can change when a monitor reconnects; a single display with the remembered name is still it.
        let sameName = connectedScreens.filter { $0.name == cues.name }
        if sameName.count == 1, let screen = sameName.first {
            self.connectedTouchscreen = screen
            UserDefaults.standard.set(screen.id, forKey: "touchscreenIDCue")
            return true
        }

        return false
    }


    /// If the touchscreen's USB cable and a display both appeared within the last few seconds, they are the same monitor.
    @discardableResult func identifyHotPlug() -> Bool {
        if let lastDateUSBAdded, let lastDateScreenAdded, let idOfLastAddedScreen {
            if Date().timeIntervalSince(lastDateUSBAdded) < hotPlugTimeInterval
                && Date().timeIntervalSince(lastDateScreenAdded) < hotPlugTimeInterval {

                if let screen = self.connectedScreens.first(where: {$0.id == idOfLastAddedScreen}), !screen.isBuiltin {
                    self.connectedTouchscreen = screen
                    return true
                }
            }
        }

        return false
    }

    /// A Mac's built-in panel has no touch, so the touchscreen is an external display.
    /// The system lists the menu bar display first, so with several externals the last one is the best guess.
    static func likelyTouchscreen(in screens: [TUCScreen]) -> TUCScreen? {
        screens.last(where: { !$0.isBuiltin }) ?? screens.last
    }

    /// Keeps the current external display if it is still connected (the list holds fresh objects), else picks one.
    private func keepOrPickFallbackScreen() {
        if let current = connectedTouchscreen, !current.isBuiltin,
           let same = connectedScreens.first(where: { $0.id == current.id }) {
            connectedTouchscreen = same
        } else {
            connectedTouchscreen = Self.likelyTouchscreen(in: connectedScreens)
        }
    }


    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens() as! [TUCScreen]

        // A new screen appeared. The first listing at launch finds every screen at once, so it doesn't count:
        // otherwise the touchscreen connecting at launch would be paired with whichever display came first.
        if !oldScreenList.isEmpty && connectedScreens.count > oldScreenList.count {
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.lastDateScreenAdded = Date()
                self.idOfLastAddedScreen = new.id
            }
        }

        // the preferred screen wins, also important if user rearranged screens (and screen numbers)
        if !self.identifyPreferredOrNoScreen() && !self.identifyHotPlug() {
            keepOrPickFallbackScreen()
        }
        updateConnectionState()
    }


    func checkAccessibilityAccessGranted() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        self.isAccessibilityAccessGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: true] as CFDictionary?)
    }

    /// Re-reads the permission without showing the system prompt.
    func refreshAccessibilityStatus() {
        let granted = AXIsProcessTrusted()
        if granted != isAccessibilityAccessGranted {
            isAccessibilityAccessGranted = granted
            addDiagnosticsEvent(granted ? "Accessibility access granted" : "Accessibility access missing")
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    var accessibilityTrustedNow: Bool {
        AXIsProcessTrusted()
    }

    // MARK: Input Monitoring

    private static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Re-reads the permission without asking. macOS posts no notification for it, so this also polls while it is needed.
    func refreshInputMonitoringStatus() {
        let granted = Self.inputMonitoringAccess == kIOHIDAccessTypeGranted
        let wasNeeded = isInputMonitoringNeeded
        if granted != isInputMonitoringGranted {
            isInputMonitoringGranted = granted
            addDiagnosticsEvent(granted ? "Input Monitoring access granted" : "Input Monitoring access missing")
        }
        let needed = !granted && touchManager.hidManagerOpenFailed
        if needed != isInputMonitoringNeeded {
            isInputMonitoringNeeded = needed
            if needed {
                addDiagnosticsEvent("Touchscreen can't be read: Input Monitoring is needed")
            }
        }
        if granted && wasNeeded {
            // The HID manager opened without access reads nothing, so open it again now.
            restartInputPipeline()
        }
        updateInputMonitoringPolling()
    }

    private func updateInputMonitoringPolling() {
        if !isInputMonitoringNeeded {
            inputMonitoringTimer?.invalidate()
            inputMonitoringTimer = nil
        } else if inputMonitoringTimer == nil {
            inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshInputMonitoringStatus()
            }
        }
    }

    /// Shows the system prompt if the app was never asked; otherwise opens the Input Monitoring list in System Settings.
    func grantInputMonitoringAccess() {
        if Self.inputMonitoringAccess == kIOHIDAccessTypeUnknown {
            addDiagnosticsEvent("Requested Input Monitoring access prompt")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            openInputMonitoringSettings()
        }
        refreshInputMonitoringStatus()
    }

    var inputMonitoringStatusText: String {
        if isInputMonitoringGranted { return L("Granted") }
        return isInputMonitoringNeeded ? L("Missing") : L("Not needed")
    }

    /// Call after starting the HID manager: asks for the permission only if reading the touchscreen failed without it.
    func requestInputMonitoringIfNeeded() {
        refreshInputMonitoringStatus()
        if isInputMonitoringNeeded && Self.inputMonitoringAccess == kIOHIDAccessTypeUnknown {
            grantInputMonitoringAccess()
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func grantAccessibilityAccess() {
        self.touchManager.triggerSystemAccessibilityAccessAlert()
        (NSApp.delegate as? AppDelegate)?.settingsWindow.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.checkAccessibilityAccessGranted()
        }
        addDiagnosticsEvent("Requested Accessibility access prompt")
    }

    override init() {
        self.touchManager = TUCTouchInputManager()
        
        super.init()
        
        self.screenParametersDidChange()
        
        self.touchManager.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(TouchMyMac.screenParametersDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Posted when any app's Accessibility permission changes; the new value is readable a moment later.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(TouchMyMac.accessibilityPermissionsDidChange), name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TouchMyMac.accessibilityPermissionsDidChange), name: NSApplication.didBecomeActiveNotification, object: nil)

        initPreferences()
        
        checkAccessibilityAccessGranted()
        isInputMonitoringGranted = Self.inputMonitoringAccess == kIOHIDAccessTypeGranted
        addDiagnosticsEvent("Initialized model")
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func accessibilityPermissionsDidChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshAccessibilityStatus()
            self.refreshInputMonitoringStatus()
        }
    }

    /// Stopping the HID manager drops the device without a removal callback; a restart reports it again.
    private func forgetTouchscreenDevice() {
        touchscreenDeviceName = nil
        updateConnectionState()
    }
    
    func resetDiagnostics() {
        touchUpdateCount = 0
        lastTouchUpdateAt = nil
        lastActiveTouchCount = 0
        gestureDecisionCount = 0
        lastGestureName = "-"
        lastActionName = "-"
        lastGestureDecisionAt = nil
        currentGestureName = "-"
        currentActionName = "-"
        recentGestureEvents = []
        lastGestureLogAt = nil
        lastGestureSignature = ""
        hidConnectCount = 0
        hidDisconnectCount = 0
        diagnosticsEvents = []
        inputProcessFrameID = 0
        inputActiveTouchCount = 0
        threeFingerTracking = false
        threeFingerTriggered = false
        threeFingerTouchCount = 0
        threeFingerUpwardTouchCount = 0
        threeFingerVerticalTravelMM = 0
        threeFingerHorizontalTravelMM = 0
        addDiagnosticsEvent("Diagnostics reset")
    }
    
    func restartInputPipeline() {
        touchManager.stop()
        forgetTouchscreenDevice()
        touchManager.start()
        addDiagnosticsEvent("Restarted HID input pipeline")
    }
    
    func refreshTouchConnection() {
        addDiagnosticsEvent("Refreshing touch connection...")

        // Rebuild HID connection and then refresh screen mapping to avoid stale assignment.
        touchManager.stop()
        forgetTouchscreenDevice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.touchManager.start()
            self.screenParametersDidChange()
            self.refreshAccessibilityStatus()
            self.addDiagnosticsEvent("Touch connection refresh requested")
        }
    }
    
    func addDiagnosticsEvent(_ message: String) {
        let applyEvent = {
            self.diagnosticsEvents.insert(DiagnosticsEvent(message: message), at: 0)
            if self.diagnosticsEvents.count > 40 {
                self.diagnosticsEvents.removeLast(self.diagnosticsEvents.count - 40)
            }
        }

        if Thread.isMainThread {
            applyEvent()
        } else {
            DispatchQueue.main.async(execute: applyEvent)
        }
    }
    
    func gestureDisplayName(_ gesture: TUCCursorGesture) -> String {
        switch gesture {
        case .TUCCursorGestureTouchDown: return "Touch Down"
        case .TUCCursorGestureTap: return "Tap"
        case .TUCCursorGestureLongPress: return "Long Press"
        case .TUCCursorGestureDrag: return "Drag (1 Finger)"
        case .TUCCursorGestureHoldAndDrag: return "Hold + Drag"
        case .TUCCursorGestureTapSecondFinger: return "Second-Finger Tap"
        case .TUCCursorGestureTwoFingerDrag: return "Two-Finger Drag"
        case .TUCCursorGesturePinch: return "Pinch"
        case .TUCCursorGestureThreeFingerSwipeUp: return "Three-Finger Swipe Up"
        case .TUCCursorGestureThreeFingerSwipeLeft: return "Three-Finger Swipe Left"
        case .TUCCursorGestureThreeFingerSwipeRight: return "Three-Finger Swipe Right"
        case .TUCCursorGestureFourFingerSwipeLeft: return "Four-Finger Swipe Left"
        case .TUCCursorGestureFiveFingerHold: return "Five-Finger Hold"
        case .TUCCursorGestureFourFingerSwipeUp: return "Four-Finger Swipe Up"
        case .TUCCursorGestureFourFingerSwipeDown: return "Four-Finger Swipe Down"
        default: return "Unknown (\(gesture.rawValue))"
        }
    }
    
    func actionDisplayName(_ action: TUCCursorAction) -> String {
        switch action {
        case .none: return "None"
        case .move: return "Move Cursor"
        case .pointAndClick: return "Point and Click"
        case .drag: return "Drag"
        case .click: return "Click"
        case .secondaryClick: return "Secondary Click"
        case .scroll: return "Scroll"
        case .magnify: return "Magnify"
        case .missionControl: return "Mission Control"
        case .keyboardShortcutHold: return "Hold Shortcut"
        case .keyboardShortcutSequence: return "Shortcut Sequence"
        case .floatingKeyboard: return "Floating Keyboard"
        case .hideFloatingKeyboard: return "Hide Floating Keyboard"
        case .switchToLeftSpace: return "Space on the Left"
        case .switchToRightSpace: return "Space on the Right"
        @unknown default: return "Unknown"
        }
    }
    
    func addGestureEventIfNeeded(gestureName: String, actionName: String) {
        let signature = "\(gestureName)->\(actionName)"
        let now = Date()
        let shouldLog: Bool
        if signature != lastGestureSignature {
            shouldLog = true
        } else if let lastGestureLogAt {
            shouldLog = now.timeIntervalSince(lastGestureLogAt) >= 0.25
        } else {
            shouldLog = true
        }
        
        if shouldLog {
            recentGestureEvents.insert(DiagnosticsEvent(message: "\(gestureName) -> \(actionName)"), at: 0)
            if recentGestureEvents.count > 24 {
                recentGestureEvents.removeLast(recentGestureEvents.count - 24)
            }
            lastGestureSignature = signature
            lastGestureLogAt = now
        }
    }
    
    func suggestedBlocker() -> String {
        if !accessibilityTrustedNow {
            return "Accessibility permission is not active."
        }
        if isInputMonitoringNeeded {
            return "The touchscreen can't be read: allow Input Monitoring."
        }
        if !isPublishingMouseEventsEnabled {
            return "Mouse event publishing is OFF."
        }
        if !connectionState.isConnected {
            return "No touchscreen HID connection detected."
        }
        if touchUpdateCount == 0 {
            return "No touch reports received yet."
        }
        return "Touch reports are flowing. If output still fails, inspect diagnostics and restart input pipeline."
    }
    
    func sendTestClickAtCursor() {
        let loc = NSEvent.mouseLocation
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: loc, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) else {
            addDiagnosticsEvent("Failed to build test click events")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        addDiagnosticsEvent("Posted test click at cursor")
    }
    
    func sendTestScroll() {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -80, wheel2: 0, wheel3: 0) else {
            addDiagnosticsEvent("Failed to build test scroll event")
            return
        }
        event.post(tap: .cghidEventTap)
        addDiagnosticsEvent("Posted test scroll event")
    }
    
}


// MARK: - Loading, Saving and Syncing Settings with Framework
extension TouchMyMac {
    
    func initPreferences() {
        let defaults = UserDefaults.standard
        
        defaults.register(defaults: [
            "holdDuration" : 0.4,
            "doubleClickDistance" : 8,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isThreeFingerSwipeEnabled" : true,
            "isThreeFingerSwipeSpacesEnabled" : true,
            "isControlDragEnabled" : true,
            "isFourFingerSwipeUpKeyboardEnabled" : true,
            "fiveFingerHoldShortcutSpec" : "fn",
            "fourFingerSwipeLeftSequenceSpec" : "cmd+a, delete",
            "isScrollInertiaEnabled" : true,
            "isCursorHiddenWhileScrolling" : true,
            "scrollSpeedMultiplier" : 1.0,
            "pinchZoomSpeed" : 1.5,
            "scrollInertiaDecelerationPerFrame" : 0.92,
            "scrollInertiaVelocityMultiplier" : 1.0
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
        if holdDuration < 0.2 {
            // Before 1.8 a hold started after 0.1 s, shorter than many taps, so taps turned into presses.
            holdDuration = 0.4
        }
        doubleClickDistance = defaults.double(forKey: "doubleClickDistance")
        errorResistance = defaults.integer(forKey: "errorResistance")
        ignoreOriginTouches = defaults.bool(forKey: "ignoreOriginTouches")
        defaults.removeObject(forKey: "primaryInteractionMode")
        defaults.removeObject(forKey: "isClickWindowToFrontEnabled")
        
        
        self.observers = [
            $isPublishingMouseEventsEnabled.assign(to: \.postMouseEvents, on: touchManager),
            $holdDuration.assign(to: \.holdDuration, on: touchManager),
            $doubleClickDistance.assign(to: \.doubleClickTolerance, on: touchManager),
            $errorResistance.assign(to: \.errorResistance, on: touchManager),
            $ignoreOriginTouches.assign(to: \.ignoreOriginTouches, on: touchManager),
            $isThreeFingerSwipeEnabled.assign(to: \.threeFingerSwipeEnabled, on: touchManager),
            $isThreeFingerSwipeSpacesEnabled.assign(to: \.threeFingerSwipeSpacesEnabled, on: touchManager),
            $isControlDragEnabled.assign(to: \.dragsControlsDirectly, on: touchManager),
            $isFourFingerSwipeUpKeyboardEnabled.assign(to: \.fourFingerSwipeUpKeyboardEnabled, on: touchManager),
            $fiveFingerHoldShortcutSpec.assign(to: \.fiveFingerHoldShortcutSpec, on: touchManager),
            $fourFingerSwipeLeftSequenceSpec.assign(to: \.fourFingerSwipeLeftSequenceSpec, on: touchManager),
            $isScrollInertiaEnabled.assign(to: \.scrollInertiaEnabled, on: touchManager),
            $isCursorHiddenWhileScrolling.assign(to: \.hidesCursorWhileScrolling, on: touchManager),
            $scrollSpeedMultiplier.assign(to: \.scrollSpeedMultiplier, on: touchManager),
            $pinchZoomSpeed.assign(to: \.pinchZoomSpeed, on: touchManager),
            $scrollInertiaDecelerationPerFrame.assign(to: \.scrollInertiaDecelerationPerFrame, on: touchManager),
            $scrollInertiaVelocityMultiplier.assign(to: \.scrollInertiaVelocityMultiplier, on: touchManager)
        ]
        
        
        
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isThreeFingerSwipeEnabled = defaults.bool(forKey: "isThreeFingerSwipeEnabled")
        isThreeFingerSwipeSpacesEnabled = defaults.bool(forKey: "isThreeFingerSwipeSpacesEnabled")
        isControlDragEnabled = defaults.bool(forKey: "isControlDragEnabled")
        isFourFingerSwipeUpKeyboardEnabled = defaults.object(forKey: "isFourFingerSwipeUpKeyboardEnabled") as? Bool ?? true
        fiveFingerHoldShortcutSpec = defaults.string(forKey: "fiveFingerHoldShortcutSpec") ?? "fn"
        let savedFourFingerSequence = defaults.string(forKey: "fourFingerSwipeLeftSequenceSpec")
        if let savedFourFingerSequence, !savedFourFingerSequence.isEmpty {
            fourFingerSwipeLeftSequenceSpec = (savedFourFingerSequence == "ctrl+a, delete") ? "cmd+a, delete" : savedFourFingerSequence
        } else {
            fourFingerSwipeLeftSequenceSpec = "cmd+a, delete"
        }
        touchManager.threeFingerSwipeEnabled = isThreeFingerSwipeEnabled
        touchManager.threeFingerSwipeSpacesEnabled = isThreeFingerSwipeSpacesEnabled
        touchManager.dragsControlsDirectly = isControlDragEnabled
        touchManager.fourFingerSwipeUpKeyboardEnabled = isFourFingerSwipeUpKeyboardEnabled
        touchManager.fiveFingerHoldShortcutSpec = fiveFingerHoldShortcutSpec
        touchManager.fourFingerSwipeLeftSequenceSpec = fourFingerSwipeLeftSequenceSpec

        isScrollInertiaEnabled = defaults.bool(forKey: "isScrollInertiaEnabled")
        isCursorHiddenWhileScrolling = defaults.bool(forKey: "isCursorHiddenWhileScrolling")
        touchManager.hidesCursorWhileScrolling = isCursorHiddenWhileScrolling
        scrollSpeedMultiplier = CGFloat(defaults.double(forKey: "scrollSpeedMultiplier"))
        pinchZoomSpeed = CGFloat(defaults.double(forKey: "pinchZoomSpeed"))
        touchManager.pinchZoomSpeed = pinchZoomSpeed
        scrollInertiaDecelerationPerFrame = CGFloat(defaults.double(forKey: "scrollInertiaDecelerationPerFrame"))
        scrollInertiaVelocityMultiplier = CGFloat(defaults.double(forKey: "scrollInertiaVelocityMultiplier"))
        touchManager.scrollInertiaEnabled = isScrollInertiaEnabled
        touchManager.scrollSpeedMultiplier = scrollSpeedMultiplier
        touchManager.scrollInertiaDecelerationPerFrame = scrollInertiaDecelerationPerFrame
        touchManager.scrollInertiaVelocityMultiplier = scrollInertiaVelocityMultiplier
    }
    
    
    func savePreferences() {
        let defaults = UserDefaults.standard
        
        defaults.set(holdDuration, forKey: "holdDuration")
        defaults.set(doubleClickDistance, forKey: "doubleClickDistance")
        defaults.set(errorResistance, forKey: "errorResistance")
        defaults.set(ignoreOriginTouches, forKey: "ignoreOriginTouches")
        
        defaults.set(isSecondaryClickEnabled, forKey: "isSecondaryClickEnabled")
        defaults.set(isMagnificationEnabled, forKey: "isMagnificationEnabled")
        defaults.set(isThreeFingerSwipeEnabled, forKey: "isThreeFingerSwipeEnabled")
        defaults.set(isThreeFingerSwipeSpacesEnabled, forKey: "isThreeFingerSwipeSpacesEnabled")
        defaults.set(isControlDragEnabled, forKey: "isControlDragEnabled")
        defaults.set(isFourFingerSwipeUpKeyboardEnabled, forKey: "isFourFingerSwipeUpKeyboardEnabled")
        defaults.set(fiveFingerHoldShortcutSpec, forKey: "fiveFingerHoldShortcutSpec")
        defaults.set(fourFingerSwipeLeftSequenceSpec, forKey: "fourFingerSwipeLeftSequenceSpec")

        defaults.set(isScrollInertiaEnabled, forKey: "isScrollInertiaEnabled")
        defaults.set(isCursorHiddenWhileScrolling, forKey: "isCursorHiddenWhileScrolling")
        defaults.set(Double(scrollSpeedMultiplier), forKey: "scrollSpeedMultiplier")
        defaults.set(Double(pinchZoomSpeed), forKey: "pinchZoomSpeed")
        defaults.set(Double(scrollInertiaDecelerationPerFrame), forKey: "scrollInertiaDecelerationPerFrame")
        defaults.set(Double(scrollInertiaVelocityMultiplier), forKey: "scrollInertiaVelocityMultiplier")
    }
    
}



extension TouchMyMac: TUCTouchDelegate {
    func performUIUpdate(_ updates: @escaping () -> Void) {
        if Thread.isMainThread {
            updates()
        } else {
            DispatchQueue.main.async(execute: updates)
        }
    }

    func captureTouchManagerDiagnostics() -> TouchManagerDiagnosticsSnapshot {
        TouchManagerDiagnosticsSnapshot(
            inputProcessFrameID: Int(touchManager.debugProcessFrameID),
            inputActiveTouchCount: Int(touchManager.debugActiveTouchCount),
            threeFingerTracking: touchManager.debugThreeFingerTracking,
            threeFingerTriggered: touchManager.debugThreeFingerTriggered,
            threeFingerTouchCount: Int(touchManager.debugThreeFingerTouchCount),
            threeFingerUpwardTouchCount: Int(touchManager.debugThreeFingerUpwardTouchCount),
            threeFingerVerticalTravelMM: touchManager.debugThreeFingerVerticalTravelMM,
            threeFingerHorizontalTravelMM: touchManager.debugThreeFingerHorizontalTravelMM
        )
    }

    func applyTouchManagerDiagnostics(_ snapshot: TouchManagerDiagnosticsSnapshot) {
        inputProcessFrameID = snapshot.inputProcessFrameID
        inputActiveTouchCount = snapshot.inputActiveTouchCount
        threeFingerTracking = snapshot.threeFingerTracking
        threeFingerTriggered = snapshot.threeFingerTriggered
        threeFingerTouchCount = snapshot.threeFingerTouchCount
        threeFingerUpwardTouchCount = snapshot.threeFingerUpwardTouchCount
        threeFingerVerticalTravelMM = snapshot.threeFingerVerticalTravelMM
        threeFingerHorizontalTravelMM = snapshot.threeFingerHorizontalTravelMM
    }

    func touchesDidChange() {
        let touchSnapshot = (self.touchManager.touchSet.allObjects as? [TUCTouch]) ?? []
        let lastTouchUpdateAt = Date()
        let activeTouchCount = touchSnapshot.filter { $0.isActive() }.count
        let diagnosticsSnapshot = captureTouchManagerDiagnostics()

        performUIUpdate {
            self.touches = touchSnapshot
            self.touchUpdateCount += 1
            self.lastTouchUpdateAt = lastTouchUpdateAt
            self.lastActiveTouchCount = activeTouchCount
            self.applyTouchManagerDiagnostics(diagnosticsSnapshot)
        }
    }

    func inputDiagnosticsDidChange() {
        let diagnosticsSnapshot = captureTouchManagerDiagnostics()
        performUIUpdate {
            self.applyTouchManagerDiagnostics(diagnosticsSnapshot)
        }
    }
    
    
    func touchscreen() -> TUCScreen? {
        self.connectedTouchscreen ?? Self.likelyTouchscreen(in: self.connectedScreens)
    }

    
    func action(for gesture: TUCCursorGesture) -> TUCCursorAction {
        let action: TUCCursorAction
        switch gesture {
        case .TUCCursorGestureTouchDown:
            action = .move
            
        case .TUCCursorGestureTap:
            action = .click
            
        case .TUCCursorGestureLongPress:
            action = .click
            
        case .TUCCursorGestureDrag:
            action = .scroll
            
        case .TUCCursorGestureHoldAndDrag:
            action = .drag
            
        case .TUCCursorGestureTapSecondFinger:
            action = isSecondaryClickEnabled ? .secondaryClick : .none
            
        case .TUCCursorGestureTwoFingerDrag:
            action = .scroll
            
        case .TUCCursorGesturePinch:
            action = isMagnificationEnabled ? .magnify : .none

        case .TUCCursorGestureThreeFingerSwipeUp:
            action = .missionControl

        // Like a trackpad, the content follows the fingers: swiping left brings in the space on the right.
        case .TUCCursorGestureThreeFingerSwipeLeft:
            action = isThreeFingerSwipeSpacesEnabled ? .switchToRightSpace : .none

        case .TUCCursorGestureThreeFingerSwipeRight:
            action = isThreeFingerSwipeSpacesEnabled ? .switchToLeftSpace : .none

        case .TUCCursorGestureFourFingerSwipeLeft:
            action = .keyboardShortcutSequence

        case .TUCCursorGestureFiveFingerHold:
            action = .keyboardShortcutHold

        case .TUCCursorGestureFourFingerSwipeUp:
            action = isFourFingerSwipeUpKeyboardEnabled ? .floatingKeyboard : .none

        case .TUCCursorGestureFourFingerSwipeDown:
            action = isFourFingerSwipeUpKeyboardEnabled ? .hideFloatingKeyboard : .none
            
        default:
            action = .none
        }
        
        let gestureName = gestureDisplayName(gesture)
        let actionName = actionDisplayName(action)
        performUIUpdate {
            self.gestureDecisionCount += 1
            self.lastGestureDecisionAt = Date()
            self.lastGestureName = gestureName
            self.lastActionName = actionName
            self.currentGestureName = gestureName
            self.currentActionName = actionName
            self.addGestureEventIfNeeded(gestureName: gestureName, actionName: actionName)
        }
        
        return action
    }
    
    
    
    func touchscreenDidConnect() {
        let name = touchManager.connectedTouchscreenName ?? "Touchscreen"
        performUIUpdate {
            self.hidConnectCount += 1
            self.addDiagnosticsEvent("Touchscreen HID connected: \(name)")
            self.touchscreenDeviceName = name
            self.lastDateUSBAdded = Date()

            if !self.identifyPreferredOrNoScreen() && !self.identifyHotPlug() {
                self.keepOrPickFallbackScreen()
            }
            self.updateConnectionState()
        }
    }
    
    func touchscreenDidDisconnect() {
        performUIUpdate {
            self.hidDisconnectCount += 1
            self.addDiagnosticsEvent("Touchscreen HID disconnected")
            self.touchscreenDeviceName = nil
            self.updateConnectionState()
        }
    }

    func touchDidBeginLongPress(atScreenLocation location: CGPoint) {
        performUIUpdate {
            (NSApp.delegate as? AppDelegate)?.pressIndicatorPanel.show(atScreenLocation: location)
        }
    }

    func touchLongPressDidMove(toScreenLocation location: CGPoint) {
        performUIUpdate {
            (NSApp.delegate as? AppDelegate)?.pressIndicatorPanel.move(toScreenLocation: location)
        }
    }

    func touchDidEndLongPress() {
        performUIUpdate {
            (NSApp.delegate as? AppDelegate)?.pressIndicatorPanel.hide()
        }
    }

    func performCustomAction(_ action: TUCCursorAction) {
        performUIUpdate {
            switch action {
            case .floatingKeyboard:
                (NSApp.delegate as? AppDelegate)?.showFloatingKeyboard()
            case .hideFloatingKeyboard:
                (NSApp.delegate as? AppDelegate)?.hideFloatingKeyboard()
            default:
                break
            }
        }
    }

    func shouldClaimTouch(_ touchID: UUID, atScreenLocation location: CGPoint) -> Bool {
        guard let keyboard = floatingKeyboard, keyboard.isVisible else { return false }
        return keyboard.keyboardView.beginTouch(touchID, atScreenLocation: location)
    }

    func claimedTouchDidEnd(_ touchID: UUID) {
        floatingKeyboard?.keyboardView.endTouch(touchID)
    }

    func claimedTouchDidMove(_ touchID: UUID, toScreenLocation location: CGPoint) {
        floatingKeyboard?.keyboardView.moveTouch(touchID, toScreenLocation: location)
    }

    func claimedTouchesDidBecomeGesture() {
        floatingKeyboard?.keyboardView.cancelForGesture()
    }
}


extension TouchMyMac {
    func uiLabels<T>(for keyPath: KeyPath<TouchMyMac, T>) -> (title:String, description:String) {
        switch keyPath {
        case \.isPublishingMouseEventsEnabled:
            return(L("Control Mouse with Touch"),
                   L("Turns the driver on or off."))
            
        case \.opensAtLogin:
            return(L("Open at Login"),
                   L("Starts TouchMyMac when you log in, so the touchscreen works right away."))

        case \.connectedTouchscreen:
            return(L("Assign Mouse Events to"),
                   L("Specifies which screen should receive the touch events."))
            
        case \.isSecondaryClickEnabled:
            return(L("Secondary Click"),
                   L("Tap the screen with two fingers at once to secondary click at the first finger, like on a Mac trackpad."))
            
        case \.isMagnificationEnabled:
            return(L("Magnification"),
                   L("Pinch two fingers to increase or decrease the size of the content. (EXPERIMENTAL)"))

        case \.isThreeFingerSwipeEnabled:
            return(L("Three-Finger Swipe Up"),
                   L("Swipe up with three fingers to open Mission Control."))

        case \.isControlDragEnabled:
            return(L("Drag Controls Directly"),
                   L("Sliders, scroll bars, dividers, window title bars and window edges follow your finger right away, even if your finger lands a little beside a divider or edge. Elsewhere, dragging scrolls unless you hold still first."))

        case \.isThreeFingerSwipeSpacesEnabled:
            return(L("Three-Finger Swipe Left / Right"),
                   L("Swipe left or right with three fingers to move between spaces and full-screen apps."))

        case \.isFourFingerSwipeUpKeyboardEnabled:
            return(L("Four-Finger Swipe Up Keyboard"),
                   L("Swipe up with four fingers to show the floating keyboard, and swipe down with four fingers to hide it."))

        case \.fiveFingerHoldShortcutSpec:
            return(L("Five-Finger Hold Shortcut"),
                   L("Hold five fingers still to keep a shortcut chord pressed. Example: fn or cmd+shift."))

        case \.fourFingerSwipeLeftSequenceSpec:
            return(L("Four-Finger Left Swipe Sequence"),
                   L("Swipe left with four fingers to fire a shortcut sequence. Example: cmd+a, delete."))
            
        case \.holdDuration:
            return(L("Hold Duration"),
                   L("Hold a finger still this long to press the mouse button. Then move to drag, for example to select text or move files."))
            
        case \.doubleClickDistance:
            return(L("Double Click Zone"),
                   L("How many mm can two taps be apart from each other to qualify double click"))
            
        case \.ignoreOriginTouches:
            return(L("Ignore Origin Touches"),
                   L("If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable."))
            
        case \.errorResistance:
            return(L("Error Resistance"),
                   L("If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs."))

        case \.isCursorHiddenWhileScrolling:
            return(L("Hide Pointer While Scrolling"),
                   L("Scrolling leaves the pointer where it was, so it's hidden while your finger scrolls."))

        case \.isScrollInertiaEnabled:
            return(L("Scroll Inertia"),
                   L("Keeps scrolling for a short time after you lift your finger (iPad-like)."))

        case \.pinchZoomSpeed:
            return(L("Pinch Zoom Speed"),
                   L("At 1.0 content zooms exactly as far as your fingers spread. Higher values zoom further for the same spread, so one hand reaches larger sizes."))

        case \.scrollSpeedMultiplier:
            return(L("Scroll Speed"),
                   L("Scales regular one-finger drag scrolling. Higher values scroll faster for the same finger travel."))

        case \.scrollInertiaDecelerationPerFrame:
            return(L("Decay Speed"),
                   L("Higher values decay slower; lower values decay faster."))

        case \.scrollInertiaVelocityMultiplier:
            return(L("Inertia Amount"),
                   L("Scales how far scrolling glides after you lift your finger."))
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain // touchscreen connected, but no display to map it to
    case disconnected // no touchscreen HID device
    case connectedAuto // connected, mapped to a display picked automatically
    case connectedPreferred // connected, mapped to the display the user picked

    var isConnected: Bool {
        return self == .connectedPreferred || self == .connectedAuto
    }

    var displayName: String {
        switch self {
        case .uncertain: return L("Connected, no display")
        case .disconnected: return L("Not connected")
        case .connectedAuto: return L("Connected (display picked automatically)")
        case .connectedPreferred: return L("Connected")
        }
    }
}
                 
                 
extension TUCScreen: Identifiable {
    func matching(name:String, id:UInt) -> Float {
        let sameName = self.name == name
        let sameID = self.id == id
        
        if sameName && sameID { return 1 }
        else if sameName { return 0.5 }
        else if sameID { return 0.2 }
        else { return 0}
    }
}


// MARK: - Open at Login
extension TouchMyMac {

    var languageNeedsRestart: Bool {
        appLanguage != launchLanguage
    }

    func setAppLanguage(_ language: AppLanguage) {
        language.save()
        appLanguage = language
    }

    /// Quits and opens the app again, so a new language takes effect.
    func relaunch() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open '\(path)'"]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            addDiagnosticsEvent("Relaunch failed: \(error.localizedDescription)")
        }
    }

    static var loginItemTurnedOffNote: String {
        L("Turned off in System Settings → General → Login Items. Allow TouchMyMac there.")
    }

    var canOpenAtLogin: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    func refreshOpensAtLogin() {
        guard #available(macOS 13.0, *) else {
            opensAtLogin = false
            openAtLoginNote = L("Needs macOS 13 or later. Add TouchMyMac in System Settings → Users & Groups → Login Items instead.")
            return
        }
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        if status == .requiresApproval {
            openAtLoginNote = Self.loginItemTurnedOffNote
        } else if openAtLoginNote == Self.loginItemTurnedOffNote {
            openAtLoginNote = nil
        }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            openAtLoginNote = nil
        } catch {
            openAtLoginNote = String(format: L("Couldn't change the login item: %@"), error.localizedDescription)
            addDiagnosticsEvent("Open at Login failed: \(error.localizedDescription)")
        }
        refreshOpensAtLogin()
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
