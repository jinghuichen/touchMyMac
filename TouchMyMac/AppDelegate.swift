//
//  AppDelegate.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import Cocoa
import SwiftUI
import Combine
import Carbon.HIToolbox


@main
class AppDelegate: NSObject, NSApplicationDelegate {

    let model = TouchMyMac()
    
    
    var statusItem: NSStatusItem!
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var activationMenuItem: NSMenuItem!
    
    var observers = [AnyCancellable]()
    
    
    
    lazy var settingsWindow: SettingsWindow = {
        return SettingsWindow.window(model: self.model)
    }()
    
    lazy var debugOverlay: DebugOverlay = {
        return DebugOverlay.overlay(model: self.model)
    }()

    lazy var floatingKeyboardPanel: FloatingKeyboardPanel = {
        return FloatingKeyboardPanel(model: self.model)
    }()
    
    @IBAction func toggleActivationMenu(_ sender: Any) {
        self.model.isPublishingMouseEventsEnabled.toggle()
    }
    
    
    
    //MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem.menu = self.statusMenu
        
        self.observers.append(
            self.model.$connectionState
                .receive(on: DispatchQueue.main)
                .sink{status in
                    DispatchQueue.main.async {
                        self.statusItem.button?.image = status.image
                    }
                    
                }
        )
        
        self.observers.append(
            self.model.$isPublishingMouseEventsEnabled
                .receive(on: DispatchQueue.main)
                .sink{
                    self.activationMenuItem.state = $0 ? .on : .off
                }
        )
        
        self.model.touchManager.start()
        
        
        if !model.isAccessibilityAccessGranted {
            self.showPreferences(nil)
        }
        
        #if DEBUG
//        self.showPreferences(nil)
//        self.showDebugOverlay()
        #endif
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        self.model.touchManager.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    
    @IBAction func showPreferences(_ sender: Any?) {
        self.settingsWindow.makeVisible()
    }
    
    func showDebugOverlay() {
        let preState = self.model.isPublishingMouseEventsEnabled
        self.model.isPublishingMouseEventsEnabled = false
        DebugOverlay.completion = {[unowned self] in
            self.debugOverlay.close()
            self.model.isPublishingMouseEventsEnabled = preState
        }
        
        self.debugOverlay.makeVisible()
    }

    func showFloatingKeyboard() {
        self.floatingKeyboardPanel.makeVisible()
    }

    func hideFloatingKeyboard() {
        self.floatingKeyboardPanel.orderOut(nil)
    }
}



class SettingsWindow: NSWindow {
    
    var model: TouchMyMac?
    
    static func window(model: TouchMyMac) -> SettingsWindow {
        let vc = NSHostingController(rootView: SettingsView(model:model))
        let window = SettingsWindow(contentRect: .zero,
                                    styleMask: [.closable, .titled, .fullSizeContentView, .resizable],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "TouchMyMac Settings"
        window.tabbingMode = .disallowed
        window.model = model
        // A regular window: it goes behind other apps once you click elsewhere,
        // and the menu bar item brings it back to the current Space.
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        return window
    }
    
    override func close() {
        self.model?.savePreferences()
        NSApp.stopModal()
        super.close()
    }
    
    func makeVisible() {
        let alreadyOnScreen = self.isVisible
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !alreadyOnScreen {
            self.center()
        }
        
    }
}



class DebugOverlay: NSWindow {
    
    var model: TouchMyMac?
    static var completion: (()->Void)?
    
    static func overlay(model: TouchMyMac) -> DebugOverlay {
        let vc = NSHostingController(rootView: DebugView(model:model, closeAction: {
            DebugOverlay.completion?()
        }))
        
        let window = DebugOverlay(contentRect: .zero,
                                    styleMask: [.resizable, .miniaturizable, .fullSizeContentView],
                                    backing: .buffered,
                                    defer: true,
                                    screen: nil)
        
        window.title = "Touches"
        window.tabbingMode = .disallowed
        window.model = model
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        
        return window
    }
    
    
    func makeVisible() {
        
        self.setIsVisible(true)
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        if let controller = self.contentViewController {
            if let screen = model?.connectedTouchscreen?.systemScreen() {
                self.level = .screenSaver // prevents notifications from coming in
                let presentationOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
                
                let options: [NSView.FullScreenModeOptionKey : NSNumber] = [
                    .fullScreenModeApplicationPresentationOptions : NSNumber(value: presentationOptions.rawValue),
                    .fullScreenModeWindowLevel : NSNumber(value: kCGNormalWindowLevel),
                    .fullScreenModeAllScreens : NSNumber(booleanLiteral: false)
                ]
                self.setIsVisible(false)
                controller.view.enterFullScreenMode(screen, withOptions: options)
            }
        }
    }
    
