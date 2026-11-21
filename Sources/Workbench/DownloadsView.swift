import AppKit
import SwiftUI
import WorkbenchCore

struct DownloadsView: View {
    @Bindable var model: DownloadsModel

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let message = model.message { banner(message) }
                    content
                }
                .padding(12)
            }
        }
    }

    // MARK: Header

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $model.filter) {
                ForEach(DownloadsFilter.allCases) { f in
                    let n = model.count(for: f)
                    Text(f == .all ? "All \(n)" : "\(f.shortLabel) \(n)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name or website", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !model.undoable.isEmpty {
                Button("Undo") { model.undoTrash() }
                    .font(.callout.weight(.semibold))
            }
            Button { model.dismissMessage() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        let items = model.visibleItems
        if let error = model.loadError {
            EmptyState(symbol: "lock", title: "Can't read Downloads",
                       message: "\(error)\nAllow OS+ in System Settings → Privacy & Security → Files and Folders.")
        } else if !model.hasLoaded {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 40)
        } else if items.isEmpty {
            EmptyState(symbol: model.filter == .all ? "tray" : "checkmark.circle",
                       title: model.filter == .all ? "Downloads is empty" : "Nothing here",
                       message: model.filter == .all ? "New downloads will show up here." : model.filter.explanation)
        } else {
            summary(items)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 46) }
                    DownloadRow(item: item, model: model)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }

    private func summary(_ items: [DownloadItem]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(items.count) \(items.count == 1 ? "item" : "items") · \(Format.bytes(model.visibleTotal))")
                    .font(.callout.weight(.medium))
                if model.filter != .all {
                    Text(model.filter.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.filter != .all {
                ConfirmButton(title: "Trash all \(items.count)", confirmTitle: "Move \(items.count) to Trash?") {
                    model.trash(items)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let model: DownloadsModel
    @State private var hovering = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var isRenaming: Bool { model.renamingID == item.id }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { model.rename(item, to: draftName) }
                        .onExitCommand { model.renamingID = nil }
                        .onAppear {
                            draftName = item.url.deletingPathExtension().lastPathComponent
                            nameFocused = true
                        }
                } else {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isRenaming {
                Button("Save") { model.rename(item, to: draftName) }
                    .controlSize(.small)
            } else {
                if hovering {
                    ConfirmButton(title: "Trash", confirmTitle: "Trash?", symbol: "trash") { model.trash([item]) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                actionsMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .draggable(item.url)   // drag straight into Mail, Slack, Finder…
        .help(item.whereFrom.first.map { "Downloaded from \($0)" } ?? item.name)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let host = item.sourceHost { parts.append(host) }
        parts.append(item.dateAdded.formatted(.relative(presentation: .named)))
        if let size = model.size(of: item) { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    private var actionsMenu: some View {
        Menu {
            Button("Open") { model.open(item) }
            Button("Show in Finder") { model.reveal(item) }
            Button("Rename…") { model.renamingID = item.id }
            Menu("Move to") {
                ForEach(model.quickDestinations, id: \.path) { folder in
                    Button(folder.lastPathComponent) { model.move(item, to: folder) }
                }
                Divider()
                Button("Choose Folder…") { model.chooseFolderAndMove(item) }
            }
            if item.sourceURL != nil {
                Divider()
                Button("Open Source Page") { model.openSource(item) }
                Button("Copy Source Link") { model.copySource(item) }
            }
            Divider()
            Button("Move to Trash") { model.trash([item]) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
