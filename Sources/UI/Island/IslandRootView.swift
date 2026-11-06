import SwiftUI

/// Root of the island: a single black NotchShape container that morphs
/// between the closed pill and the opened surface by animating its real
/// frame and corner radii (ping-island style) — no raster scaling, no blur.
/// The hosting window never resizes — all morphing happens here.
struct IslandRootView: View {
    @Bindable var model: IslandModel
    @State private var hoveringPill = false

    private static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    /// Critically damped: closing snaps shut with no wobble.
    private static let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)
    private static let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)

    private static let openedRadii = (top: CGFloat(10), bottom: CGFloat(22))
    private static let closedRadii = (top: CGFloat(5), bottom: CGFloat(14))

    var body: some View {
        VStack(spacing: 0) {
            headerBand
            if model.isOpened {
                OpenedSurfaceView(model: model)
                    .background(
                        // The click-outside test and the hit test read this
                        // height. Through a preference it stuck at the first
                        // layout (163 pt) while the island grew to ~700, so every
                        // click on its lower part counted as outside: the island
                        // shut on "更多" or text, and a card's tap never fired.
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { model.measuredOpenedHeight = Self.openedHeight(geo.size.height, notch: model.notchHeight) }
                                .onChange(of: geo.size.height) { _, height in
                                    model.measuredOpenedHeight = Self.openedHeight(height, notch: model.notchHeight)
                                }
                        }
                    )
                    // Container owns the shape morph; content just settles in
                    // (and gets out of the way faster than it arrived).
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
        .frame(width: containerWidth)
        .background(currentShape.fill(IslandStyle.background))
        .overlay(
            currentShape.stroke(
                IslandStyle.accent.opacity(model.isOpened ? 0.16 : 0),
                lineWidth: 1
            )
        )
        .clipShape(currentShape)
        .shadow(
            color: .black.opacity(model.isOpened || hoveringPill ? 0.5 : 0),
            radius: 9, y: 5
        )
        .scaleEffect(pillScale, anchor: .top)
        .animation(transitionAnimation, value: model.state)
        .onHover { inside in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                hoveringPill = inside
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.isOpened) { _, opened in
            if !opened { model.measuredOpenedHeight = 0 }
        }
    }

    /// Notch-height band that is always present: wings while closed, clear
    /// spacer under the hardware notch while opened.
    private var headerBand: some View {
        ZStack {
            if !model.isOpened {
                ClosedPillView(model: model)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .frame(width: containerWidth, height: model.notchHeight)
    }

    private var containerWidth: CGFloat {
        model.isOpened ? model.openedWidth : model.closedWidth
    }

    private var currentShape: NotchShape {
        NotchShape(
            topRadius: model.isOpened ? Self.openedRadii.top : Self.closedRadii.top,
            bottomRadius: model.isOpened ? Self.openedRadii.bottom : Self.closedRadii.bottom
        )
    }

    private var pillScale: CGFloat {
        guard !model.isOpened else { return 1.0 }
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

extension IslandRootView {
    /// Full opened height for hit testing: the header band plus the surface.
    static func openedHeight(_ surface: CGFloat, notch: CGFloat) -> CGFloat {
        surface > 0 ? surface + notch : 0
    }
}
