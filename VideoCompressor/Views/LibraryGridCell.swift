import SwiftUI

/// One square of the Library mosaic (spec §1.3). Pure display: the parent
/// owns selection and handles the tap.
struct LibraryGridCell: View {
    let assetID: String
    /// Duration (`0:42`) for video, megapixels (`12 MP`) for photos.
    let leadingText: String
    let bytes: Int64
    let badges: [Badge]
    let isSelected: Bool
    let accessibilityText: String
    /// ≥ 1 GB or top 10% of its type: the size sits in an accent badge (v2 §2.6).
    var isLarge = false

    enum Badge: Hashable {
        case symbol(String)
        case text(String)
    }

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            // ThumbnailImage rounds its own corners (8pt) and is
            // frozen, so it is drawn 16pt oversize and clipped square here to
            // get the 0-radius mosaic (V7). Drop this once it takes a radius.
            ThumbnailImage(assetID: assetID, side: side + 16)
                .frame(width: side, height: side)
                .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .background(Color(.secondarySystemFill))
        .overlay {
            LinearGradient(colors: [.clear, .black.opacity(contrast == .increased ? 0.7 : 0.55)],
                           startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            HStack {
                // Size first: it is what the grid is sorted by.
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(isLarge ? .footnote.bold() : .footnote.weight(.semibold))
                    .padding(.horizontal, isLarge ? 6 : 0).padding(.vertical, isLarge ? 2 : 0)
                    .background {
                        if isLarge { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) }
                    }
                Spacer(minLength: 4)
                Text(leadingText).opacity(0.85)
            }
            .onThumbnailText()
            .padding(6)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                ForEach(badges.prefix(2), id: \.self) { badge in
                    Group {
                        switch badge {
                        case .symbol(let name): Image(systemName: name)
                        case .text(let text): Text(text)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.4)))
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(6)
        }
        .overlay {
            if isSelected {
                ZStack {
                    Color.black.opacity(0.18)
                    Rectangle().strokeBorder(Color.accentColor,
                                             lineWidth: contrast == .increased ? 4 : 3)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : .white.opacity(0.9))
                .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
                .contentTransition(.symbolEffect(.replace))
                .padding(8)
        }
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLarge ? accessibilityText + ", large" : accessibilityText)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(isSelected ? "Double-tap to deselect" : "Double-tap to select")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(assetID)
    }
}

private extension View {
    func onThumbnailText() -> some View {
        font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}
