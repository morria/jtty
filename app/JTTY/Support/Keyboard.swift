import SwiftUI
import UIKit

/// Put the keyboard away from anywhere.
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// A tap on anything that is not a control dismisses the keyboard, as it
/// does in Messages. The tab bar sits behind the keyboard, so without this
/// a field with focus is a dead end. (A keyboard Done button was tried and
/// dropped: iOS 26 floats it over the compose bar.)
struct DismissesKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
    }
}

extension View {
    func dismissesKeyboard() -> some View { modifier(DismissesKeyboard()) }
}

/// How much of the screen's bottom the keyboard covers, from the keyboard's
/// own frame. SwiftUI's keyboard avoidance has been seen leaving the
/// compose bar under the keyboard on the phone; the frame the system
/// reports is the one to trust.
@MainActor @Observable
final class KeyboardObserver {
    private(set) var overlap: CGFloat = 0
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.update(frame: frame, duration: duration) }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.update(frame: .zero, duration: duration) }
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func update(frame: CGRect, duration: Double) {
        let screen = UIScreen.main.bounds
        // A floating or split keyboard on the iPad covers nothing we can
        // usefully move out of the way.
        let docked = frame.width >= screen.width - 1 && frame.maxY >= screen.maxY - 1
        let overlap = docked ? max(0, screen.maxY - frame.minY) : 0
        withAnimation(.easeOut(duration: duration)) { self.overlap = overlap }
    }
}
