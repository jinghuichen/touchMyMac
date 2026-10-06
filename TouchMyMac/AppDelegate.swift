//
//  AppDelegate.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import Cocoa
import SwiftUI
import Combine


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
        return FloatingKeyboardPanel.panel(model: self.model)
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
        // The app delegate keeps a strong reference and reopens this window; AppKit must not free it on close.
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.model = model
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        
        let windowController = NSWindowController(window: window)
        
        windowController.contentViewController = vc
        return window
    }
    
    override func close() {
        self.model?.savePreferences()
        if NSApp.modalWindow != nil {
            NSApp.stopModal()
        }
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


struct FloatingKeyboardKey: Identifiable {
    let id: String
    let title: String
    let token: String?
    let width: CGFloat
    let isAccent: Bool

    init(title: String, token: String? = nil, width: CGFloat = 42, isAccent: Bool = false) {
        self.id = "\(title)|\(token ?? title.lowercased())"
        self.title = title
        self.token = token ?? title.lowercased()
        self.width = width
        self.isAccent = isAccent
    }
}

struct FloatingKeyboardButtonStyle: ButtonStyle {
    let isAccent: Bool
    let isActive: Bool
    let isFlashing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor(configuration: configuration), lineWidth: configuration.isPressed || isFlashing ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.08 : 0.16),
                    radius: configuration.isPressed ? 2 : 8,
                    y: configuration.isPressed ? 1 : 4)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.09), value: isFlashing)
    }

    private func borderColor(configuration: Configuration) -> Color {
        if isFlashing {
            return Color.accentColor
        }
        if configuration.isPressed {
            return Color.accentColor.opacity(0.85)
        }
        if isActive {
            return Color.accentColor.opacity(0.65)
        }
        if isAccent {
            return Color.primary.opacity(0.18)
        }
        return Color.primary.opacity(0.12)
    }
}

struct FloatingKeyboardView: View {
    @ObservedObject var model: TouchMyMac
    @State private var shiftEnabled = false
    @State private var symbolKeyboardEnabled = false
    @State private var flashedKeyID: String?
    let closeAction: () -> Void

    private var rows: [[FloatingKeyboardKey]] {
        if symbolKeyboardEnabled {
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { FloatingKeyboardKey(title: $0, width: 58) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { FloatingKeyboardKey(title: $0, width: 58) },
                [".", ",", "?", "!", "'", "#", "%", "^", "*"].map { FloatingKeyboardKey(title: $0, width: 62) },
                [FloatingKeyboardKey(title: "ABC", token: nil, width: 94, isAccent: true)]
                    + ["+", "=", "_", "\\", "|", "~", "<"].map { FloatingKeyboardKey(title: $0, width: 62) }
                    + [FloatingKeyboardKey(title: "Delete", token: "delete", width: 96, isAccent: true)],
                [
                    FloatingKeyboardKey(title: "ABC", token: nil, width: 76, isAccent: true),
                    FloatingKeyboardKey(title: "Space", token: "space", width: 360, isAccent: true),
                    FloatingKeyboardKey(title: "Return", token: "return", width: 116, isAccent: true)
                ]
            ]
        }

        return [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { FloatingKeyboardKey(title: $0, width: 58) },
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"].map { FloatingKeyboardKey(title: $0, width: 58) },
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"].map { FloatingKeyboardKey(title: $0, width: 62) },
            [FloatingKeyboardKey(title: "Shift", token: nil, width: 94, isAccent: true)]
                + ["z", "x", "c", "v", "b", "n", "m"].map { FloatingKeyboardKey(title: $0, width: 62) }
                + [FloatingKeyboardKey(title: "Delete", token: "delete", width: 96, isAccent: true)],
            [
                FloatingKeyboardKey(title: "#+=", token: nil, width: 76, isAccent: true),
                FloatingKeyboardKey(title: "Space", token: "space", width: 360, isAccent: true),
                FloatingKeyboardKey(title: "Return", token: "return", width: 116, isAccent: true)
            ]
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Floating Keyboard")
                        .font(.title3.weight(.semibold))
                    Text("Four-finger swipe up shows this panel. Four-finger swipe down hides it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Hide", action: closeAction)
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ForEach(row) { key in
                            keyButton(key)
                        }
                    }
                }
            }

            if shiftEnabled {
                Text("Shift will apply to the next letter key.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .frame(width: 760)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    @ViewBuilder
    private func keyButton(_ key: FloatingKeyboardKey) -> some View {
        Button {
            handleKeyPress(key)
        } label: {
            Text(buttonTitle(for: key))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .frame(width: key.width, height: 56)
                .background(backgroundColor(for: key))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(
            FloatingKeyboardButtonStyle(
                isAccent: key.isAccent,
                isActive: key.title == "Shift" && shiftEnabled,
                isFlashing: flashedKeyID == key.id
            )
        )
    }

    private func handleKeyPress(_ key: FloatingKeyboardKey) {
        if key.title == "Shift" {
            flashKey(key.id)
            shiftEnabled.toggle()
            return
        }
        if key.title == "#+=" || key.title == "ABC" {
            flashKey(key.id)
            symbolKeyboardEnabled.toggle()
            return
        }
        guard let token = key.token else { return }
        let shouldShift = shiftEnabled
        flashKey(key.id)
        model.sendVirtualKeyboardKey(token: token, shifted: shouldShift)
        if shouldShift && token.range(of: #"^[a-z]$"#, options: .regularExpression) != nil {
            shiftEnabled = false
        }
    }

    private func flashKey(_ keyID: String) {
        flashedKeyID = nil
        flashedKeyID = keyID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if flashedKeyID == keyID {
                flashedKeyID = nil
            }
        }
    }

    private func buttonTitle(for key: FloatingKeyboardKey) -> String {
        if shiftEnabled && key.token?.range(of: #"^[a-z]$"#, options: .regularExpression) != nil {
            return key.title.uppercased()
        }
        return key.title
    }

    private func backgroundColor(for key: FloatingKeyboardKey) -> Color {
        if flashedKeyID == key.id {
            return Color.accentColor.opacity(0.28)
        }
        if key.title == "Shift" && shiftEnabled {
            return Color.accentColor.opacity(0.3)
        }
        if key.title == "#+=" || key.title == "ABC" {
            return Color.accentColor.opacity(symbolKeyboardEnabled ? 0.26 : 0.16)
        }
        if key.isAccent {
            return Color(nsColor: .controlAccentColor).opacity(0.16)
        }
        return Color(nsColor: .controlBackgroundColor)
    }
}


class FloatingKeyboardPanel: NSPanel {
    var model: TouchMyMac?

    static func panel(model: TouchMyMac) -> FloatingKeyboardPanel {
        let window = FloatingKeyboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 390),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        window.title = "Floating Keyboard"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.model = model

        let vc = NSHostingController(
            rootView: FloatingKeyboardView(model: model, closeAction: {
                window.close()
            })
        )
        let windowController = NSWindowController(window: window)
        windowController.contentViewController = vc

        return window
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func makeVisible() {
        if !self.isVisible {
            if let targetScreen = model?.touchscreen()?.systemScreen() ?? NSScreen.main {
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
}
