import SwiftUI
import UIKit
import GuessWhoSync

struct ContactPhotoCropEditor: View {
    let image: UIImage
    let initialCrop: ContactPhotoCrop?
    let onChoose: (ContactPhotoCrop) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var crop: ContactPhotoCrop?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack {
                PhotoCropViewport(image: image, initialCrop: initialCrop) { crop = $0 }
                Text("Move and scale")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .background(.black)
            .navigationTitle("Crop Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        guard let crop else { return }
                        saving = true
                        Task {
                            do {
                                try await onChoose(crop)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                                saving = false
                            }
                        }
                    }
                    .disabled(crop == nil || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert("Couldn't Save Photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct PhotoCropViewport: UIViewRepresentable {
    let image: UIImage
    let initialCrop: ContactPhotoCrop?
    let onChange: (ContactPhotoCrop) -> Void

    func makeUIView(context: Context) -> CropView {
        CropView(image: image, crop: initialCrop, onChange: onChange)
    }

    func updateUIView(_ view: CropView, context: Context) {}

    final class CropView: UIView, UIScrollViewDelegate {
        private let scroll = UIScrollView()
        private let imageView: UIImageView
        private let scrim = CAShapeLayer()
        private let border = CAShapeLayer()
        private let onChange: (ContactPhotoCrop) -> Void
        private var crop: ContactPhotoCrop?
        private var laidOutSize = CGSize.zero
        private var layingOut = false

        init(image: UIImage, crop: ContactPhotoCrop?, onChange: @escaping (ContactPhotoCrop) -> Void) {
            self.imageView = UIImageView(image: image)
            self.crop = crop
            self.onChange = onChange
            super.init(frame: .zero)
            clipsToBounds = true
            scroll.delegate = self
            scroll.clipsToBounds = false
            scroll.bounces = false
            scroll.bouncesZoom = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.showsVerticalScrollIndicator = false
            scroll.contentInsetAdjustmentBehavior = .never
            imageView.frame = CGRect(origin: .zero, size: image.size)
            scroll.addSubview(imageView)
            addSubview(scroll)
            scrim.fillRule = .evenOdd
            scrim.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
            layer.addSublayer(scrim)
            border.fillColor = UIColor.clear.cgColor
            border.strokeColor = UIColor.white.cgColor
            border.lineWidth = 1
            layer.addSublayer(border)
            scroll.isAccessibilityElement = true
            scroll.accessibilityLabel = "Photo crop"
            scroll.accessibilityHint = "Drag to move. Pinch to zoom."
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != laidOutSize, bounds.width > 48, bounds.height > 48,
                  let image = imageView.image else { return }
            layingOut = true
            laidOutSize = bounds.size
            let side = min(bounds.width - 48, bounds.height - 48, 420)
            scroll.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            let minimum = side / min(image.size.width, image.size.height)
            let selected = crop ?? ContactPhotoCrop.square(imageSize: image.size)
            scroll.minimumZoomScale = minimum
            scroll.maximumZoomScale = max(minimum * 12, side / (CGFloat(selected?.width ?? 1) * image.size.width))
            scroll.zoomScale = max(minimum, side / (CGFloat(selected?.width ?? 1) * image.size.width))
            scroll.contentSize = CGSize(width: image.size.width * scroll.zoomScale, height: image.size.height * scroll.zoomScale)
            scroll.contentOffset = CGPoint(x: CGFloat(selected?.x ?? 0) * scroll.contentSize.width,
                                           y: CGFloat(selected?.y ?? 0) * scroll.contentSize.height)
            let mask = UIBezierPath(rect: bounds)
            mask.append(UIBezierPath(ovalIn: scroll.frame))
            scrim.path = mask.cgPath
            border.path = UIBezierPath(ovalIn: scroll.frame).cgPath
            layingOut = false
            publishCrop()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { publishCrop() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { publishCrop() }

        private func publishCrop() {
            guard !layingOut, let image = imageView.image, scroll.bounds.width > 0 else { return }
            let center = CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width,
                                 y: (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height)
            let zoom = min(image.size.width, image.size.height) * scroll.zoomScale / scroll.bounds.width
            guard let selected = ContactPhotoCrop.square(imageSize: image.size, zoom: Double(zoom), center: center) else { return }
            crop = selected
            // layoutSubviews can run during SwiftUI updates.
            DispatchQueue.main.async { [onChange] in onChange(selected) }
        }
    }
}