    override func close() {
        if let controller = self.contentViewController {
            self.level = .normal
            self.setIsVisible(true)
            controller.view.exitFullScreenMode(options: nil)
        }
        super.close()
    }
}


// MARK: - Floating Keyboard

/**
 One key of the floating keyboard. Key codes are ANSI virtual key codes,
 so the active input source decides which character is typed.
 */
struct KeyboardKey {
    enum Role: Equatable {
        case character
        case modifier(CGEventFlags) // sticky: applies to the next key press
        case capsLock
        case hide
    }

    enum Alignment {
        case center, leading, trailing
    }

    var label: String
    var shiftedLabel: String? = nil
    var glyph: String? = nil
    var keyCode: Int = 0
    var width: CGFloat = 1 // in key units
    var role: Role = .character
    var alignment: Alignment = .center
    var repeats = false

    var isLetter: Bool {
        label.count == 1 && label.first!.isLetter
    }

    /// Function keys get the darker cap, like on a Mac keyboard.
    var isFunctionKey: Bool {
        role != .character || alignment != .center
    }

    static func letter(_ label: String, _ keyCode: Int) -> KeyboardKey {
        KeyboardKey(label: label, keyCode: keyCode)
    }

    static func symbol(_ label: String, _ shiftedLabel: String, _ keyCode: Int) -> KeyboardKey {
        KeyboardKey(label: label, shiftedLabel: shiftedLabel, keyCode: keyCode)
    }

    static func arrow(_ label: String, _ keyCode: Int) -> KeyboardKey {
        KeyboardKey(label: label, keyCode: keyCode, repeats: true)
    }

    static func modifier(_ label: String, glyph: String, flag: CGEventFlags, width: CGFloat, alignment: Alignment) -> KeyboardKey {
        KeyboardKey(label: label, glyph: glyph, width: width, role: .modifier(flag), alignment: alignment)
    }
}


/**
 Mac-style keyboard drawn by hand instead of SwiftUI, so a key press is a hit test plus one small redraw.
 Touches arrive directly from the touch input manager (see `TUCTouchDelegate.shouldClaimTouch`),
 so keys fire on touch down and overlapping fingers each produce their own key press.
 */
final class FloatingKeyboardView: NSView {

    private enum Slot {
        case key(KeyboardKey)
        case stacked(KeyboardKey, KeyboardKey) // two half-height keys in one column, like the up/down arrows
    }

    private enum VerticalPlacement {
        case center, top, bottom
    }

    private static let unit: CGFloat = 56
    private static let gap: CGFloat = 6
    private static let padding: CGFloat = 10
    private static let grabberHeight: CGFloat = 22 // drag handle strip above the keys
    private static let edgeSnapDistance: CGFloat = 28 // closer than this to a screen edge, the panel sticks to it
    /// Keys fire this long after touch down (or on liftoff, if sooner), so four fingers landing on the
    /// keyboard for a swipe are recognized as a gesture before any of them types.
    private static let keyCommitDelay: TimeInterval = 0.045
    private static let keyRepeatDelay: TimeInterval = 0.45
    private static let keyRepeatInterval: TimeInterval = 0.06

