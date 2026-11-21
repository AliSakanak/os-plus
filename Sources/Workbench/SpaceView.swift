import SwiftUI
import WorkbenchCore

struct SpaceView: View {
    let model: SpaceModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Health", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("What's using space").font(.headline)
                Spacer()
                Button {
                    model.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isScanning)
                .help("Scan again")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    }
                    if model.isScanning && model.items.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Measuring folders… this can take a minute.").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        if model.totalReclaimable > 0 {
                            Text("About **\(Format.bytes(model.totalReclaimable))** can be safely moved to the Trash.")
                                .font(.callout)
                        }
                        section("Caches & common folders", nil, model.items)
                        if !model.nodeModules.isEmpty {
                            section("Project dependencies (node_modules)",
                                    "Run npm/pnpm install in the project to get them back.", model.nodeModules)
                        }
                        Text("Nothing is deleted. Items go to the Trash, so you can put them back until you empty it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ subtitle: String?, _ items: [SpaceItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    SpaceRow(item: item, model: model)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct SpaceRow: View {
    let item: SpaceItem
    let model: SpaceModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.bytes(item.bytes)).monospacedDigit().font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    Button("Show") { model.reveal(item) }
                    if item.canTrash {
                        ConfirmButton(title: "Trash", confirmTitle: "Move to Trash?") { model.moveToTrash(item) }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
