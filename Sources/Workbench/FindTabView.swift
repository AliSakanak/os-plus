import SwiftUI
import WorkbenchCore

/// The popover tab: explains the finder, opens it, and shows its settings.
struct FindTabView: View {
    @Bindable var model: FinderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tint)
                    Text("Find files the way you remember them")
                        .font(.headline)
                    Text("Typos are fine (\"stava\"), initials work (\"sfa\"), and you can describe it: \"lease pdf from last spring\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.showPanel()
                    } label: {
                        Label("Open finder", systemImage: "magnifyingglass").frame(maxWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 6) {
                        Text("Shortcut anywhere:").foregroundStyle(.secondary)
                        Picker("Shortcut", selection: $model.shortcut) {
                            ForEach(FinderShortcut.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .font(.callout)
                    if !model.hotKeyRegistered {
                        Text("Another app is using \(model.shortcut.label). Pick a different shortcut.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Searching in").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isIndexing ? "Indexing…" : "Re-index") { model.reindex() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(model.isIndexing)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.roots, id: \.self) { root in
                            Label(root.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                                .font(.callout)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .onAppear { model.refreshIndexIfStale() }
    }

    private var statusLine: String {
        var parts: [String] = []
        if let at = model.indexedAt {
            parts.append("\(model.entryCount.formatted()) files, indexed \(at.formatted(.relative(presentation: .named))).")
        }
        parts.append("Skips hidden folders, node_modules and build output.")
        if let note = model.modelNote {
            parts.append(note)
        } else {
            parts.append("Uses Apple's on-device model to think of other words. Nothing leaves your Mac.")
        }
        return parts.joined(separator: " ")
    }
}