    private static let rows: [[Slot]] = [
        [
            .key(.symbol("`", "~", kVK_ANSI_Grave)),
            .key(.symbol("1", "!", kVK_ANSI_1)),
            .key(.symbol("2", "@", kVK_ANSI_2)),
            .key(.symbol("3", "#", kVK_ANSI_3)),
            .key(.symbol("4", "$", kVK_ANSI_4)),
            .key(.symbol("5", "%", kVK_ANSI_5)),
            .key(.symbol("6", "^", kVK_ANSI_6)),
            .key(.symbol("7", "&", kVK_ANSI_7)),
            .key(.symbol("8", "*", kVK_ANSI_8)),
            .key(.symbol("9", "(", kVK_ANSI_9)),
            .key(.symbol("0", ")", kVK_ANSI_0)),
            .key(.symbol("-", "_", kVK_ANSI_Minus)),
            .key(.symbol("=", "+", kVK_ANSI_Equal)),
            .key(KeyboardKey(label: "delete", keyCode: kVK_Delete, width: 1.5, alignment: .trailing, repeats: true))
        ],
        [.key(KeyboardKey(label: "tab", keyCode: kVK_Tab, width: 1.5, alignment: .leading))]
            + letters("qwertyuiop", [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T,
                                     kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P])
            + [
                .key(.symbol("[", "{", kVK_ANSI_LeftBracket)),
                .key(.symbol("]", "}", kVK_ANSI_RightBracket)),
                .key(.symbol("\\", "|", kVK_ANSI_Backslash))
            ],
        [.key(KeyboardKey(label: "caps lock", width: 1.75, role: .capsLock, alignment: .leading))]
            + letters("asdfghjkl", [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G,
                                    kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L])
            + [
                .key(.symbol(";", ":", kVK_ANSI_Semicolon)),
                .key(.symbol("'", "\"", kVK_ANSI_Quote)),
                .key(KeyboardKey(label: "return", keyCode: kVK_Return, width: 1.75, alignment: .trailing))
            ],
        [.key(.modifier("shift", glyph: "⇧", flag: .maskShift, width: 2.25, alignment: .leading))]
            + letters("zxcvbnm", [kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M])
            + [
                .key(.symbol(",", "<", kVK_ANSI_Comma)),
                .key(.symbol(".", ">", kVK_ANSI_Period)),
                .key(.symbol("/", "?", kVK_ANSI_Slash)),
                .key(.modifier("shift", glyph: "⇧", flag: .maskShift, width: 2.25, alignment: .trailing))
            ],
        [
            .key(KeyboardKey(label: "", role: .hide)),
            .key(.modifier("control", glyph: "⌃", flag: .maskControl, width: 1, alignment: .leading)),
            .key(.modifier("option", glyph: "⌥", flag: .maskAlternate, width: 1, alignment: .leading)),
            .key(.modifier("command", glyph: "⌘", flag: .maskCommand, width: 1.25, alignment: .leading)),
            .key(KeyboardKey(label: "", keyCode: kVK_Space, width: 5, repeats: true)),
            .key(.modifier("command", glyph: "⌘", flag: .maskCommand, width: 1.25, alignment: .trailing)),
            .key(.modifier("option", glyph: "⌥", flag: .maskAlternate, width: 1, alignment: .trailing)),
            .key(.arrow("◀", kVK_LeftArrow)),
            .stacked(.arrow("▲", kVK_UpArrow), .arrow("▼", kVK_DownArrow)),
            .key(.arrow("▶", kVK_RightArrow))
        ]
    ]

    static let contentSize = NSSize(width: 14.5 * unit + 2 * padding,
                                    height: grabberHeight + CGFloat(rows.count) * unit + 2 * padding)

    private weak var model: TouchMyMac?
    private let keys: [(key: KeyboardKey, rect: NSRect)] = FloatingKeyboardView.makeLayout()

    private var latchedModifiers: CGEventFlags = []
    private var isCapsLockOn = false
    private var pressedKeys: [UUID: Int] = [:] // touch (or mouse) -> index into `keys`
    private var pendingCommits: [UUID: Timer] = [:]
    private var repeatTimers: [UUID: Timer] = [:]
    private var isPartOfGesture = false // the current touches are a multi-finger gesture, not key presses
    private let mousePressID = UUID()

    // Moving the panel by its handle or empty edge.
    private var dragID: UUID?
    private var dragStartLocation = NSPoint.zero // screen coordinates
    private var dragStartOrigin = NSPoint.zero

    init(model: TouchMyMac) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }


    // MARK: Input

    /// Returns false when the location is outside the keyboard, so the touch falls through to regular cursor handling.
    func beginTouch(_ touchID: UUID, atScreenLocation location: CGPoint) -> Bool {
        guard let window else { return false }
        let screenPoint = Self.cocoaScreenPoint(location)
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard bounds.contains(point) else { return false }

        if isPartOfGesture {
            return true // keep it out of cursor handling; it only counts toward the gesture
        }
        if let index = keyIndex(at: point) {
            press(index, id: touchID)
        } else {
            beginDrag(touchID, at: screenPoint)
        }
        return true
    }

    func moveTouch(_ touchID: UUID, toScreenLocation location: CGPoint) {
        if touchID == dragID {
            moveDrag(to: Self.cocoaScreenPoint(location))
        }
    }

