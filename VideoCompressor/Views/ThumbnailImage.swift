import SwiftUI

/// Square, aspect-fill, corner-rounded thumbnail. Shows a placeholder until
/// the image arrives; an iCloud-only asset keeps the placeholder forever,
/// which is deliberate — thumbnails never download.
///
/// Loading lives in `.task(id:)`, so SwiftUI cancels it when the row scrolls
/// away or is reused, and no cancellation bookkeeping is needed here.
struct ThumbnailImage: View {
    let assetID: String?
    let fileURL: URL?
    let side: CGFloat

    @State private var image: UIImage?

    init(assetID: String?, fileURL: URL? = nil, side: CGFloat) {
        self.assetID = assetID
        self.fileURL = fileURL
        self.side = side
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: side * 0.3))
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: assetID ?? fileURL?.path ?? "") {
            guard image == nil else { return }
            if let assetID {
                image = await Thumbnails.image(for: assetID, size: side)
            } else if let fileURL {
                image = await Thumbnails.image(for: fileURL, size: side)
            }
        }
        .accessibilityHidden(true)
    }
}
