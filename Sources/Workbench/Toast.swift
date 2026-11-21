import AppKit
import SwiftUI

/// A small floating confirmation ("Copied 42 words") near the bottom of the screen the mouse is on.
/// It never takes focus or blocks clicks.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill", tint: Color = .green,
              duration: Duration = .seconds(2.2)) {
        let hosting = NSHostingView(rootView: ToastView(title: title, detail: detail, symbol: symbol, tint: tint))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(10)  // room for the shadow
    }
}
