import AppKit
import CoreGraphics
import Foundation
import Observation
import WorkbenchCore

@MainActor
@Observable
final class GrabModel {
    private(set) var history: GrabHistory
    private(set) var isGrabbing = false
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var hotKeyRegistered = false

    var shortcut: GrabShortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "grabShortcut")
            registerHotKey()
        }
    }

    private let runner = CommandRunner()

    init() {
        history = GrabHistory.load()
        shortcut = UserDefaults.standard.string(forKey: "grabShortcut").flatMap(GrabShortcut.init) ?? .commandShift2
        registerHotKey()
    }

    private func registerHotKey() {
        hotKeyRegistered = HotKeyCenter.shared.register(id: 1, keyCode: shortcut.keyCode,
                                                        modifiers: shortcut.modifiers) { [weak self] in
            self?.grab()
        }
    }

    func refreshPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func openPermissionSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Drag-select a region (Apple's own crosshair UI), OCR it, copy the text.
    func grab() {
        guard !isGrabbing else { return }
        refreshPermission()
        guard hasScreenPermission else {
            CGRequestScreenCaptureAccess()
            Toast.shared.show("Screen Recording permission needed",
                              detail: "Allow OS+ in System Settings → Privacy & Security → Screen Recording.",
                              symbol: "lock.fill", tint: .orange, duration: .seconds(5))
            return
        }
        isGrabbing = true
        closeMenuBarWindow()

        let runner = self.runner
        Task {
            defer { isGrabbing = false }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("workbench-grab-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }

            // -i: interactive selection (Space toggles window mode, Esc cancels), -x: no sound, -o: no window shadow.
            _ = try? await runner.run("/usr/sbin/screencapture", ["-i", "-x", "-o", url.path], timeout: 600)
            guard FileManager.default.fileExists(atPath: url.path) else { return }  // cancelled with Esc

            do {
                let result = try await TextRecognizer.recognize(imageAt: url)
                guard !result.isEmpty else {
                    Toast.shared.show("No text found", detail: "Try selecting a larger area.",
                                      symbol: "text.magnifyingglass", tint: .orange)
                    return
                }
                let text = result.clipboardText
                copyToClipboard(text)
                history.add(text)
                saveHistory()
                Toast.shared.show(result.summary, detail: text.replacingOccurrences(of: "\n", with: " "),
                                  symbol: result.lines.isEmpty ? "qrcode" : "text.viewfinder")
            } catch {
                Toast.shared.show("Couldn't read the text", detail: error.localizedDescription,
                                  symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
    }

    func copy(_ record: GrabRecord) {
        copyToClipboard(record.text)
        Toast.shared.show("Copied", detail: record.text.replacingOccurrences(of: "\n", with: " "))
    }

    func delete(_ record: GrabRecord) {
        history.remove(id: record.id)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveHistory() {
        try? history.save()
    }

    /// Hide the popover so it isn't in the way of the selection.
    private func closeMenuBarWindow() {
        for window in NSApp.windows where window.isVisible && window.className.contains("MenuBarExtra") {
            window.close()
        }
    }
}
