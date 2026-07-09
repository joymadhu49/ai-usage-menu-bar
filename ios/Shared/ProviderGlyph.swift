import SwiftUI

// Provider icon: an SF Symbol by name, or the bundled official Grok logo
// (asset "GrokLogo", template) for the sentinel "grok".
struct ProviderGlyph: View {
    let icon: String
    var size: CGFloat = 12

    var body: some View {
        if icon == "grok" {
            Image("GrokLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
        }
    }
}
