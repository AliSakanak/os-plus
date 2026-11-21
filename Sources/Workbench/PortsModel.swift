import AppKit
import Foundation
import Observation
import WorkbenchCore

@MainActor
@Observable
final class PortsModel {
    private(set) var ports: [ListeningPort] = []
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    var message: String?
    var showSystem = false

    private let runner = CommandRunner()
    private var timer: Timer?
    private var isVisible = false

    init() {
        refresh()
        schedule()
    }

    var devPorts: [ListeningPort] { ports.filter { $0.kind == .dev } }
    var appPorts: [ListeningPort] { ports.filter { $0.kind == .app } }
    var systemPorts: [ListeningPort] { ports.filter { $0.kind == .system } }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { refresh() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        // Keep the badge roughly current in the background; refresh quickly while visible.
        let interval: TimeInterval = isVisible ? 2 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let runner = self.runner
        Task {
            let result = await PortsReader.read(runner: runner)
            self.ports = result
            self.lastUpdated = Date()
            self.isLoading = false
        }
    }

    func open(_ port: ListeningPort) {
        if let url = port.url { NSWorkspace.shared.open(url) }
    }

    func copyURL(_ port: ListeningPort) {
        guard let url = port.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        message = "Copied \(url.absoluteString)"
    }

    func revealFolder(_ port: ListeningPort) {
        guard let dir = port.workingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    func stop(_ port: ListeningPort, force: Bool) {
        do {
            try PortsReader.stop(pid: port.pid, force: force)
            message = force
                ? "Force-stopped \(port.displayName) on :\(port.port)."
                : "Asked \(port.displayName) on :\(port.port) to stop."
            // Give it a moment to exit before re-reading.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                refresh()
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
