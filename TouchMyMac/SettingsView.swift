//
//  SettingsView.swift
//  TouchMyMac
//
//  Created by Sebastian Hueber on 03.02.23.
//

import SwiftUI
import TouchUpCore

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case gestures
    case tuning
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .gestures: return "Gestures"
        case .tuning: return "Tuning"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Input and screen routing"
        case .gestures: return "Gesture actions and mappings"
        case .tuning: return "Thresholds and scrolling"
        case .diagnostics: return "Debug and live status"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .gestures: return "hand.tap"
        case .tuning: return "slider.horizontal.3"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct SettingsView: View {

    @ObservedObject var model: TouchMyMac
    @State private var selectedPane: SettingsPane = .general

    static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var connectedScreenSelection: Binding<UInt> {
        Binding {
            model.connectedTouchscreen?.id ?? 0
        } set: { value in
            model.connectedTouchscreen = model.connectedScreens.first(where: { $0.id == value })
            model.rememeberCues()
        }
    }

    private var scrollSpeedBinding: Binding<Double> {
        Binding {
            Double(model.scrollSpeedMultiplier)
        } set: { value in
            model.scrollSpeedMultiplier = CGFloat(value)
        }
    }

    private var inertiaAmountBinding: Binding<Double> {
        Binding {
            Double(model.scrollInertiaVelocityMultiplier)
        } set: { value in
            model.scrollInertiaVelocityMultiplier = CGFloat(value)
        }
    }

    private var inertiaDecayBinding: Binding<Double> {
        Binding {
            Double(model.scrollInertiaDecelerationPerFrame)
        } set: { value in
            model.scrollInertiaDecelerationPerFrame = CGFloat(value)
        }
    }

    private var errorResistanceBinding: Binding<Double> {
        Binding {
            Double(model.errorResistance)
        } set: { value in
            model.errorResistance = NSInteger(Int(value))
        }
    }

    private var doubleClickDistanceBinding: Binding<Double> {
        Binding {
            Double(model.doubleClickDistance)
        } set: { value in
            model.doubleClickDistance = CGFloat(Int(value))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TouchMyMac")
                    .font(.title3.weight(.semibold))
                Text("Preferences")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 14)

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    paneButton(pane)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func paneButton(_ pane: SettingsPane) -> some View {
        let isSelected = selectedPane == pane

        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(pane.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader

                switch selectedPane {
                case .general:
                    generalPane
                case .gestures:
                    gesturesPane
                case .tuning:
                    tuningPane
                case .diagnostics:
                    diagnosticsPane
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedPane.title)
                .font(.system(size: 29, weight: .bold))
            Text(selectedPane.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.isAccessibilityAccessGranted {
                accessBanner
            }

            SettingsGroup(title: "Input") {
                settingToggleRow(
                    labels: model.uiLabels(for: \.isPublishingMouseEventsEnabled),
                    isOn: $model.isPublishingMouseEventsEnabled
                )

                sectionDivider

                VStack(alignment: .leading, spacing: 8) {
                    SettingText(labels: model.uiLabels(for: \.connectedTouchscreen))

                    if model.connectedScreens.isEmpty {
                        Text("No connected touchscreen detected yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: connectedScreenSelection) {
                            ForEach(model.connectedScreens) { screen in
                                Text(screen.name).tag(screen.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
            }

            SettingsGroup(title: "Status") {
                settingValueRow("Accessibility", value: model.accessibilityTrustedNow ? "Granted" : "Missing")
                sectionDivider
                settingValueRow("Input Publishing", value: model.isPublishingMouseEventsEnabled ? "Enabled" : "Disabled")
                sectionDivider
                settingValueRow("Connection", value: String(describing: model.connectionState))
                sectionDivider
                settingValueRow("Assigned Screen", value: model.connectedTouchscreen?.name ?? "(Auto)")
            }

            SettingsGroup(title: "About") {
                footer
            }
        }
    }

    private var gesturesPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Gesture Toggles") {
                settingToggleRow(labels: model.uiLabels(for: \.isSecondaryClickEnabled), isOn: $model.isSecondaryClickEnabled)
                sectionDivider
                settingToggleRow(labels: model.uiLabels(for: \.isMagnificationEnabled), isOn: $model.isMagnificationEnabled)
                sectionDivider
                settingToggleRow(labels: model.uiLabels(for: \.isThreeFingerSwipeEnabled), isOn: $model.isThreeFingerSwipeEnabled)
                sectionDivider
                settingToggleRow(labels: model.uiLabels(for: \.isThreeFingerSwipeSpacesEnabled), isOn: $model.isThreeFingerSwipeSpacesEnabled)
                sectionDivider
                settingToggleRow(labels: model.uiLabels(for: \.isFourFingerSwipeUpKeyboardEnabled), isOn: $model.isFourFingerSwipeUpKeyboardEnabled)
            }

            SettingsGroup(title: "Shortcut Mapping") {
                shortcutFieldRow(
                    labels: model.uiLabels(for: \.fiveFingerHoldShortcutSpec),
                    placeholder: "fn",
                    text: $model.fiveFingerHoldShortcutSpec,
                    hint: "Example: fn or cmd+shift"
                )
                sectionDivider
                shortcutFieldRow(
                    labels: model.uiLabels(for: \.fourFingerSwipeLeftSequenceSpec),
                    placeholder: "cmd+a, delete",
                    text: $model.fourFingerSwipeLeftSequenceSpec,
                    hint: "Example: cmd+a, delete"
                )
            }
        }
    }

    private var tuningPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Touch Timing") {
                sliderRow(
                    labels: model.uiLabels(for: \.holdDuration),
                    value: $model.holdDuration,
                    range: 0.0...0.16,
                    step: 0.02,
                    currentText: { String(format: "Current %.2f s", $0) },
                    minText: "0.00 s",
                    maxText: "0.16 s"
                )
                sectionDivider
                sliderRow(
                    labels: model.uiLabels(for: \.doubleClickDistance),
                    value: doubleClickDistanceBinding,
                    range: 0...8,
                    step: 1,
                    currentText: { "Current \(Int($0)) mm" },
                    minText: "0 mm",
                    maxText: "8 mm"
                )
            }

            SettingsGroup(title: "Scroll") {
                settingToggleRow(labels: model.uiLabels(for: \.isScrollInertiaEnabled), isOn: $model.isScrollInertiaEnabled)
                sectionDivider
                sliderRow(
                    labels: model.uiLabels(for: \.scrollSpeedMultiplier),
                    value: scrollSpeedBinding,
                    range: 0.5...3.0,
                    step: 0.1,
                    currentText: { String(format: "Current %.1fx", $0) },
                    minText: "0.5x",
                    maxText: "3.0x"
                )
                sectionDivider
                sliderRow(
                    labels: model.uiLabels(for: \.scrollInertiaVelocityMultiplier),
                    value: inertiaAmountBinding,
                    range: 0.5...2.0,
                    step: 0.05,
                    currentText: { String(format: "Current %.2fx", $0) },
                    minText: "0.5x",
                    maxText: "2.0x",
                    disabled: !model.isScrollInertiaEnabled
                )
                sectionDivider
                sliderRow(
                    labels: model.uiLabels(for: \.scrollInertiaDecelerationPerFrame),
                    value: inertiaDecayBinding,
                    range: 0.85...0.99,
                    step: 0.005,
                    currentText: { String(format: "Current %.3f", $0) },
                    minText: "0.850",
                    maxText: "0.990",
                    disabled: !model.isScrollInertiaEnabled
                )
            }

            SettingsGroup(title: "Reliability") {
                sliderRow(
                    labels: model.uiLabels(for: \.errorResistance),
                    value: errorResistanceBinding,
                    range: 0...10,
                    step: 1,
                    currentText: { "Current \(Int($0))" },
                    minText: "0",
                    maxText: "10"
                )
                sectionDivider
                settingToggleRow(labels: model.uiLabels(for: \.ignoreOriginTouches), isOn: $model.ignoreOriginTouches)
            }
        }
    }

    private var diagnosticsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Actions") {
                actionRow(title: "Grant Accessibility Access", action: model.grantAccessibilityAccess)
                sectionDivider
                actionRow(title: "Restart Input Pipeline", action: model.restartInputPipeline)
                sectionDivider
                actionRow(title: "Refresh Touch Connection", action: model.refreshTouchConnection)
                sectionDivider
                actionRow(title: "Reset Diagnostics", action: model.resetDiagnostics)
                sectionDivider
                actionRow(title: "Open Fullscreen Test Environment") {
                    (NSApp.delegate as? AppDelegate)?.showDebugOverlay()
                }
            }

            SettingsGroup(title: "Live Diagnostics") {
                diagnosticsTextLine("Status", model.suggestedBlocker())
                diagnosticsTextLine("Accessibility (Cached)", model.isAccessibilityAccessGranted ? "Granted" : "Missing")
                diagnosticsTextLine("Accessibility (Live)", model.accessibilityTrustedNow ? "Granted" : "Missing")
                diagnosticsTextLine("Input Enabled", model.isPublishingMouseEventsEnabled ? "Yes" : "No")
                diagnosticsTextLine("Connection", String(describing: model.connectionState))
                diagnosticsTextLine("Connected Screens", "\(model.connectedScreens.count)")
                diagnosticsTextLine("Assigned Screen", model.connectedTouchscreen?.name ?? "(Auto)")
                diagnosticsTextLine("Touch Reports", "\(model.touchUpdateCount)")
                diagnosticsTextLine("Last Active Touches", "\(model.lastActiveTouchCount)")
                diagnosticsTextLine("Gesture Decisions", "\(model.gestureDecisionCount)")
                diagnosticsTextLine("Current Gesture", model.currentGestureName)
                diagnosticsTextLine("Current Action", model.currentActionName)
                diagnosticsTextLine("Last Gesture -> Action", "\(model.lastGestureName) -> \(model.lastActionName)")
                diagnosticsTextLine("Input Frame", "\(model.inputProcessFrameID)")
                diagnosticsTextLine("Input Active Touches", "\(model.inputActiveTouchCount)")
                diagnosticsTextLine("3F Session", model.threeFingerTracking ? "Active" : "Idle")
                diagnosticsTextLine("3F Triggered", model.threeFingerTriggered ? "Yes" : "No")
                diagnosticsTextLine("3F Touches / Upward", "\(model.threeFingerTouchCount) / \(model.threeFingerUpwardTouchCount)")
                diagnosticsTextLine("3F Travel V / H", String(format: "%.1f / %.1f mm", model.threeFingerVerticalTravelMM, model.threeFingerHorizontalTravelMM))
                diagnosticsTextLine("HID Connect / Disconnect", "\(model.hidConnectCount) / \(model.hidDisconnectCount)")
                diagnosticsTextLine("Last Touch Update", formatDate(model.lastTouchUpdateAt))

                if !model.diagnosticsEvents.isEmpty {
                    sectionDivider
                    eventBlock(title: "Recent Diagnostics", events: Array(model.diagnosticsEvents.prefix(8)))
                }

                if !model.recentGestureEvents.isEmpty {
                    sectionDivider
                    eventBlock(title: "Recent Gesture Stream", events: Array(model.recentGestureEvents.prefix(10)))
                }
            }

        }
    }

    private var accessBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility Access Required")
                    .font(.headline)
                Text("TouchMyMac needs Accessibility access before macOS will accept the injected mouse and keyboard events.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Grant Access") {
                model.grantAccessibilityAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func settingToggleRow(labels: (title: String, description: String), isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SettingText(labels: labels)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    private func shortcutFieldRow(labels: (title: String, description: String), placeholder: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingText(labels: labels)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func sliderRow(labels: (title: String, description: String), value: Binding<Double>, range: ClosedRange<Double>, step: Double, currentText: @escaping (Double) -> String, minText: String, maxText: String, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingText(labels: labels)

            Slider(value: value, in: range, step: step)
                .disabled(disabled)

            HStack {
                Text(minText)
                Spacer()
                Text(currentText(value.wrappedValue))
                Spacer()
                Text(maxText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if disabled {
                Text("Enable Scroll Inertia to adjust this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .opacity(disabled ? 0.55 : 1)
    }

    private func settingValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func actionRow(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func diagnosticsTextLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(title):")
                .foregroundStyle(.primary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.vertical, 2)
    }

    private func eventBlock(title: String, events: [DiagnosticsEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(events) { event in
                Text("[\(formatDate(event.time))] \(event.message)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color(nsColor: .separatorColor))
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("TouchMyMac v\(versionString)")
                        .font(.headline)
                }

                Text("Touch input for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Link(destination: URL(string: "https://github.com/jinghuichen/touchMyMac")!) {
                Label("GitHub", systemImage: "link")
            }
        }
        .padding(.vertical, 8)
    }

    func formatDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.diagnosticsDateFormatter.string(from: date)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}

private struct SettingText: View {
    let labels: (title: String, description: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(labels.title)
                .font(.body.weight(.medium))
            Text(labels.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
