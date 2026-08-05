import AppKit
import Foundation

// Composes App Store promotional slides at exactly 6.9" size (1320 x 2868)
// from real simulator captures plus a headline. No third-party tooling —
// AppKit is already on the machine, unlike PIL/ImageMagick.
//
// Renders into an explicit NSBitmapImageRep sized in PIXELS. The previous
// version used `image.lockFocus()`, which picks up the Mac's backing scale —
// on a Retina display that silently produced 2640 x 5736 and needed a `sips`
// downscale afterwards, which softened every glyph. This draws once, at the
// exact size the App Store wants.

let W: CGFloat = 1320, H: CGFloat = 2868

struct Slide {
    let file: String, title: String, sub: String, out: String
    let top: NSColor, bottom: NSColor
}

func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

// Deep, slightly different blues per slide so the set reads as one family
// without looking mechanically identical in the App Store's filmstrip.
let slides: [Slide] = [
    .init(file: "screenshots/01-fair-spots-in-chat.png",
          title: "It lives in your chat",
          sub: "Your friend doesn't need the app",
          out: "promo/01-chat.png", top: c(10, 42, 78), bottom: c(5, 14, 26)),
    .init(file: "screenshots/02-everyones-drive-time.png",
          title: "Fair means fair",
          sub: "Everyone's drive time, side by side",
          out: "promo/02-fair.png", top: c(12, 50, 70), bottom: c(5, 14, 26)),
    .init(file: "screenshots/03-agreed-open-in-maps.png",
          title: "Agree in one tap",
          sub: "Then open it right in Maps",
          out: "promo/03-agree.png", top: c(14, 46, 60), bottom: c(5, 14, 26)),
    .init(file: "screenshots/04-search-like-maps.png",
          title: "Search like Maps",
          sub: "Coffee, food, gas — or by name",
          out: "promo/04-search.png", top: c(20, 40, 76), bottom: c(5, 14, 26)),
]

func render(_ s: Slide) {
    guard let shot = NSImage(contentsOfFile: s.file) else {
        print("MISSING \(s.file)"); return
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { print("no bitmap for \(s.out)"); return }
    // Pixels, not points — otherwise text is laid out for a 2x canvas.
    rep.size = NSSize(width: W, height: H)

    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    // Background gradient
    NSGradient(colors: [s.top, s.bottom])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -75)

    // Headline
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    titleStyle.lineHeightMultiple = 0.95
    let title = NSAttributedString(string: s.title, attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -2.5,
        .paragraphStyle: titleStyle,
    ])
    // AppKit origin is bottom-left; lay the text out from the top.
    let titleH = title.boundingRect(with: NSSize(width: W - 160, height: 400),
                                    options: .usesLineFragmentOrigin).height
    title.draw(with: NSRect(x: 80, y: H - 170 - titleH, width: W - 160, height: titleH),
               options: .usesLineFragmentOrigin)

    let subStyle = NSMutableParagraphStyle()
    subStyle.alignment = .center
    let sub = NSAttributedString(string: s.sub, attributes: [
        .font: NSFont.systemFont(ofSize: 50, weight: .medium),
        .foregroundColor: c(150, 186, 222),
        .paragraphStyle: subStyle,
    ])
    let subH = sub.boundingRect(with: NSSize(width: W - 160, height: 200),
                                options: .usesLineFragmentOrigin).height
    let subTop = H - 170 - titleH - 34
    sub.draw(with: NSRect(x: 80, y: subTop - subH, width: W - 160, height: subH),
             options: .usesLineFragmentOrigin)

    // Device shot, rounded, centred under the copy
    let shotW: CGFloat = 900
    let ratio = shot.size.height / shot.size.width
    let shotH = shotW * ratio
    let rect = NSRect(x: (W - shotW) / 2, y: subTop - subH - 120 - shotH,
                      width: shotW, height: shotH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40), blur: 90,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    let path = NSBezierPath(roundedRect: rect, xRadius: 62, yRadius: 62)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    shot.draw(in: rect)
    ctx.restoreGState()

    // Hairline bezel
    c(255, 255, 255).withAlphaComponent(0.10).setStroke()
    path.lineWidth = 10
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: s.out).deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try? png.write(to: URL(fileURLWithPath: s.out))
    print("wrote \(s.out)  \(rep.pixelsWide) x \(rep.pixelsHigh)")
}

slides.forEach(render)
