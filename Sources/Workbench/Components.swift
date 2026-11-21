import SwiftUI
import WorkbenchCore

extension Verdict {
    var color: Color {
        switch self {
        case .good: .green
        case .watch: .orange
        case .act: .red
        case .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .watch: "exclamationmark.circle.fill"
        case .act: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// A rounded panel with an icon, title, verdict and free-form content.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let assessment: Assessment?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title).font(.headline)
                Spacer()
                if let assessment {
                    Label(assessment.verdict.label, systemImage: assessment.verdict.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(assessment.verdict.color)
                }
            }
            content
            if let assessment {
                Text(assessment.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

/// A big number with a smaller caption beside it: "89%  of original capacity".
struct Headline: View {
    let value: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Horizontal fill bar, 0…1.
struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityValue(Text(Format.percent(fraction * 100)))
    }
}

/// "Label ............ value" row.
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Collapsible list of the apps using the most of something.
struct TopAppsList: View {
    let title: String
    let apps: [AppUsage]
    let value: (AppUsage) -> String
    @State private var expanded = false

    var body: some View {
        if !apps.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 4) {
                    ForEach(apps) { app in
                        HStack {
                            Text(app.name).lineLimit(1).truncationMode(.middle)
                            if app.processCount > 1 {
                                Text("×\(app.processCount)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(value(app)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(title).font(.callout)
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}
