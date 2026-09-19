import SwiftUI

/// The small parts the detail screens share.
struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case "pending": return .orange
        case "granted", "completed": return .green
        case "denied", "failed": return .red
        case "building", "proposed", "executing": return .blue
        default: return .secondary
        }
    }
}

/// A labelled value; hidden when there is nothing to show.
struct Field: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

/// Pretty-printed JSON in a scrolling monospace block; hidden when empty.
struct JSONBlock: View {
    let label: String
    let value: JSONValue?

    init(_ label: String, _ value: JSONValue?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(value.pretty)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// The comment that becomes the decision's rationale, on the record.
struct CommentField: View {
    @Binding var text: String

    var body: some View {
        TextField("Comment (kept as the rationale)", text: $text, axis: .vertical)
            .lineLimit(2...6)
    }
}
