import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR codes, drawn locally.
///
/// Nothing here talks to a service: a QR generator that round-trips the payload
/// through someone's API would publish the pairing link it is meant to keep
/// between this Mac and its owner's phone. CoreImage has shipped the encoder
/// since 10.9.
enum QRCodeRenderer {
    /// A QR for `string`, sized to `points` and drawn in `foreground` on
    /// `background`.
    ///
    /// The generator emits one pixel per module, so the image is scaled up by a
    /// whole number with interpolation switched off — anything else feathers the
    /// module edges, and a blurry QR is a QR a phone gives up on.
    static func image(for string: String,
                      points: CGFloat,
                      foreground: NSColor = .black,
                      background: NSColor = .white) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium recovers ~15% of the symbol. The link is short, so the extra
        // modules cost nothing, and a screen photographed at an angle needs it.
        filter.correctionLevel = "M"
        guard let coreImage = filter.outputImage else { return nil }

        let moduleCount = max(coreImage.extent.width, 1)
        // Round up so the whole code always fills the requested box, then let
        // the NSImage size do the final (still integral-module) scaling.
        let scale = max(1, (points / moduleCount).rounded(.up))
        let scaled = coreImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let source = NSImage(size: rep.size)
        source.addRepresentation(rep)

        // The generator's output is black-on-transparent. Tinting through
        // CIFalseColor would work, but drawing it as a mask keeps the colors as
        // resolved `NSColor`s, so a theme change repaints correctly.
        let output = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            background.setFill()
            rect.fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            foreground.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        return output
    }
}

/// An `NSImageView` that re-renders its QR when the appearance flips.
///
/// A QR needs real contrast in both themes and cannot simply be tinted: the
/// quiet zone and the light modules are part of the symbol, so the background
/// has to be painted too. Keeping the payload here and redrawing on
/// `viewDidChangeEffectiveAppearance` is the only way the code stays scannable
/// after a switch to dark mode.
final class QRCodeView: NSImageView {
    var payload: String = "" {
        didSet { redraw() }
    }
    /// Side length in points. The view is square and pins itself to it.
    var side: CGFloat = 180 {
        didSet {
            sideConstraints.forEach { $0.constant = side }
            redraw()
        }
    }

    private var sideConstraints: [NSLayoutConstraint] = []

    init(side: CGFloat = 180) {
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        sideConstraints = [
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ]
        NSLayoutConstraint.activate(sideConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    private func redraw() {
        guard !payload.isEmpty else {
            image = nil
            return
        }
        // Resolve against this view's appearance, not the app's: a sheet can
        // carry its own.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Not pure black/white — a paper-white card in a dark sheet is a
            // flashbulb, and phones scan a soft contrast pair perfectly well.
            let dark = self.effectiveAppearance.isDark
            self.image = QRCodeRenderer.image(
                for: self.payload,
                points: self.side * (self.window?.backingScaleFactor ?? 2),
                foreground: dark ? NSColor(white: 0.06, alpha: 1) : NSColor(white: 0.08, alpha: 1),
                background: dark ? NSColor(white: 0.88, alpha: 1) : .white)
        }
    }
}
