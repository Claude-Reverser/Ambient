import SwiftUI

enum AmbientTheme {
    static let accent = Color(red: 0.65, green: 0.46, blue: 1.0)
    static let lavender = Color(red: 0.79, green: 0.69, blue: 1.0)
    static let background = Color(red: 0.045, green: 0.037, blue: 0.07)
    static let surface = Color(red: 0.083, green: 0.068, blue: 0.12)
    static let border = Color.white.opacity(0.075)
}
struct VioletButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 17).padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [AmbientTheme.accent, Color(red: 0.44, green: 0.29, blue: 0.83)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(
            .secondary)
    }
}
struct DetailBadge: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(
            .white.opacity(0.8)
        ).padding(.horizontal, 10).padding(.vertical, 6).background(
            .black.opacity(0.32), in: Capsule()
        ).overlay(Capsule().stroke(.white.opacity(0.13)))
    }
}
