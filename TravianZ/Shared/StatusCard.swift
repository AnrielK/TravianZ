import SwiftUI

struct StatusCard<Actions: View>: View {
    let icon: String
    let text: String
    let spinner: Bool
    @ViewBuilder var actions: () -> Actions

    init(icon: String, text: String, spinner: Bool, @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.text = text
        self.spinner = spinner
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            if spinner {
                ProgressView()
            } else {
                Image(systemName: icon).font(.largeTitle)
            }
            Text(text).multilineTextAlignment(.center)
            actions()
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(32)
    }
}

extension StatusCard where Actions == EmptyView {
    init(icon: String, text: String, spinner: Bool) {
        self.init(icon: icon, text: text, spinner: spinner) { EmptyView() }
    }
}
