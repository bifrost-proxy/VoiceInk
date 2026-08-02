import SwiftUI

struct ModelOfficialSourceLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text("Official link")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(.secondaryLabelColor))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .accessibilityLabel(Text("Official link"))
    }
}
