import SwiftUI
import UIKit

/// Put the keyboard away from anywhere.
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// A tap on anything that is not a control dismisses the keyboard, and
/// every keyboard carries a Done button. The tab bar sits behind the
/// keyboard, so without both of these a field with focus is a dead end.
struct DismissesKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
            .toolbar {
                // Leading, not trailing: iOS 26 floats this over the content
                // above the keyboard, and the trailing edge is where the
                // Send button lives.
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { hideKeyboard() }
                    Spacer()
                }
            }
    }
}

extension View {
    func dismissesKeyboard() -> some View { modifier(DismissesKeyboard()) }
}
