import SwiftUI
import DriveCheckMenuCore

extension HealthLevel {
    var color: Color {
        switch self {
        case .ok: return .secondary
        case .unknown: return .gray
        case .warning: return .yellow
        case .problem: return .red
        }
    }
}

struct StatusDot: View {
    let level: HealthLevel

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 9, height: 9)
    }
}

struct HealthBadge: View {
    let level: HealthLevel

    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(level.color.opacity(0.16)))
            .foregroundStyle(level.color)
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
