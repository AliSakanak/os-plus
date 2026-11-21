import SwiftUI

/// A button that asks "Sure?" inline before acting. Alerts are unreliable inside menu-bar popovers
/// (they can dismiss the popover), so the confirmation lives in the button itself and times out.
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    var symbol: String?
    let action: () -> Void
    @State private var armed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarmTask?.cancel()
                armed = false
                action()
            } else {
                armed = true
                disarmTask?.cancel()
                disarmTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { armed = false }
                }
            }
        } label: {
            if let symbol, !armed {
                Label(title, systemImage: symbol)
            } else {
                Text(armed ? confirmTitle : title)
            }
        }
        .foregroundStyle(armed ? Color.red : Color.primary)
        .animation(.easeOut(duration: 0.15), value: armed)
        .help(armed ? "Click again to confirm" : title)
    }
}
