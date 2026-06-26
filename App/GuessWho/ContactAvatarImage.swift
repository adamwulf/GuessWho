import UIKit
import GuessWhoSync

enum ContactAvatarImage {
    static func placeholder(for contact: Contact, diameter: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format)
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            backgroundColor(for: contact).setFill()
            context.cgContext.fillEllipse(in: rect)

            let initials = contact.initials
            guard !initials.isEmpty else { return }

            let font = UIFont.systemFont(ofSize: max(11, diameter * 0.42), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let size = initials.size(withAttributes: attributes)
            let origin = CGPoint(
                x: (diameter - size.width) / 2,
                y: (diameter - size.height) / 2
            )
            initials.draw(at: origin, withAttributes: attributes)
        }
    }

    private static func backgroundColor(for contact: Contact) -> UIColor {
        let seed = "\(contact.contactType)-\(contact.displayName)"
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        let palette: [UIColor] = [
            .systemBlue,
            .systemGreen,
            .systemIndigo,
            .systemOrange,
            .systemPink,
            .systemPurple,
            .systemRed,
            .systemTeal,
        ]
        return palette[abs(value) % palette.count]
    }
}
