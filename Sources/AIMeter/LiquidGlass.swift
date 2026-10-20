import SwiftUI
import AppKit

// MARK: - Native Visual Effect View (Dynamic Wallpaper Blur)
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Liquid Glass Background Style
struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 1. ネイティブ動的すりガラス（壁紙や背後ウィンドウを滑らかに屈折・透過）
            VisualEffectBlur(
                material: .hudWindow,
                blendingMode: .behindWindow,
                state: .active
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // 2. 環境光シアーティント（コントラスト確保と深みのある光沢）
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.45), location: 0.0),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.02) : Color.white.opacity(0.18), location: 0.4),
                            .init(color: colorScheme == .dark ? Color.black.opacity(0.16) : Color.black.opacity(0.03), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 3. 上部スペキュラ・サーフェスグレア（ガラス上面の環境光反射）
            VStack {
                LinearGradient(
                    colors: [
                        colorScheme == .dark ? Color.white.opacity(0.15) : Color.white.opacity(0.40),
                        colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                Spacer()
            }

            // 4. 精密なスペキュラ・エッジ境界線（1px 屈折ハイライト）
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.50) : Color.white.opacity(0.85), location: 0.0),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.20) : Color.white.opacity(0.45), location: 0.35),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.20), location: 0.70),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.40), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        }
    }
}

// MARK: - Layered Frosted Glass Background (For Provider Sections)
struct FrostedGlassCardBackground: View {
    var cornerRadius: CGFloat = 9
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.045)
                        : Color.white.opacity(0.35)
                )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.55), location: 0.0),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.18), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
    }
}

// MARK: - Glass Morphic Button Style
struct GlassCapsuleButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(configuration.isPressed ? 0.30 : 0.20)
                                : (colorScheme == .dark
                                    ? Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)
                                    : Color.white.opacity(configuration.isPressed ? 0.55 : 0.38))
                        )

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: isSelected
                                        ? Color.accentColor.opacity(0.65)
                                        : (colorScheme == .dark ? Color.white.opacity(0.32) : Color.white.opacity(0.65)), location: 0.0),
                                    .init(color: isSelected
                                        ? Color.accentColor.opacity(0.20)
                                        : (colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.22)), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                }
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
