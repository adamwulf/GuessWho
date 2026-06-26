import SwiftUI
import UIKit

/// Identifiable box around a `UIImage` so it can drive `.fullScreenCover(item:)`
/// (UIImage isn't Identifiable). A fresh `id` per box guarantees the cover
/// re-presents even if the same image instance is tapped twice.
struct FullscreenPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Fullscreen, zoomable/pannable presentation of a contact's photo. Shown as a
/// `.fullScreenCover` from the detail header when the user taps the photo. The
/// zoom/pan/double-tap mechanics live in a `UIScrollView` (via
/// `ZoomableImageView`) rather than SwiftUI gestures: the scroll view gives us
/// momentum, rubber-band bounce, centered insets, and double-tap-to-zoom for
/// free, and behaves identically on iPhone/iPad and Mac Catalyst.
struct ContactPhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            ZoomableImageView(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
            .accessibilityLabel("Close")
        }
    }
}

/// A `UIScrollView` that hosts a single `UIImageView` and supports
/// pinch-to-zoom, pan, and double-tap-to-zoom. The image is laid out to fit the
/// view at minimum zoom and kept centered via content insets at every zoom
/// level.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    func makeUIView(context: Context) -> UIScrollView {
        // A LayoutNotifyingScrollView so the fit-scale + centering math runs on
        // every real layout pass (`layoutSubviews`), where the bounds are
        // settled. Driving it from `updateUIView` instead is wrong: SwiftUI
        // calls `updateUIView` before the scroll view has its final bounds, so
        // the centering computation would bail on a zero/placeholder size and
        // the image would pin to the top-left corner.
        let scrollView = LayoutNotifyingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutDidChange()
        }

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // The image is fixed for the lifetime of the cover, so there is nothing
        // to re-bind. Layout (zoom scales + centering) is driven from the scroll
        // view's own `layoutSubviews` via `onLayout`, not from here.
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView: UIImageView
        weak var scrollView: UIScrollView?
        private var lastLayoutSize: CGSize = .zero

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        /// Recompute the fit-to-view minimum zoom whenever the scroll view's
        /// bounds change (rotation, split-view resize, Catalyst window resize).
        /// Preserves the "fully zoomed out" state across a resize but leaves a
        /// user-chosen zoom untouched.
        func layoutDidChange() {
            guard let scrollView, scrollView.bounds.size != lastLayoutSize else { return }
            let wasMinimumZoom =
                lastLayoutSize == .zero
                || abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
            lastLayoutSize = scrollView.bounds.size

            let imageSize = imageView.image?.size ?? scrollView.bounds.size
            imageView.frame = CGRect(origin: .zero, size: imageSize)
            scrollView.contentSize = imageSize

            let boundsSize = scrollView.bounds.size
            guard imageSize.width > 0, imageSize.height > 0,
                  boundsSize.width > 0, boundsSize.height > 0 else { return }

            let widthScale = boundsSize.width / imageSize.width
            let heightScale = boundsSize.height / imageSize.height
            let minScale = min(widthScale, heightScale)

            scrollView.minimumZoomScale = minScale
            // Allow zooming in to 3x past fit, but never below the image's native
            // resolution feeling cramped — cap the max so huge photos still get a
            // meaningful zoom range.
            scrollView.maximumZoomScale = max(minScale * 4, 1)

            if wasMinimumZoom {
                scrollView.zoomScale = minScale
            }
            centerImage(in: scrollView)
        }

        /// Keep the image centered when it is smaller than the viewport by
        /// padding the scroll view's content insets symmetrically.
        private func centerImage(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize
            let horizontalInset = max(0, (boundsSize.width - contentSize.width) / 2)
            let verticalInset = max(0, (boundsSize.height - contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                // Already zoomed in — zoom back out to fit.
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // Zoom in toward the tapped point.
                let targetScale = min(scrollView.minimumZoomScale * 3, scrollView.maximumZoomScale)
                let point = gesture.location(in: imageView)
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                let rect = CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// A `UIScrollView` that invokes `onLayout` on every layout pass. The zoom
/// scales and centering depend on the scroll view's final bounds, which are
/// only known inside `layoutSubviews` — not when SwiftUI calls `updateUIView`.
/// Driving the layout from here keeps the image fit-to-screen and centered on
/// first present and across every later bounds change (rotation, resize).
private final class LayoutNotifyingScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
