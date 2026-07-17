import SwiftUI

/// Root of the island: closed pill and opened surface are two co-located
/// surfaces in a ZStack cross-faded under a single state-keyed animation.
/// The hosting window never resizes — all morphing happens here.
struct IslandRootView: View {
    @Bindable var model: IslandModel
    @State private var openedMounted = false
    @State private var hoveringPill = false

    private static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    private static let closeAnimation = Animation.smooth(duration: 0.3)
    private static let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)
    /// Keep the opened surface mounted briefly after close so it can fade out.
    private static let openedUnmountDelay: TimeInterval = 0.36

    var body: some View {
        ZStack(alignment: .top) {
            // The pill "grows into" the surface: it scales up and fades as
            // the surface expands, instead of a flat cross-fade in place.
            ClosedPillView(model: model)
                .scaleEffect(model.isOpened ? 1.35 : pillScale, anchor: .top)
                .opacity(model.isOpened ? 0 : 1)
                .blur(radius: model.isOpened ? 6 : 0)
                .onHover { inside in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        hoveringPill = inside
                    }
                }

            if openedMounted {
                OpenedSurfaceView(model: model)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: OpenedHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .opacity(model.isOpened ? 1 : 0)
                    // Emerge from the notch: slight upward offset + scale so
                    // the surface reads as unfolding out of the pill.
                    .scaleEffect(x: model.isOpened ? 1 : 0.62, y: model.isOpened ? 1 : 0.3, anchor: .top)
                    .allowsHitTesting(model.isOpened)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(transitionAnimation, value: model.state)
        .onPreferenceChange(OpenedHeightKey.self) { height in
            model.measuredOpenedHeight = height
        }
        .onChange(of: model.state) { _, newState in
            if newState == .opened {
                openedMounted = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.openedUnmountDelay) {
                    if !model.isOpened { openedMounted = false }
                }
            }
        }
    }

    private var pillScale: CGFloat {
        if model.state == .popping { return 1.04 }
        if hoveringPill && model.state == .closed { return 1.03 }
        return 1.0
    }

    private var transitionAnimation: Animation {
        switch model.state {
        case .opened: return Self.openAnimation
        case .popping: return Self.popAnimation
        case .closed: return Self.closeAnimation
        }
    }
}

private struct OpenedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
