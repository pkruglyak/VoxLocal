import AppKit
import SwiftUI

/// Floating dictation indicator. A borderless, non-activating `NSPanel`
/// keeps keyboard focus in the user's current application.
@MainActor
public final class OverlayWindowController {
    private var panel: NSPanel?
    private weak var dictation: DictationController?
    private var hideTask: Task<Void, Never>?

    public init(dictation: DictationController) {
        self.dictation = dictation
        dictation.onStateChange = { [weak self] state in
            self?.handle(state: state)
        }
    }

    private func handle(state: DictationState) {
        switch state {
        case .idle:
            hide()
        case .preparing, .recording, .stopping, .transcribing, .refining, .inserting:
            show()
        case .completed, .cancelled, .error:
            show() // stays briefly; controller resets to .idle which hides it
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 270, height: 66),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        if let dictation {
            panel.contentView = NSHostingView(rootView: OverlayView(dictation: dictation))
        }
        return panel
    }

    public func show() {
        hideTask?.cancel()
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        if !panel.isVisible {
            position(panel)
            // orderFrontRegardless keeps the target app active/focused.
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// SwiftUI content of the overlay: a compact recording control pill while
/// listening, and short status feedback for the remaining pipeline states.
struct OverlayView: View {
    @ObservedObject var dictation: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if dictation.state == .recording {
                recordingPill
            } else {
                statusPill
            }
        }
        .frame(width: 270, height: 66)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.t("app.name")): \(title). \(subtitle)")
    }

    private var recordingPill: some View {
        HStack(spacing: 13) {
            Button {
                dictation.cancelDictation()
            } label: {
                Circle()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("overlay.esc"))

            LevelMeter(level: dictation.micLevel, animate: !reduceMotion)
                .frame(width: 106, height: 34)
                .accessibilityLabel(L10n.t("overlay.level.ax"))

            Button {
                dictation.stopAndProcess()
            } label: {
                Circle()
                    .fill(Color(red: 1.0, green: 0.44, blue: 0.51))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white)
                            .frame(width: 20, height: 20)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("menu.stop"))
        }
        .padding(.horizontal, 12)
        .frame(width: 250, height: 54)
        .background(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(Color.black.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            stateIcon
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(width: 250, height: 54)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var title: String {
        L10n.t("state.\(dictation.state.rawValue)")
    }

    private var subtitle: String {
        if !dictation.statusMessage.isEmpty {
            return dictation.statusMessage
        }
        switch dictation.state {
        case .recording, .transcribing, .refining:
            return L10n.t("overlay.esc")
        default:
            return ""
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch dictation.state {
        case .preparing:
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)
        case .stopping, .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .refining:
            Image(systemName: "wand.and.stars")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        case .inserting:
            Image(systemName: "text.insert")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

/// Compact waveform-style meter driven by the recorder's RMS level.
struct LevelMeter: View {
    let level: Float
    let animate: Bool
    private let barPattern: [CGFloat] = [0.38, 0.54, 0.72, 0.88, 1.0, 1.0, 0.88, 0.72, 0.54, 0.38]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(barPattern.indices, id: \.self) { index in
                let threshold = Float(index + 1) / Float(barPattern.count + 1)
                let boostedLevel = min(1, max(0.18, CGFloat(level) * 1.35))
                let height = 30 * barPattern[index] * (0.72 + boostedLevel * 0.42)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(level > threshold ? Color.white : Color.white.opacity(0.28))
                    .frame(width: 6, height: height)
            }
        }
        .animation(animate ? .linear(duration: 0.08) : nil, value: level)
    }
}
