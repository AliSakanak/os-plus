import AppKit
import SwiftUI
import WorkbenchCore

/// Borderless panels can't take keyboard focus by default; this one can.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FinderPanelController: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private weak var model: FinderModel?

    var isVisible: Bool { panel.isVisible }

    init(model: FinderModel) {
        self.model = model
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                             styleMask: [.borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FinderView(model: model))
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.18))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Clicking anywhere else dismisses it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

struct FinderView: View {
    @Bindable var model: FinderModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.understood.isEmpty || model.alternativesNote != nil || model.isThinking || model.relaxedNote != nil {
                interpretation
            }
            Divider().opacity(model.query.isEmpty ? 0 : 1)
            results
            footer
        }
        .frame(width: 680, height: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .onAppear { focused = true }
        .onExitCommand { model.hidePanel() }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find a file… try \"lease pdf from last spring\"", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($focused)
                .onSubmit { model.open() }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.command) { model.reveal(); return .handled }
                    return .ignored
                }
                .onKeyPress(characters: ["c"]) { press in
                    // ⌘C copies the selected file's path when no text is selected in the field.
                    guard press.modifiers.contains(.command), model.selectedHit != nil else { return .ignored }
                    model.copyPath()
                    return .handled
                }
            if model.isIndexing { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var interpretation: some View {
        HStack(spacing: 6) {
            ForEach(model.understood, id: \.self) { chip in
                Text(chip)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            if let relaxed = model.relaxedNote {
                Text(relaxed).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            if model.isThinking {
                ProgressView().controlSize(.mini)
                Text("Thinking of other words…").font(.caption).foregroundStyle(.secondary)
            } else if let note = model.alternativesNote {
                Label(note, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var results: some View {
        if model.query.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text("Search names, even with typos, or describe it:")
                    .foregroundStyle(.secondary)
                Text("\"stava footy\"  ·  \"invoice last month\"  ·  \"photos 3 weeks ago\"  ·  \"sfa\"")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.hits.isEmpty && !model.isIndexing && !model.isThinking {
            VStack {
                Spacer()
                Text("No matches in \(model.roots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.hits.enumerated()), id: \.element.entry.path) { index, hit in
                            FinderRow(hit: hit, selected: index == model.selection)
                                .id(index)
                                .onTapGesture(count: 2) { model.open(hit) }
                                .onTapGesture { model.selection = index }
                                .draggable(URL(fileURLWithPath: hit.entry.path))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selection) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Group {
                Text("↩ open")
                Text("⌘↩ show in Finder")
                Text("⌘C copy path")
                Text("esc close")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            Spacer()
            Text(model.isIndexing ? "Indexing…" : "\(model.entryCount.formatted()) files")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct FinderRow: View {
    let hit: SearchHit
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.entry.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.entry.displayFolder)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(hit.entry.modified.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}
