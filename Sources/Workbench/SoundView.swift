import SwiftUI
import WorkbenchCore

struct SoundView: View {
    let model: SoundModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.canControl {
                    PermissionCard(model: model)
                }

                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.fill")
                        .foregroundStyle(.secondary)
                    Text(model.outputName ?? "No output device")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    if model.anyChanged {
                        Button("Reset all") { model.resetAll() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .help("Put every app back to its normal volume")
                    }
                }

                if model.rows.isEmpty {
                    EmptyState(symbol: "speaker.slash", title: "No apps are using sound",
                               message: "Apps show up here once they've played something.")
                } else {
                    section("Playing now", model.playing)
                    section("Other apps", model.quiet)
                }

                Text("Volumes are relative to your Mac's volume, and reset when OS+ quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [SoundRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 46) }
                        SoundAppRow(row: row, model: model)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            }
        }
    }
}

private struct SoundAppRow: View {
    let row: SoundRow
    let model: SoundModel

    private var levelText: String {
        if row.setting.muted { return "Muted" }
        return Format.percent(row.setting.level * 100)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: model.icon(for: row))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .opacity(row.setting.muted ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    if row.isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !row.setting.muted)
                            .help("Playing sound now")
                    }
                    Spacer(minLength: 4)
                    Text(levelText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(row.setting.needsTap ? (row.setting.muted ? Color.red : Color.primary) : Color.secondary)
                }
                Slider(value: Binding(get: { row.setting.muted ? 0 : row.setting.level },
                                      set: { model.setLevel($0, for: row.id) }),
                       in: 0...1)
                    .controlSize(.small)
                    .disabled(!model.canControl)
                    .accessibilityLabel("\(row.name) volume")
                if let error = row.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                model.toggleMute(row.id)
            } label: {
                Image(systemName: row.setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.setting.muted ? Color.red : Color.secondary)
            .disabled(!model.canControl)
            .help(row.setting.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Back to 100%") { model.reset(row.id) }
                .disabled(!row.setting.needsTap)
        }
    }
}

private struct PermissionCard: View {
    let model: SoundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("One permission needed", systemImage: "lock.shield")
                .font(.headline)
            Text("To turn other apps up and down, OS+ routes their sound through itself. macOS calls this "
                 + "“System Audio Recording”. Nothing is recorded or saved; it goes straight to your speakers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.permission == .denied {
                Text("It's switched off. In System Settings → Privacy & Security → Screen & System Audio Recording, "
                     + "turn on OS+ under “System Audio Recording Only”.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.openPrivacySettings() }
            } else {
                HStack(spacing: 12) {
                    Button(model.isRequestingPermission ? "Waiting for macOS…" : "Allow…") { model.requestPermission() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRequestingPermission)
                    // Fallback if macOS doesn't show its prompt: add Workbench by hand there.
                    Button("Open System Settings") { model.openPrivacySettings() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
    }
}
