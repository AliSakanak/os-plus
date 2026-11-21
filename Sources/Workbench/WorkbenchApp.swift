import SwiftUI
import WorkbenchCore

@main
struct WorkbenchApp: App {
    init() {
        // `Workbench --search-cli "query"` prints finder results and exits: lets search be checked
        // from a terminal without opening any windows.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--search-cli"), i + 1 < args.count {
            let query = args[i + 1]
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await SearchCLI.run(query)
                done.signal()
            }
            done.wait()
            exit(0)
        }
        // `Workbench --sound-cli list|output-test|selftest` checks per-app volume and exits.
        if let i = args.firstIndex(of: "--sound-cli") {
            exit(SoundCLI.run(i + 1 < args.count ? args[i + 1] : ""))
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RootView(health: delegate.health, ports: delegate.ports, space: delegate.space, grab: delegate.grab,
                     downloads: delegate.downloads, finder: delegate.finder, sound: delegate.sound)
        } label: {
            Image(nsImage: MenuBarGlyph.image(alert: delegate.health.overall == .act))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let health = HealthModel()
    let ports = PortsModel()
    let space = SpaceModel()
    let grab = GrabModel()
    let downloads = DownloadsModel()
    let finder = FinderModel()
    let sound = SoundModel()
    private var debugWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        // macOS removes our audio taps when the process exits anyway; this just does it tidily.
        sound.stopAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Workbench --debug-window [--tab ports]` shows the popover content in a normal window,
        // so it can be screenshotted (`screencapture -l <id>`) without clicking the menu bar.
        let args = CommandLine.arguments
        if args.contains("--demo-toast") {
            Toast.shared.show("Copied 8 words", detail: "Error 403: Access denied Retry in 30 seconds",
                              symbol: "text.viewfinder", duration: .seconds(8))
        }
        if let i = args.firstIndex(of: "--demo-find") {
            finder.showPanel()
            if i + 1 < args.count { finder.query = args[i + 1] }
        }
        if args.contains("--demo-sound") { sound.showPreview() }
        // `Workbench --snapshot <tab> <out.png> [height]` renders a tab off-screen to a PNG and quits
        // (works even when the screen is locked; used for README screenshots).
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count, let tab = Tab(rawValue: args[i + 1].capitalized) {
            let out = args[i + 2]
            let height = i + 3 < args.count ? CGFloat(Double(args[i + 3]) ?? 600) : 600
            UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
            let view = NSHostingView(rootView: RootView(health: health, ports: ports, space: space, grab: grab,
                                                        downloads: downloads, finder: finder, sound: sound, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.orderBack(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))   // let the models load real data
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
            return
        }
        guard args.contains("--debug-window") else { return }
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let tab = Tab(rawValue: args[i + 1].capitalized) {
            UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
        }
        var height: CGFloat = 600
        if let i = args.firstIndex(of: "--height"), i + 1 < args.count, let h = Double(args[i + 1]) { height = h }
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 420, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "OS+"
        window.contentView = NSHostingView(rootView: RootView(health: health, ports: ports, space: space, grab: grab, downloads: downloads,
                                                              finder: finder, sound: sound, height: height))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        debugWindow = window
        print("WINDOW_ID \(window.windowNumber)")
        fflush(stdout)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case health = "Health"
    case ports = "Ports"
    case text = "Text"
    case downloads = "Downloads"
    case find = "Find"
    case sound = "Sound"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .health: "heart.text.square"
        case .ports: "network"
        case .text: "text.viewfinder"
        case .downloads: "arrow.down.circle"
        case .find: "sparkle.magnifyingglass"
        case .sound: "speaker.wave.2"
        }
    }
}

struct RootView: View {
    let health: HealthModel
    let ports: PortsModel
    let space: SpaceModel
    let grab: GrabModel
    let downloads: DownloadsModel
    let finder: FinderModel
    let sound: SoundModel
    var height: CGFloat = 600
    @AppStorage("selectedTab") private var tab: Tab = .health

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab, portsBadge: ports.devPorts.count)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            Group {
                switch tab {
                case .health: HealthView(model: health, space: space)
                case .ports: PortsView(model: ports)
                case .text: GrabView(model: grab)
                case .downloads: DownloadsView(model: downloads)
                case .find: FindTabView(model: finder)
                case .sound: SoundView(model: sound)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            FooterView(lastUpdated: tab == .health ? health.lastUpdated : tab == .ports ? ports.lastUpdated : nil)
        }
        .frame(width: 420, height: height)
        .onAppear {
            health.setVisible(true)
            ports.setVisible(tab == .ports)
            downloads.setVisible(tab == .downloads)
            sound.setVisible(tab == .sound)
        }
        .onDisappear {
            health.setVisible(false)
            ports.setVisible(false)
            downloads.setVisible(false)
            sound.setVisible(false)
        }
        .onChange(of: tab) { _, new in
            ports.setVisible(new == .ports)
            downloads.setVisible(new == .downloads)
            sound.setVisible(new == .sound)
        }
    }
}

struct TabBar: View {
    @Binding var selection: Tab
    var portsBadge: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: selection == tab ? .semibold : .regular))
                            .frame(height: 20)
                            .overlay(alignment: .topTrailing) {
                                if tab == .ports, portsBadge > 0 {
                                    Text("\(portsBadge)")
                                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor))
                                        .offset(x: 10, y: -4)
                                }
                            }
                        Text(tab.rawValue)
                            .font(.caption.weight(selection == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == tab ? Color.primary.opacity(0.09) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
            }
        }
    }
}

struct FooterView: View {
    var lastUpdated: Date?
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        HStack(spacing: 12) {
            if let lastUpdated {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, wanted in
                    loginError = LoginItem.set(enabled: wanted)
                    launchAtLogin = LoginItem.isEnabled
                }
                .help(loginError ?? "Start OS+ when you log in")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