    func endTouch(_ touchID: UUID) {
        if touchID == dragID {
            endDrag()
        }
        if let pending = pendingCommits.removeValue(forKey: touchID) {
            // Lifted before the commit delay ran out: type the key now.
            pending.invalidate()
            commit(id: touchID)
        }
        repeatTimers.removeValue(forKey: touchID)?.invalidate()
        if let index = pressedKeys.removeValue(forKey: touchID) {
            setNeedsDisplay(keys[index].rect.insetBy(dx: -2, dy: -2))
        }
        if pressedKeys.isEmpty && dragID == nil {
            isPartOfGesture = false
        }
    }

    /// Four or more fingers are down with some on the keyboard: they're a swipe, so keys that haven't fired don't.
    func cancelForGesture() {
        isPartOfGesture = true
        pendingCommits.values.forEach { $0.invalidate() }
        pendingCommits.removeAll()
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
        pressedKeys.removeAll()
        endDrag()
        needsDisplay = true
    }

    func reset() {
        pendingCommits.values.forEach { $0.invalidate() }
        pendingCommits.removeAll()
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
        pressedKeys.removeAll()
        endDrag()
        isPartOfGesture = false
        latchedModifiers = []
        isCapsLockOn = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let index = keyIndex(at: convert(event.locationInWindow, from: nil)) {
            press(index, id: mousePressID)
        } else {
            beginDrag(mousePressID, at: NSEvent.mouseLocation)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if dragID == mousePressID {
            moveDrag(to: NSEvent.mouseLocation)
        }
    }

    override func mouseUp(with event: NSEvent) {
        endTouch(mousePressID)
    }

    /// Touch locations are global display coordinates with the origin at the top left of the primary screen.
    private static func cocoaScreenPoint(_ location: CGPoint) -> NSPoint {
        NSPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
    }


    // MARK: Moving the panel

    private func beginDrag(_ id: UUID, at screenPoint: NSPoint) {
        guard dragID == nil, let window else { return }
        dragID = id
        dragStartLocation = screenPoint
        dragStartOrigin = window.frame.origin
        window.alphaValue = 0.85 // shows the panel is picked up
        setNeedsDisplay(grabberRect.insetBy(dx: -12, dy: -4))
    }

    private func moveDrag(to screenPoint: NSPoint) {
        guard let window else { return }
        let origin = NSPoint(x: dragStartOrigin.x + screenPoint.x - dragStartLocation.x,
                             y: dragStartOrigin.y + screenPoint.y - dragStartLocation.y)
        // Keep it on the screen the finger is on, so it can still be dragged to another display.
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? window.screen
        guard let area = screen?.visibleFrame else {
            window.setFrameOrigin(origin)
            return
        }
        window.setFrameOrigin(Self.snappedOrigin(origin, size: window.frame.size, in: area))
    }

    /// Keeps the whole panel inside `area` and pulls it flush against an edge it comes close to, like a magnet.
    static func snappedOrigin(_ origin: NSPoint, size: NSSize, in area: NSRect) -> NSPoint {
        func snap(_ value: CGFloat, length: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
            let clamped = Swift.min(Swift.max(value, lower), upper - length)
            if clamped - lower < edgeSnapDistance {
                return lower
            }
            if upper - (clamped + length) < edgeSnapDistance {
                return upper - length
            }
            return clamped
        }
        return NSPoint(x: snap(origin.x, length: size.width, min: area.minX, max: area.maxX),
                       y: snap(origin.y, length: size.height, min: area.minY, max: area.maxY))
    }

    private func endDrag() {
        guard dragID != nil else { return }
        dragID = nil
        window?.alphaValue = 1
        (window as? FloatingKeyboardPanel)?.rememberPosition()
        setNeedsDisplay(grabberRect.insetBy(dx: -12, dy: -4))
    }

    private var grabberRect: NSRect {
        let width: CGFloat = dragID == nil ? 44 : 64
        return NSRect(x: bounds.midX - width / 2, y: Self.grabberHeight / 2 + 2, width: width, height: 5)
    }

    private func keyIndex(at point: NSPoint) -> Int? {
        // Grow each key by half the gap so a touch between two keys still hits one of them.
        keys.firstIndex { $0.rect.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(point) }
    }

    private func press(_ index: Int, id: UUID) {
        pressedKeys[id] = index
        setNeedsDisplay(keys[index].rect.insetBy(dx: -2, dy: -2))

        let timer = Timer(timeInterval: Self.keyCommitDelay, repeats: false) { [weak self] _ in
            self?.pendingCommits.removeValue(forKey: id)
            self?.commit(id: id)
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingCommits[id]?.invalidate()
        pendingCommits[id] = timer
    }

    private func commit(id: UUID) {
        guard !isPartOfGesture, let index = pressedKeys[id] else { return }
        let key = keys[index].key

        switch key.role {
        case .modifier(let flag):
            latchedModifiers.formSymmetricDifference(flag)
            needsDisplay = true

        case .capsLock:
            isCapsLockOn.toggle()
            needsDisplay = true

        case .hide:
            window?.orderOut(nil)

        case .character:
            var flags = latchedModifiers
            if isCapsLockOn && key.isLetter {
                flags.insert(.maskShift)
            }
            send(key, flags: flags)

            if !latchedModifiers.isEmpty {
                latchedModifiers = []
                needsDisplay = true
            }
            if key.repeats {
                startRepeating(key, flags: flags, id: id)
            }
        }
    }

    private func send(_ key: KeyboardKey, flags: CGEventFlags) {
        model?.touchManager.performKeyCode(CGKeyCode(key.keyCode), modifierFlags: flags)
    }

    private func startRepeating(_ key: KeyboardKey, flags: CGEventFlags, id: UUID) {
        let timer = Timer(fire: Date(timeIntervalSinceNow: Self.keyRepeatDelay),
                          interval: Self.keyRepeatInterval,
                          repeats: true) { [weak self] _ in
            self?.send(key, flags: flags)
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimers[id]?.invalidate()
        repeatTimers[id] = timer
    }


    // MARK: Layout

    private static func letters(_ letters: String, _ keyCodes: [Int]) -> [Slot] {
        zip(letters, keyCodes).map { .key(.letter(String($0), $1)) }
    }

    private static func makeLayout() -> [(key: KeyboardKey, rect: NSRect)] {
        var layout: [(key: KeyboardKey, rect: NSRect)] = []

        for (rowIndex, row) in rows.enumerated() {
            let y = grabberHeight + padding + CGFloat(rowIndex) * unit
            var x = padding

            for slot in row {
                switch slot {
                case .key(let key):
                    let width = key.width * unit
                    layout.append((key, NSRect(x: x, y: y, width: width, height: unit).insetBy(dx: gap / 2, dy: gap / 2)))
                    x += width

                case .stacked(let top, let bottom):
                    let cell = NSRect(x: x, y: y, width: unit, height: unit).insetBy(dx: gap / 2, dy: gap / 2)
                    let (topRect, bottomRect) = cell.divided(atDistance: cell.height / 2, from: .minYEdge)
                    layout.append((top, topRect.insetBy(dx: 0, dy: 1)))
                    layout.append((bottom, bottomRect.insetBy(dx: 0, dy: 1)))
                    x += unit
                }
            }
        }
        return layout
    }


    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let grabber = grabberRect
        if grabber.insetBy(dx: -12, dy: -4).intersects(dirtyRect) {
            (dragID == nil ? NSColor.secondaryLabelColor.withAlphaComponent(0.5) : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: grabber, xRadius: grabber.height / 2, yRadius: grabber.height / 2).fill()
        }

        let pressedIndices = Set(pressedKeys.values)
        for (index, entry) in keys.enumerated() where entry.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            drawKey(entry.key, in: entry.rect, isPressed: pressedIndices.contains(index))
        }
    }

    private func drawKey(_ key: KeyboardKey, in rect: NSRect, isPressed: Bool) {
        let cornerRadius: CGFloat = 6

        NSColor.keyEdge.setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let face: NSColor
        if isPressed {
            face = .controlAccentColor
        } else if case .modifier(let flag) = key.role, latchedModifiers.contains(flag) {
            face = NSColor.controlAccentColor.withAlphaComponent(0.35)
        } else {
            face = key.isFunctionKey ? .functionKeyFace : .keyFace
        }
        face.setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        drawLabels(of: key, in: rect, color: isPressed ? .white : .labelColor)
    }

    private func drawLabels(of key: KeyboardKey, in rect: NSRect, color: NSColor) {
        let isShifted = latchedModifiers.contains(.maskShift)

        if key.role == .hide {
            drawHideSymbol(in: rect, color: color)
            return
        }

        if key.role == .capsLock {
            let indicator = NSRect(x: rect.minX + 7, y: rect.minY + 7, width: 6, height: 6)
            (isCapsLockOn ? NSColor.systemGreen : NSColor.keyEdge).setFill()
            NSBezierPath(ovalIn: indicator).fill()
        }

        if key.alignment != .center {
            if let glyph = key.glyph {
                drawText(glyph, font: .functionKeyGlyphFont, color: color, in: rect, horizontal: key.alignment, vertical: .top)
            }
            drawText(key.label, font: .functionKeyFont, color: color, in: rect, horizontal: key.alignment, vertical: .bottom)

        } else if let shiftedLabel = key.shiftedLabel {
            let dimmed = color.withAlphaComponent(0.45)
            drawText(shiftedLabel, font: .symbolKeyFont, color: isShifted ? color : dimmed, in: rect, horizontal: .center, vertical: .top)
            drawText(key.label, font: .symbolKeyFont, color: isShifted ? dimmed : color, in: rect, horizontal: .center, vertical: .bottom)

        } else if key.isLetter {
            let label = (isShifted || isCapsLockOn) ? key.label.uppercased() : key.label
            drawText(label, font: .letterKeyFont, color: color, in: rect, horizontal: .center, vertical: .center)

        } else {
            drawText(key.label, font: .arrowKeyFont, color: color, in: rect, horizontal: .center, vertical: .center)
        }
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect,
                          horizontal: KeyboardKey.Alignment, vertical: VerticalPlacement) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let content = rect.insetBy(dx: 6, dy: 5)

        let x: CGFloat
        switch horizontal {
        case .center: x = rect.midX - size.width / 2
        case .leading: x = content.minX
        case .trailing: x = content.maxX - size.width
        }

        let y: CGFloat
        switch vertical {
        case .center: y = rect.midY - size.height / 2
        case .top: y = content.minY
        case .bottom: y = content.maxY - size.height
        }

        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawHideSymbol(in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "keyboard.chevron.compact.down", accessibilityDescription: "Hide Keyboard")?
            .withSymbolConfiguration(configuration) else { return }

        let size = image.size
        let imageRect = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}


private extension NSColor {
    static let keyFace = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 1, alpha: 0.95) }
    static let functionKeyFace = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0.84, alpha: 0.95) }
    static let keyEdge = NSColor(name: nil) { $0.isDark ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 0, alpha: 0.2) }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

