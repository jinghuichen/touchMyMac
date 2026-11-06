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
import TouchUpCore


@main
class AppDelegate: NSObject, NSApplicationDelegate {

    let model = TouchMyMac()
    
    
    var statusItem: NSStatusItem!
    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var activationMenuItem: NSMenuItem!
    
    var observers = [AnyCancellable]()

    // Status rows at the top of the menu bar menu; the icon itself never changes.
    let statusSummaryMenuItem = NSMenuItem()
    let accessibilityStatusMenuItem = NSMenuItem()
    let inputMonitoringStatusMenuItem = NSMenuItem()
    let touchscreenStatusMenuItem = NSMenuItem()
    
    
    
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
        self.statusItem.button?.image = Self.menuBarIcon
        self.statusItem.button?.toolTip = "TouchMyMac"
        self.installStatusMenuItems()

        // receive(on:) runs after @Published has stored the new value, so the refresh reads current state.
        self.observers.append(
            Publishers.CombineLatest4(
                self.model.$isAccessibilityAccessGranted,
                self.model.$touchscreenDeviceName,
                self.model.$screenAssignmentRevision,
                self.model.$isPublishingMouseEventsEnabled
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusMenu() }
        )
        self.observers.append(
            self.model.$isInputMonitoringGranted
                .combineLatest(self.model.$isInputMonitoringNeeded)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshStatusMenu() }
        )
        
        self.observers.append(
            self.model.$isPublishingMouseEventsEnabled
                .receive(on: DispatchQueue.main)
                .sink{
                    self.activationMenuItem.state = $0 ? .on : .off
                }
        )
        
        self.model.touchManager.start()
        self.model.requestInputMonitoringIfNeeded()
        
        if !model.isAccessibilityAccessGranted || model.isInputMonitoringNeeded {
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


// MARK: - Menu Bar Status

extension AppDelegate: NSMenuDelegate {

    /// A monitor with a finger touching its lower right corner, drawn as a template so the menu bar tints it.
    static let menuBarIcon: NSImage = {
        let size = NSSize(width: 19, height: 16)
        let hand = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold))
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.25, y: 4.25, width: 14.5, height: 10.5), xRadius: 2.2, yRadius: 2.2)
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 8.5, y: 4.25))
            stand.line(to: NSPoint(x: 8.5, y: 1.75))
            stand.move(to: NSPoint(x: 5.5, y: 1.5))
            stand.line(to: NSPoint(x: 11.5, y: 1.5))
            for path in [screen, stand] {
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            if let hand {
                let rect = NSRect(x: size.width - hand.size.width - 0.2, y: 0, width: hand.size.width, height: hand.size.height)
                // Cut a gap around the hand so it reads apart from the monitor outline.
                for step in 0..<12 {
                    let angle = CGFloat(step) * .pi / 6
                    hand.draw(in: rect.offsetBy(dx: cos(angle) * 1.3, dy: sin(angle) * 1.3),
                              from: .zero, operation: .destinationOut, fraction: 1)
                }
                hand.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TouchMyMac"
        return image
    }()

    private enum StatusTone {
        case good, warning, problem, neutral

        var symbol: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .problem: return "xmark.circle.fill"
            case .neutral: return "pause.circle.fill"
            }
        }

        var color: NSColor {
            switch self {
            case .good: return .systemGreen
            case .warning: return .systemOrange
            case .problem: return .systemRed
            case .neutral: return .systemGray
            }
        }
    }

    private static func statusIcon(_ tone: StatusTone) -> NSImage? {
        statusIcon(symbol: tone.symbol, colors: [.white, tone.color])
    }

    private static func statusIcon(symbol: String, colors: [NSColor]) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    func installStatusMenuItems() {
        statusMenu.delegate = self

        accessibilityStatusMenuItem.target = self
        accessibilityStatusMenuItem.action = #selector(openAccessibilitySettings(_:))
        inputMonitoringStatusMenuItem.target = self
        inputMonitoringStatusMenuItem.action = #selector(grantInputMonitoring(_:))
        touchscreenStatusMenuItem.submenu = NSMenu()

        let items = [statusSummaryMenuItem, accessibilityStatusMenuItem, inputMonitoringStatusMenuItem,
                     touchscreenStatusMenuItem, .separator()]
        for (index, item) in items.enumerated() {
            statusMenu.insertItem(item, at: index)
        }
        refreshStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusMenu else { return }
        model.refreshAccessibilityStatus()
        model.refreshInputMonitoringStatus()
        refreshStatusMenu()
    }

    func refreshStatusMenu() {
        let accessibilityGranted = model.isAccessibilityAccessGranted
        let inputMonitoringGranted = model.isInputMonitoringGranted
        let inputMonitoringNeeded = model.isInputMonitoringNeeded
        let deviceName = model.touchscreenDeviceName
        let touchControlOn = model.isPublishingMouseEventsEnabled

        // Summary: the one thing to look at first.
        let summary: (String, StatusTone)
        if !accessibilityGranted {
            summary = ("Needs Accessibility permission", .warning)
        } else if inputMonitoringNeeded {
            summary = ("Needs Input Monitoring permission", .warning)
        } else if deviceName == nil {
            summary = ("Waiting for a touchscreen", .problem)
        } else if !touchControlOn {
            summary = ("Touch control is paused", .neutral)
        } else {
            summary = ("Ready: touch control is on", .good)
        }
        statusSummaryMenuItem.attributedTitle = NSAttributedString(string: summary.0, attributes: [
            .font: NSFont.menuFont(ofSize: 0).bold,
            .foregroundColor: NSColor.labelColor,
        ])
        statusSummaryMenuItem.image = Self.statusIcon(summary.1)
        statusSummaryMenuItem.isEnabled = false

        if accessibilityGranted {
            accessibilityStatusMenuItem.title = "Accessibility: Allowed"
            accessibilityStatusMenuItem.image = Self.statusIcon(.good)
            accessibilityStatusMenuItem.toolTip = "TouchMyMac may control the mouse and keyboard."
        } else {
            accessibilityStatusMenuItem.title = "Accessibility: Not Allowed – Open Settings…"
            accessibilityStatusMenuItem.image = Self.statusIcon(.warning)
            accessibilityStatusMenuItem.toolTip = "Turn on TouchMyMac in Privacy & Security → Accessibility. "
                + "After an update, remove it from the list and add it again."
        }

        // Most touchscreens don't need Input Monitoring, so the row only shows once it matters.
        inputMonitoringStatusMenuItem.isHidden = !inputMonitoringGranted && !inputMonitoringNeeded
        if inputMonitoringGranted {
            inputMonitoringStatusMenuItem.title = "Input Monitoring: Allowed"
            inputMonitoringStatusMenuItem.image = Self.statusIcon(.good)
            inputMonitoringStatusMenuItem.toolTip = "TouchMyMac may read the touchscreen's touch data."
        } else {
            inputMonitoringStatusMenuItem.title = "Input Monitoring: Not Allowed – Open Settings…"
            inputMonitoringStatusMenuItem.image = Self.statusIcon(.warning)
            inputMonitoringStatusMenuItem.toolTip = "Turn on TouchMyMac in Privacy & Security → Input Monitoring. "
                + "macOS won't let the app read this touchscreen without it."
        }

        // The touchscreen row names the monitor touches land on; its submenu picks another one.
        let display = model.connectedTouchscreen
        if deviceName == nil && inputMonitoringNeeded {
            // Without Input Monitoring the touchscreen may not show up at all, so don't call it unplugged.
            touchscreenStatusMenuItem.title = "Touchscreen: Waiting for Input Monitoring"
            touchscreenStatusMenuItem.image = Self.statusIcon(.warning)
            touchscreenStatusMenuItem.toolTip = "Allow Input Monitoring first; the touchscreen shows up after that."
        } else if deviceName == nil {
            touchscreenStatusMenuItem.title = "Touchscreen: Not Connected"
            touchscreenStatusMenuItem.image = Self.statusIcon(.problem)
            touchscreenStatusMenuItem.toolTip = "Connect the touchscreen's USB cable."
        } else if let display {
            touchscreenStatusMenuItem.title = "Touchscreen: \(display.name)"
            if !inputMonitoringNeeded {
                touchscreenStatusMenuItem.image = Self.statusIcon(.good)
                touchscreenStatusMenuItem.toolTip = "Touches land on this display. Pick another one if it's the wrong monitor."
            } else {
                touchscreenStatusMenuItem.image = Self.statusIcon(.warning)
                touchscreenStatusMenuItem.toolTip = "Connected, but no touches can be read until Input Monitoring is allowed."
            }
        } else {
            touchscreenStatusMenuItem.title = "Touchscreen: No Display Found"
            touchscreenStatusMenuItem.image = Self.statusIcon(.warning)
            touchscreenStatusMenuItem.toolTip = nil
        }

        refreshDisplayMenu()
    }

    private func refreshDisplayMenu() {
        guard let submenu = touchscreenStatusMenuItem.submenu else { return }
        let current = model.connectedTouchscreen
        let remembered = model.isAssignedScreenRemembered

        submenu.removeAllItems()
        let header = NSMenuItem(title: "Touches Land On", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)

        let automatic = NSMenuItem(title: "Automatic", action: #selector(useAutomaticDisplay(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = remembered ? .off : .on
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        for screen in model.connectedScreens {
            let title = screen.isBuiltin ? "\(screen.name) (This Mac)" : screen.name
            let item = NSMenuItem(title: title, action: #selector(assignDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: screen.id)
            // A dash marks the display Automatic chose; a checkmark marks one you picked.
            if screen.id == current?.id {
                item.state = remembered ? .on : .mixed
            }
            submenu.addItem(item)
        }
    }

    @objc func useAutomaticDisplay(_ sender: NSMenuItem) {
        model.useAutomaticTouchscreenDisplay()
    }

    @objc func assignDisplay(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uintValue else { return }
        model.assignTouchscreen(toScreenWithID: id)
    }

    @objc func openAccessibilitySettings(_ sender: Any?) {
        model.openAccessibilitySettings()
    }

    @objc func grantInputMonitoring(_ sender: Any?) {
        model.grantInputMonitoringAccess()
    }
}


private extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
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
        case inputSource // switches the input source, like the globe key or ⌃Space
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
    private static let grabberHeight: CGFloat = 30 // drag handle strip above the keys, with the size button
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
            .key(KeyboardKey(label: "", role: .inputSource)),
            .key(.modifier("control", glyph: "⌃", flag: .maskControl, width: 1, alignment: .leading)),
            .key(.modifier("option", glyph: "⌥", flag: .maskAlternate, width: 1, alignment: .leading)),
            .key(.modifier("command", glyph: "⌘", flag: .maskCommand, width: 1.25, alignment: .leading)),
            .key(KeyboardKey(label: "", keyCode: kVK_Space, width: 4, repeats: true)),
            .key(.modifier("command", glyph: "⌘", flag: .maskCommand, width: 1.25, alignment: .trailing)),
            .key(.modifier("option", glyph: "⌥", flag: .maskAlternate, width: 1, alignment: .trailing)),
            .key(.arrow("◀", kVK_LeftArrow)),
            .stacked(.arrow("▲", kVK_UpArrow), .arrow("▼", kVK_DownArrow)),
            .key(.arrow("▶", kVK_RightArrow))
        ]
    ]

    /// The mini keyboard is the same layout at this size.
    static let compactScale: CGFloat = 0.6

    static func contentSize(scale: CGFloat) -> NSSize {
        NSSize(width: (14.5 * unit + 2 * padding) * scale,
               height: (grabberHeight + CGFloat(rows.count) * unit + 2 * padding) * scale)
    }

    private weak var model: TouchMyMac?
    private var keys: [(key: KeyboardKey, rect: NSRect)] = FloatingKeyboardView.makeLayout(scale: 1)

    var isCompact = false {
        didSet {
            keys = Self.makeLayout(scale: scale)
            needsDisplay = true
        }
    }
    var scale: CGFloat { isCompact ? Self.compactScale : 1 }

    private var latchedModifiers: CGEventFlags = []
    private var isCapsLockOn = false
    private var pressedKeys: [UUID: Int] = [:] // touch (or mouse) -> index into `keys`
    private var pendingCommits: [UUID: Timer] = [:]
    private var repeatTimers: [UUID: Timer] = [:]
    private var isPartOfGesture = false // the current touches are a multi-finger gesture, not key presses
    private let mousePressID = UUID()

    private var sizeButtonID: UUID? // the touch (or mouse) pressing the full/mini button in the top strip
    private var inputSourceLabel = InputSourceSwitcher.currentShortName()
    private var inputSourceObserver: NSObjectProtocol?

    // Moving the panel by its handle or empty edge.
    private var dragID: UUID?
    private var dragStartLocation = NSPoint.zero // screen coordinates
    private var dragStartOrigin = NSPoint.zero

    init(model: TouchMyMac) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize(scale: 1)))
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshInputSourceLabel()
        }
    }

    deinit {
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
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
        if sizeButtonRect.contains(point) {
            pressSizeButton(touchID)
        } else if let index = keyIndex(at: point) {
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
        if touchID == sizeButtonID {
            sizeButtonID = nil
            setNeedsDisplay(sizeButtonRect)
            if !isPartOfGesture {
                (window as? FloatingKeyboardPanel)?.setCompact(!isCompact)
            }
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
        if pressedKeys.isEmpty && dragID == nil && sizeButtonID == nil {
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
        sizeButtonID = nil
        endDrag()
        needsDisplay = true
    }

    func reset() {
        pendingCommits.values.forEach { $0.invalidate() }
        pendingCommits.removeAll()
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
        pressedKeys.removeAll()
        sizeButtonID = nil
        endDrag()
        isPartOfGesture = false
        latchedModifiers = []
        isCapsLockOn = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if sizeButtonRect.contains(point) {
            pressSizeButton(mousePressID)
        } else if let index = keyIndex(at: point) {
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

    /// The vertical center of the handle, which the size button lines up with.
    private var grabberMidY: CGFloat {
        (Self.grabberHeight / 2 + 2) * scale
    }

    private var grabberRect: NSRect {
        let width: CGFloat = (dragID == nil ? 44 : 64) * scale
        let height = max(5 * scale, 3)
        return NSRect(x: bounds.midX - width / 2, y: grabberMidY - height / 2, width: width, height: height)
    }

    /// The full/mini button: level with the handle, its right edge on the keys' right edge.
    private var sizeButtonIconRect: NSRect {
        let side = 24 * scale
        return NSRect(x: bounds.maxX - (Self.padding + Self.gap / 2) * scale - side, y: grabberMidY - side / 2,
                      width: side, height: side)
    }

    /// Where a touch presses the size button: the icon plus the strip around it, short of the keys.
    private var sizeButtonRect: NSRect {
        let minX = sizeButtonIconRect.minX - 14 * scale
        return NSRect(x: minX, y: 0, width: bounds.maxX - minX, height: (Self.grabberHeight + Self.padding / 2) * scale)
    }

    private func pressSizeButton(_ id: UUID) {
        guard sizeButtonID == nil else { return }
        sizeButtonID = id
        setNeedsDisplay(sizeButtonRect)
    }

    private func refreshInputSourceLabel() {
        let label = InputSourceSwitcher.currentShortName()
        guard label != inputSourceLabel else { return }
        inputSourceLabel = label
        if let index = keys.firstIndex(where: { $0.key.role == .inputSource }) {
            setNeedsDisplay(keys[index].rect.insetBy(dx: -2, dy: -2))
        }
    }

    private func keyIndex(at point: NSPoint) -> Int? {
        // Grow each key by half the gap so a touch between two keys still hits one of them.
        keys.firstIndex { $0.rect.insetBy(dx: -Self.gap * scale / 2, dy: -Self.gap * scale / 2).contains(point) }
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

        case .inputSource:
            if let touchManager = model?.touchManager {
                InputSourceSwitcher.switchToPrevious(using: touchManager)
            }

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

    private static func makeLayout(scale: CGFloat) -> [(key: KeyboardKey, rect: NSRect)] {
        var layout: [(key: KeyboardKey, rect: NSRect)] = []
        let unit = Self.unit * scale, gap = Self.gap * scale, padding = Self.padding * scale

        for (rowIndex, row) in rows.enumerated() {
            let y = (grabberHeight + Self.padding) * scale + CGFloat(rowIndex) * unit
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

        if sizeButtonRect.intersects(dirtyRect) {
            let icon = sizeButtonIconRect
            let isPressed = sizeButtonID != nil
            if isPressed {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: icon, xRadius: 6 * scale, yRadius: 6 * scale).fill()
            }
            drawSymbol(isCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                       description: isCompact ? "Full-Size Keyboard" : "Mini Keyboard", in: icon,
                       color: isPressed ? .white : .secondaryLabelColor, pointSize: 13)
        }

        let pressedIndices = Set(pressedKeys.values)
        for (index, entry) in keys.enumerated() where entry.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            drawKey(entry.key, in: entry.rect, isPressed: pressedIndices.contains(index))
        }
    }

    private func drawKey(_ key: KeyboardKey, in rect: NSRect, isPressed: Bool) {
        let cornerRadius: CGFloat = 6 * scale

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
            drawSymbol("keyboard.chevron.compact.down", description: "Hide Keyboard", in: rect, color: color)
            return
        }
        if key.role == .inputSource {
            // Like the globe key on a Mac keyboard, with the current input source on the cap.
            let corner = NSRect(x: rect.minX + 4 * scale, y: rect.maxY - 20 * scale, width: 16 * scale, height: 16 * scale)
            drawSymbol("globe", description: "Switch Input Source", in: corner, color: color, pointSize: 11)
            drawText(inputSourceLabel, font: font(15), color: color, in: rect, horizontal: .center, vertical: .center)
            return
        }

        if key.role == .capsLock {
            let indicator = NSRect(x: rect.minX + 7 * scale, y: rect.minY + 7 * scale, width: 6 * scale, height: 6 * scale)
            (isCapsLockOn ? NSColor.systemGreen : NSColor.keyEdge).setFill()
            NSBezierPath(ovalIn: indicator).fill()
        }

        if key.alignment != .center {
            if let glyph = key.glyph {
                drawText(glyph, font: font(13), color: color, in: rect, horizontal: key.alignment, vertical: .top)
            }
            drawText(key.label, font: font(10), color: color, in: rect, horizontal: key.alignment, vertical: .bottom)

        } else if let shiftedLabel = key.shiftedLabel {
            let dimmed = color.withAlphaComponent(0.45)
            drawText(shiftedLabel, font: font(14), color: isShifted ? color : dimmed, in: rect, horizontal: .center, vertical: .top)
            drawText(key.label, font: font(14), color: isShifted ? dimmed : color, in: rect, horizontal: .center, vertical: .bottom)

        } else if key.isLetter {
            let label = (isShifted || isCapsLockOn) ? key.label.uppercased() : key.label
            drawText(label, font: font(20), color: color, in: rect, horizontal: .center, vertical: .center)

        } else {
            drawText(key.label, font: font(11), color: color, in: rect, horizontal: .center, vertical: .center)
        }
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect,
                          horizontal: KeyboardKey.Alignment, vertical: VerticalPlacement) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let content = rect.insetBy(dx: 6 * scale, dy: 5 * scale)

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

    /// System font at `size` points for the full-size keyboard, scaled for the mini one.
    private func font(_ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size * scale)
    }

    private func drawSymbol(_ name: String, description: String, in rect: NSRect, color: NSColor, pointSize: CGFloat = 15) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize * scale, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) else { return }

        let size = image.size
        let imageRect = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}


/**
 Switches keyboard input sources the way the user's own shortcut does, and names the current one for the key cap.
 */
enum InputSourceSwitcher {
    /// "Select the previous input source" under Keyboard Shortcuts → Input Sources.
    private static let previousSourceHotKey = "60"
    private static let defaultShortcut = (keyCode: CGKeyCode(kVK_Space), flags: CGEventFlags.maskControl)

    /// Toggles back to the previous input source, so one tap goes between, say, English and Pinyin.
    static func switchToPrevious(using touchManager: TUCTouchInputManager) {
        switch previousSourceShortcut() {
        case .some(let shortcut):
            touchManager.performKeyCode(shortcut.keyCode, modifierFlags: shortcut.flags)
        case .none:
            selectNextSource()
        }
    }

    /// The shortcut as set in System Settings: ⌃Space unless the user changed it, nil if it's turned off.
    private static func previousSourceShortcut() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotKeys[previousSourceHotKey] as? [String: Any] else {
            return defaultShortcut // never customized
        }
        guard (entry["enabled"] as? Bool) == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] != 0xFFFF else {
            return nil
        }
        return (CGKeyCode(parameters[1]), CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    /// Used when the shortcut is turned off: selects the next enabled keyboard input source.
    private static func selectNextSource() {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as CFString,
                      kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              sources.count > 1 else { return }
        let currentID = identifier(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        let index = sources.firstIndex { identifier(of: $0) == currentID } ?? -1
        TISSelectInputSource(sources[(index + 1) % sources.count])
    }

    /// A short name for the key cap: 中 for Chinese, あ for Japanese, 한 for Korean, otherwise the language code (EN, DE …).
    static func currentShortName() -> String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let languages = property(of: source, kTISPropertyInputSourceLanguages) as? [String],
              let language = languages.first else { return "" }
        if language.hasPrefix("zh") { return "中" }
        if language.hasPrefix("ja") { return "あ" }
        if language.hasPrefix("ko") { return "한" }
        return String(language.prefix(2)).uppercased()
    }

    private static func identifier(of source: TISInputSource) -> String? {
        property(of: source, kTISPropertyInputSourceID) as? String
    }

    private static func property(of source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
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

class FloatingKeyboardPanel: NSPanel {
    let keyboardView: FloatingKeyboardView
    private weak var model: TouchMyMac?
    private var userOrigin: NSPoint? // where the user last moved the panel
    private static let compactDefaultsKey = "isFloatingKeyboardCompact"

    init(model: TouchMyMac) {
        self.model = model
        self.keyboardView = FloatingKeyboardView(model: model)

        let isCompact = UserDefaults.standard.bool(forKey: Self.compactDefaultsKey)
        keyboardView.isCompact = isCompact
        let size = FloatingKeyboardView.contentSize(scale: keyboardView.scale)

        // No title bar: the keyboard's own handle and empty edge move it (see FloatingKeyboardView).
        super.init(contentRect: NSRect(origin: .zero, size: size),
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

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
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

    /// Switches between the full and the mini keyboard. The panel keeps its bottom edge and horizontal
    /// center, or the screen edge it was snapped to, and the choice is remembered.
    func setCompact(_ compact: Bool) {
        guard compact != keyboardView.isCompact else { return }
        let old = frame
        keyboardView.isCompact = compact
        UserDefaults.standard.set(compact, forKey: Self.compactDefaultsKey)

        let size = FloatingKeyboardView.contentSize(scale: keyboardView.scale)
        var origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        if let area = screen?.visibleFrame {
            if abs(old.minX - area.minX) < 1 {
                origin.x = area.minX
            } else if abs(old.maxX - area.maxX) < 1 {
                origin.x = area.maxX - size.width
            }
            if abs(old.maxY - area.maxY) < 1 {
                origin.y = area.maxY - size.height
            }
            origin = FloatingKeyboardView.snappedOrigin(origin, size: size, in: area)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        rememberPosition()
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
