import SwiftUI

extension Category {
    var color: Color {
        switch self {
        case .caches: return .teal
        case .developer: return .indigo
        case .trash: return Color(nsColor: .systemGray)
        case .downloads: return .blue
        case .media: return .pink
        case .documents: return .orange
        case .apps: return .purple
        case .appData: return .brown
        case .messages: return .green
        case .backups: return .mint
        case .virtualization: return .cyan
        case .cloud: return Color(red: 0.45, green: 0.62, blue: 0.85)
        case .system: return Color(nsColor: .systemGray).opacity(0.7)
        case .other: return .yellow
        }
    }

    var icon: String {
        switch self {
        case .caches: return "memorychip"
        case .developer: return "hammer"
        case .trash: return "trash"
        case .downloads: return "arrow.down.circle"
        case .media: return "photo.on.rectangle"
        case .documents: return "doc.text"
        case .apps: return "square.grid.2x2"
        case .appData: return "externaldrive.badge.person.crop"
        case .messages: return "envelope"
        case .backups: return "clock.arrow.circlepath"
        case .virtualization: return "shippingbox"
        case .cloud: return "icloud"
        case .system: return "gearshape.2"
        case .other: return "questionmark.folder"
        }
    }
}

extension Safety {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .keep: return .red
        }
    }

    var icon: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "eye.fill"
        case .keep: return "hand.raised.fill"
        }
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct SafetyBadge: View {
    var safety: Safety
    var body: some View { Badge(text: safety.title, color: safety.color, icon: safety.icon) }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct Segment: Identifiable {
    var id: String
    var color: Color
    var fraction: Double
    var label: String
}

/// A single horizontal bar split into coloured parts; whatever is left of the track stays empty.
struct SegmentedBar: View {
    var segments: [Segment]
    var height: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(.quaternary)
                HStack(spacing: 1.5) {
                    ForEach(segments) { segment in
                        Rectangle().fill(segment.color)
                            .frame(width: max(segment.fraction > 0 ? 2 : 0, geo.size.width * segment.fraction))
                            .help(segment.label)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map(\.label).joined(separator: ", "))
    }
}

struct SizeBar: View {
    var fraction: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

enum Fmt {
    static func size(_ bytes: Int64) -> String { ByteFormat.string(bytes) }

    /// `/Users/you/Projects/app` as `~/Projects/app`.
    static func shortPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = Localizer.shared.locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func dateTimeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Localizer.shared.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