private extension NSFont {
    static let letterKeyFont = NSFont.systemFont(ofSize: 20)
    static let symbolKeyFont = NSFont.systemFont(ofSize: 14)
    static let arrowKeyFont = NSFont.systemFont(ofSize: 11)
    static let functionKeyFont = NSFont.systemFont(ofSize: 10)
    static let functionKeyGlyphFont = NSFont.systemFont(ofSize: 13)
}


class FloatingKeyboardPanel: NSPanel {
    let keyboardView: FloatingKeyboardView
    private weak var model: TouchMyMac?
    private var userOrigin: NSPoint? // where the user last moved the panel

    init(model: TouchMyMac) {
        self.model = model
        self.keyboardView = FloatingKeyboardView(model: model)

        // No title bar: the keyboard's own handle and empty edge move it (see FloatingKeyboardView).
        super.init(contentRect: NSRect(origin: .zero, size: FloatingKeyboardView.contentSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The level macOS reserves for on-screen keyboards, so the panel stays above
        // other apps' floating windows and this app's own settings window.
        level = NSWindow.Level(Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: FloatingKeyboardView.contentSize))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 14)
        contentView = background

        keyboardView.frame = background.bounds
        keyboardView.autoresizingMask = [.width, .height]
        background.addSubview(keyboardView)

        model.floatingKeyboard = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func makeVisible() {
        if !self.isVisible {
            if let userOrigin, let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSRect(origin: userOrigin, size: frame.size).center) }) {
                // The screen layout may have changed since; keep it fully on screen.
                setFrameOrigin(FloatingKeyboardView.snappedOrigin(userOrigin, size: frame.size, in: screen.visibleFrame))
            } else if let targetScreen = model?.touchscreen()?.systemScreen() ?? NSScreen.main {
                let visibleFrame = targetScreen.visibleFrame
                let origin = CGPoint(
                    x: visibleFrame.midX - (frame.width / 2),
                    y: visibleFrame.minY + 48
                )
                setFrameOrigin(origin)
            }
        }

        orderFrontRegardless()
    }

    func rememberPosition() {
        userOrigin = frame.origin
    }

    override func orderOut(_ sender: Any?) {
        keyboardView.reset()
        super.orderOut(sender)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override func close() {
        keyboardView.reset()
        super.close()
    }
}


private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
