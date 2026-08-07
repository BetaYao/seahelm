import SwiftUI

/// Rate-limit readout — "✦ 5h 11% 4h1m │ 7d 2% 6h1m". The label is bright,
/// the percentage carries the severity tint, and the reset countdown recedes.
struct UsageReadoutView: View {
    let logoName: String
    let segments: [UsageReadoutSegment]
    /// Compact drops the reset countdown — used where width is tight.
    var showsReset: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            // The vendor's own mark. Template-rendered, but tinted to the brand
            // rather than the island accent — at 11pt the logo is the only cue
            // for which provider a rotated window belongs to.
            Image(logoName)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
                .foregroundStyle(Self.brandColor(for: logoName))
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("│")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.18))
                }
                segmentView(segment)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func segmentView(_ segment: UsageReadoutSegment) -> some View {
        HStack(spacing: 4) {
            Text(segment.label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Text(segment.percentText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.color(for: segment.severity))
            if showsReset, let reset = segment.resetText {
                Text(reset)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    /// Claude's own orange; OpenAI's mark is monochrome and reads as near-white
    /// on the island's near-black surface.
    static func brandColor(for logoName: String) -> Color {
        logoName == "ClaudeLogo"
            ? Color(red: 0.85, green: 0.47, blue: 0.34)
            : Color.white.opacity(0.92)
    }

    static func color(for severity: UsageReadoutSegment.Severity) -> Color {
        switch severity {
        case .unknown: return .white.opacity(0.5)
        case .ok: return Color(red: 0.30, green: 0.85, blue: 0.39)
        case .warn: return Color(red: 0.98, green: 0.75, blue: 0.28)
        case .critical: return Color(red: 0.98, green: 0.38, blue: 0.35)
        }
    }
}
