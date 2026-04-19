import SwiftUI

struct TruncationBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.26), lineWidth: 1)
            )
    }
}

