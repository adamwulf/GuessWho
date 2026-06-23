import SwiftUI

/// Cross-platform abstraction over iOS's `UIKeyboardType`. The macOS
/// build has no `keyboardType(_:)` modifier — the View extension below
/// just returns `self` there. iOS forwards to the matching
/// `UIKeyboardType` case.
enum PlatformKeyboardType {
    case `default`, phonePad, emailAddress, URL
}

extension View {
    @ViewBuilder
    func applyKeyboard(_ type: PlatformKeyboardType) -> some View {
        #if targetEnvironment(macCatalyst)
        self
        #else
        switch type {
        case .default: self
        case .phonePad: self.keyboardType(.phonePad)
        case .emailAddress: self.keyboardType(.emailAddress)
        case .URL: self.keyboardType(.URL)
        }
        #endif
    }
}
