import SwiftUI

// MARK: - ProgressRing

struct ProgressRing: View {
    var progress: Double     // 0...1
    var size: CGFloat = 96
    var lineWidth: CGFloat = 6
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(progress, 1)))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: size * 0.22, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                if let label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(Palette.mutedText)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - HabitRow

/// Round check used for habits everywhere on Today.
struct CheckCircle: View {
    let isOn: Bool
    var tint: Color = Palette.accent
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? tint : Color.primary.opacity(0.22), lineWidth: 1.5)
            if isOn {
                Circle().fill(tint)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
    }
}

struct HabitRow: View {
    let name: String
    let iconName: String
    let isCompleted: Bool
    var isScheduled: Bool = true
    var detail: String? = nil
    var dotColor: Color? = nil
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                CheckCircle(isOn: isCompleted)

                if let dotColor {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.mutedText)
                        .frame(width: 18)
                }

                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(isCompleted || !isScheduled ? Palette.mutedText : .primary)
                    .strikethrough(isCompleted, color: Palette.mutedText.opacity(0.6))

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mutedText)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .background(hovering ? Palette.subtleFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isScheduled)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isCompleted)
    }
}

// MARK: - ScheduleRow

struct ScheduleRow: View {
    let title: String
    let startTime: Date
    let endTime: Date
    let category: String
    var isCurrent: Bool = false
    var accentColor: Color? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.timeFormatter.string(from: startTime))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text(Self.timeFormatter.string(from: endTime))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.mutedText)
            }
            .frame(width: 48, alignment: .trailing)

            Rectangle()
                .fill(accentColor ?? (isCurrent ? Palette.accent : Palette.hairline))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(isCurrent ? .medium : .regular)
                Text(category)
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - StatCard

struct StatCard: View {
    let label: String
    let value: String
    var sublabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.lowercased())
                .font(.mono(11, .semibold))
                .italic()
                .foregroundStyle(Palette.accent)
            Text(value)
                .font(.mono(26, .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let sublabel {
                Text(sublabel)
                    .font(.caption)
                    .foregroundStyle(Palette.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineCard()
    }
}

// MARK: - EmptyState

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var fillsSpace: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.accent)
                .frame(width: 64, height: 64)
                .background(Palette.callout, in: Circle())
            Text(title).font(.mono(16, .bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
    }
}

// MARK: - LinearBar

/// Thin rounded progress bar (0…1).
struct LinearBar: View {
    var value: Double
    var height: CGFloat = 4
    var tint: Color = Palette.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.subtleFill)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: value)
    }
}
