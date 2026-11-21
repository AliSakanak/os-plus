import SwiftUI
import WorkbenchCore

struct GrabView: View {
    @Bindable var model: GrabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                if !model.hasScreenPermission { permissionBanner }
                historySection
            }
            .padding(12)
        }
        .onAppear { model.refreshPermission() }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tint)
            Text("Copy text from anywhere on screen")
                .font(.headline)
            Text("Drag a box over a video, an image, an error dialog or a slide. The text lands on your clipboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.grab()
            } label: {
                Label("Grab text", systemImage: "viewfinder")
                    .frame(maxWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isGrabbing)

            HStack(spacing: 6) {
                Text("Shortcut anywhere:")
                    .foregroundStyle(.secondary)
                Picker("Shortcut", selection: $model.shortcut) {
                    ForEach(GrabShortcut.allCases) { Text($0.label).tag($0) }
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
            Text("Press Space while selecting to grab a whole window, or Esc to cancel. Reads English and Spanish, plus QR codes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission needed", systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("macOS asks for this before any app can read what's on screen. Turn on OS+ in the list. If macOS asks, quit and reopen OS+.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { model.openPermissionSettings() }
                Button("Check again") { model.refreshPermission() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private var historySection: some View {
        HStack {
            Text("Recent grabs").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if !model.history.records.isEmpty {
                ConfirmButton(title: "Clear", confirmTitle: "Clear all?") { model.clearHistory() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        if model.history.records.isEmpty {
            Text("Nothing yet. Your last 30 grabs will appear here, saved only on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.history.records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider() }
                    GrabRow(record: record, model: model)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct GrabRow: View {
    let record: GrabRecord
    let model: GrabModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.text)
                    .font(.callout)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Text(record.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Button { model.copy(record) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy again")
            Button { model.delete(record) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.35)
                .help("Remove from history")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
