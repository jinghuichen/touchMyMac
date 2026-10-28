//
//  Model.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import AppKit
import Combine
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
    
    @Published var connectionState: ConnectionState = .disconnected
    
    
    
    @Published var holdDuration: TimeInterval = 0.1
    @Published var doubleClickDistance: CGFloat = 3 //mm
    @Published var errorResistance: NSInteger = 0 // num of Reports to wait before cancelling a touch
    @Published var ignoreOriginTouches: Bool = false
    
    
    
    @Published var isSecondaryClickEnabled = false
    @Published var isMagnificationEnabled = false
    @Published var isThreeFingerSwipeEnabled = true
    @Published var isThreeFingerSwipeSpacesEnabled = true
    @Published var isFourFingerSwipeUpKeyboardEnabled = true
    @Published var fiveFingerHoldShortcutSpec: String = "fn"
    @Published var fourFingerSwipeLeftSequenceSpec: String = "cmd+a, delete"

    @Published var isScrollInertiaEnabled = true
    @Published var scrollSpeedMultiplier: CGFloat = 1.0
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
    }
    
    
    /**
     returns true, if the screen list contained the preferred screen which is now assigned the touch screen.
     if screen list empty, it removes the assigned touch screen.
     */
    @discardableResult func identifyPreferredOrNoScreen() -> Bool {
        let cues = identificationCues
        
        
        if connectedScreens.count == 0 {
            self.connectedTouchscreen = nil
            self.connectionState = .uncertain
            print("OH NO SCREEN")
            return true
        }
        
       
        
        if let perfectMatch = connectedScreens.first(where: { $0.matching(name: cues.name, id: cues.id) == 1}) {
            self.connectedTouchscreen = perfectMatch
            self.connectionState = lastDateUSBAdded == nil ? .connectedPreferred : .connectedHotPlug
            print("PREFERRED SCREEN FOUND")
            return true
        }
        
        return false
    }
    
    
    @discardableResult func identifyHotPlug() -> Bool {
        // if the USB cable of a touch screen was plugged in within last 10 seconds, assign this to the touchscreen
        
        // no need to hot plug during existing connection
        if self.connectionState.isConnected {
            print("HOTPLUG SKIPPED")
            return false
        }
        
        if let lastDateUSBAdded, let lastDateScreenAdded, let idOfLastAddedScreen {
            if Date().timeIntervalSince(lastDateUSBAdded) < hotPlugTimeInterval
                && Date().timeIntervalSince(lastDateScreenAdded) < hotPlugTimeInterval {
                
                
                if let screen = self.connectedScreens.first(where: {$0.id == idOfLastAddedScreen}) {
                    self.connectedTouchscreen = screen
                    let cues = identificationCues
                    let match = screen.matching(name: cues.name, id: cues.id)
                    self.connectionState = match == 1 ? .connectedPreferred : .connectedHotPlug
                    print("HOTPLUG SUCCESS")
                    return true
                }
                
                print("HOTPLUG FAIL")
            }
        }
        
        return false
    }
    
    
    @objc func screenParametersDidChange() {
        // identify which screen is newly added.
        let oldScreenList = self.connectedScreens
        self.connectedScreens = TUCScreen.allScreens() as! [TUCScreen]
        
        // a new screen appeared!
        if connectedScreens.count > oldScreenList.count {
            self.lastDateScreenAdded = Date()
            
            let new = connectedScreens.first { s in
                !(oldScreenList.contains(where: {$0.id == s.id}))
            }
            if let new {
                self.idOfLastAddedScreen = new.id
                identifyHotPlug()
            }
        }
        
        // search for the preferred screen, also important if user rearranged screens (and screen numbers)
        if !self.identifyPreferredOrNoScreen() {
            self.connectedTouchscreen = self.connectedScreens.last
        }
    }
    
    
    func checkAccessibilityAccessGranted() {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        self.isAccessibilityAccessGranted = AXIsProcessTrustedWithOptions([checkOptPrompt: true] as CFDictionary?)
    }
    
    var accessibilityTrustedNow: Bool {
        AXIsProcessTrusted()
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

        initPreferences()
        
        checkAccessibilityAccessGranted()
        addDiagnosticsEvent("Initialized model")
    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        touchManager.start()
        addDiagnosticsEvent("Restarted HID input pipeline")
    }
    
    func refreshTouchConnection() {
        addDiagnosticsEvent("Refreshing touch connection...")
        connectionState = .uncertain
        
        // Rebuild HID connection and then refresh screen mapping to avoid stale assignment.
        touchManager.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.touchManager.start()
            self.screenParametersDidChange()
            self.checkAccessibilityAccessGranted()
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
            "holdDuration" : 0.1,
            "doubleClickDistance" : 8,
            "errorResistance" : 4,
            "ignoreOriginTouches" : true,
            "isSecondaryClickEnabled" : true,
            "isMagnificationEnabled" : true,
            "isThreeFingerSwipeEnabled" : true,
            "isThreeFingerSwipeSpacesEnabled" : true,
            "isFourFingerSwipeUpKeyboardEnabled" : true,
            "fiveFingerHoldShortcutSpec" : "fn",
            "fourFingerSwipeLeftSequenceSpec" : "cmd+a, delete",
            "isScrollInertiaEnabled" : true,
            "scrollSpeedMultiplier" : 1.0,
            "scrollInertiaDecelerationPerFrame" : 0.92,
            "scrollInertiaVelocityMultiplier" : 1.0
        ])
        
        holdDuration = defaults.double(forKey: "holdDuration")
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
            $isFourFingerSwipeUpKeyboardEnabled.assign(to: \.fourFingerSwipeUpKeyboardEnabled, on: touchManager),
            $fiveFingerHoldShortcutSpec.assign(to: \.fiveFingerHoldShortcutSpec, on: touchManager),
            $fourFingerSwipeLeftSequenceSpec.assign(to: \.fourFingerSwipeLeftSequenceSpec, on: touchManager),
            $isScrollInertiaEnabled.assign(to: \.scrollInertiaEnabled, on: touchManager),
            $scrollSpeedMultiplier.assign(to: \.scrollSpeedMultiplier, on: touchManager),
            $scrollInertiaDecelerationPerFrame.assign(to: \.scrollInertiaDecelerationPerFrame, on: touchManager),
            $scrollInertiaVelocityMultiplier.assign(to: \.scrollInertiaVelocityMultiplier, on: touchManager)
        ]
        
        
        
        isSecondaryClickEnabled = defaults.bool(forKey: "isSecondaryClickEnabled")
        isMagnificationEnabled = defaults.bool(forKey: "isMagnificationEnabled")
        isThreeFingerSwipeEnabled = defaults.bool(forKey: "isThreeFingerSwipeEnabled")
        isThreeFingerSwipeSpacesEnabled = defaults.bool(forKey: "isThreeFingerSwipeSpacesEnabled")
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
        touchManager.fourFingerSwipeUpKeyboardEnabled = isFourFingerSwipeUpKeyboardEnabled
        touchManager.fiveFingerHoldShortcutSpec = fiveFingerHoldShortcutSpec
        touchManager.fourFingerSwipeLeftSequenceSpec = fourFingerSwipeLeftSequenceSpec

        isScrollInertiaEnabled = defaults.bool(forKey: "isScrollInertiaEnabled")
        scrollSpeedMultiplier = CGFloat(defaults.double(forKey: "scrollSpeedMultiplier"))
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
        defaults.set(isFourFingerSwipeUpKeyboardEnabled, forKey: "isFourFingerSwipeUpKeyboardEnabled")
        defaults.set(fiveFingerHoldShortcutSpec, forKey: "fiveFingerHoldShortcutSpec")
        defaults.set(fourFingerSwipeLeftSequenceSpec, forKey: "fourFingerSwipeLeftSequenceSpec")

        defaults.set(isScrollInertiaEnabled, forKey: "isScrollInertiaEnabled")
        defaults.set(Double(scrollSpeedMultiplier), forKey: "scrollSpeedMultiplier")
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
        self.connectedTouchscreen ?? self.connectedScreens.last
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
        performUIUpdate {
            self.hidConnectCount += 1
            self.addDiagnosticsEvent("Touchscreen HID connected")
            self.lastDateScreenAdded = Date()
            
            if !self.identifyHotPlug() {
                if self.connectionState.isConnected {
                    self.connectionState = .uncertain
                }
            }
            
            self.identifyPreferredOrNoScreen()
        }
    }
    
    func touchscreenDidDisconnect() {
        performUIUpdate {
            self.hidDisconnectCount += 1
            self.addDiagnosticsEvent("Touchscreen HID disconnected")
            self.connectionState = .disconnected
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
            return("Control Mouse with Touch",
                   "Turns the driver on or off.")
            
        case \.connectedTouchscreen:
            return("Assign Mouse Events to",
                   "Specifies which screen should receive the touch events.")
            
        case \.isSecondaryClickEnabled:
            return("Secondary Click",
                   "Tap the screen with two fingers at once to secondary click at the first finger, like on a Mac trackpad.")
            
        case \.isMagnificationEnabled:
            return("Magnification",
                   "Pinch two fingers to increase or decrease the size of the content. (EXPERIMENTAL)")

        case \.isThreeFingerSwipeEnabled:
            return("Three-Finger Swipe Up",
                   "Swipe up with three fingers to open Mission Control.")

        case \.isThreeFingerSwipeSpacesEnabled:
            return("Three-Finger Swipe Left / Right",
                   "Swipe left or right with three fingers to move between spaces and full-screen apps.")

        case \.isFourFingerSwipeUpKeyboardEnabled:
            return("Four-Finger Swipe Up Keyboard",
                   "Swipe up with four fingers to show the floating keyboard, and swipe down with four fingers to hide it.")

        case \.fiveFingerHoldShortcutSpec:
            return("Five-Finger Hold Shortcut",
                   "Hold five fingers still to keep a shortcut chord pressed. Example: fn or cmd+shift.")

        case \.fourFingerSwipeLeftSequenceSpec:
            return("Four-Finger Left Swipe Sequence",
                   "Swipe left with four fingers to fire a shortcut sequence. Example: cmd+a, delete.")
            
        case \.holdDuration:
            return("Hold Duration",
                   "How long do you have to hold finger to initiate hold&drag")
            
        case \.doubleClickDistance:
            return("Double Click Zone",
                   "How many mm can two taps be apart from each other to qualify double click")
            
        case \.ignoreOriginTouches:
            return("Ignore Origin Touches",
                   "If your touchscreen randomly sends coordinate (0,0) in its datastream, toggle this option to make input more stable.")
            
        case \.errorResistance:
            return("Error Resistance",
                   "If your touchscreen is really unreliable at reporting touches, increase this slider to make inputs more stable at the cost of higher latency in detecting liftoffs.")

        case \.isScrollInertiaEnabled:
            return("Scroll Inertia",
                   "Keeps scrolling for a short time after you lift your finger (iPad-like).")

        case \.scrollSpeedMultiplier:
            return("Scroll Speed",
                   "Scales regular one-finger drag scrolling. Higher values scroll faster for the same finger travel.")

        case \.scrollInertiaDecelerationPerFrame:
            return("Decay Speed",
                   "Higher values decay slower; lower values decay faster.")

        case \.scrollInertiaVelocityMultiplier:
            return("Inertia Amount",
                   "Scales how far scrolling glides after you lift your finger.")
            
        default:
            return("\(keyPath)", "")
        }
    }
}


enum ConnectionState: Int {
    case uncertain
    case disconnected
    case connectedHotPlug // connected as result from hot plugging within a few seconds
    case connectedPreferred // connected with stored cues matching perfectly
    
    var image: NSImage? {
        let image: NSImage?
        
        switch self {
        case .uncertain:
            image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        case .disconnected:
            image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: nil)
        default:
            image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        }

        image?.isTemplate = true
        
        return image
    }
    
    var isConnected: Bool {
        return self == .connectedPreferred || self == .connectedHotPlug
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
