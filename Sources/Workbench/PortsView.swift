import SwiftUI
import WorkbenchCore

struct PortsView: View {
    @Bindable var model: PortsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let message = model.message {
                    HStack {
                        Text(message).font(.callout)
                        Spacer()
                        Button { model.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                }

                if model.ports.isEmpty && model.lastUpdated != nil {
                    EmptyState(symbol: "network.slash", title: "Nothing is listening",
                               message: "When you start a dev server it'll show up here.")
                } else {
                    section("Your servers", model.devPorts,
                            empty: "No dev servers running. Start one and it'll appear here.")
                    if !model.appPorts.isEmpty {
                        section("Apps", model.appPorts, empty: nil)
                    }
                    Toggle("Show macOS services (\(model.systemPorts.count))", isOn: $model.showSystem)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    if model.showSystem {
                        section("macOS", model.systemPorts, empty: nil)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ ports: [ListeningPort], empty: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if ports.isEmpty, let empty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                        if index > 0 { Divider() }
                        PortRow(port: port, model: model)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            }
        }
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let model: PortsModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(":\(String(port.port))")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.displayName).lineLimit(1)
                    if !port.isLocalOnly {
                        Image(systemName: "wifi")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Reachable from other devices on your network")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(port.command ?? port.processName)

            Spacer(minLength: 4)

            if port.kind == .dev && port.looksLikeWebServer {
                Button { model.open(port) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open http://localhost:\(String(port.port))")
            }
            Menu {
                if port.looksLikeWebServer {
                    Button("Open in Browser") { model.open(port) }
                }
                Button("Copy URL") { model.copyURL(port) }
                if port.workingDirectory != nil, port.workingDirectory != "/" {
                    Button("Show Folder in Finder") { model.revealFolder(port) }
                }
                Divider()
                Button("Stop") { model.stop(port, force: false) }
                Button("Force Stop") { model.stop(port, force: true) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if port.kind == .dev {
                ConfirmButton(title: "Stop", confirmTitle: "Stop?", symbol: "stop.circle") {
                    model.stop(port, force: false)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let project = port.projectName { parts.append(project) }
        parts.append("pid \(port.pid)")
        if let elapsed = port.elapsedSeconds { parts.append("up \(Format.duration(elapsed))") }
        return parts.joined(separator: " · ")
    }
}
