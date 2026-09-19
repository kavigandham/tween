import AppKit
import Foundation

// Composes App Store slides at exactly 6.9" size (1320 x 2868) from native
// simulator captures plus a headline. AppKit only — nothing to install.
//
// Two things made the previous set look soft, and both are fixed here:
//
//  1. **A redundant downscale.** This renders at exactly 1320 x 2868, but the
//     README still told you to `sips -z 2778 1284` afterwards. Resampling a
//     finished 1320-wide composition down to 1284 softened every glyph in the
//     set for no reason. There is no post-step now: what this writes is what
//     you upload.
//  2. **The phone was too small to read.** The device shot was drawn 900px
//     wide inside a 1320px frame — a 0.68x downscale of the UI on top of a
//     third of the canvas spent on empty gradient. It's 1120 now, the copy
//     block is tighter, and the screen content is legible at filmstrip size.
//
// Captures come from `-SHOT <scene>` (TweenApp/ShotHarness.swift), which
// renders one surface edge to edge with a believable seed. See ../README.md.

let W: CGFloat = 1320, H: CGFloat = 2868

struct Slide {
    let file: String, title: String, sub: String, out: String
    let top: NSColor, bottom: NSColor
    /// Fraction of the capture's HEIGHT to trim off the top before drawing.
    ///
    /// Every Tween surface is a big map with the panel that carries the actual
    /// message underneath it. Drawn whole, the panel lands in the bottom third
    /// of the slide and is unreadable at the size the App Store shows a
    /// filmstrip — which is most of why the old set said nothing. Trimming
    /// map (there's plenty left to establish place) pushes the words up into
    /// the part of the frame people actually look at.
    var cropTop: CGFloat = 0
}

func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

// Every headline describes something VISIBLE in its own capture. The old set
// promised "It lives in your chat" over a generic browse list and "Agree in
// one tap" over a screen with no agree button on it.
let slides: [Slide] = [
    .init(file: "raw/fair.png",
          title: "Fair means fair",
          sub: "Ranked by everyone's drive time — not distance",
          out: "promo/01-fair.png", top: c(10, 42, 78), bottom: c(5, 14, 26),
          cropTop: 0.20),
    .init(file: "raw/vote.png",
          title: "Can't agree? Vote.",
          sub: "Everyone's pick on the board, side by side",
          out: "promo/02-vote.png", top: c(12, 50, 70), bottom: c(5, 14, 26),
          cropTop: 0.26),
    .init(file: "raw/plan.png",
          title: "Then tell them you left",
          sub: "One tap sends your real ETA to the chat",
          out: "promo/03-plan.png", top: c(14, 46, 60), bottom: c(5, 14, 26),
          cropTop: 0.22),
    .init(file: "screenshots/04-search-like-maps.png",
          title: "Search like Maps",
          sub: "Coffee, food, gas — or anywhere by name",
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
    // Full-quality resampling on the one downscale that remains (native
    // capture → device shot). The default is fine for photos and mushy for
    // 11pt UI type.
    ctx.interpolationQuality = .high

    NSGradient(colors: [s.top, s.bottom])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -75)

    // Headline
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    titleStyle.lineHeightMultiple = 0.95
    let title = NSAttributedString(string: s.title, attributes: [
        .font: NSFont.systemFont(ofSize: 96, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -2.5,
        .paragraphStyle: titleStyle,
    ])
    let titleH = title.boundingRect(with: NSSize(width: W - 140, height: 400),
                                    options: .usesLineFragmentOrigin).height
    title.draw(with: NSRect(x: 70, y: H - 120 - titleH, width: W - 140, height: titleH),
               options: .usesLineFragmentOrigin)

    let subStyle = NSMutableParagraphStyle()
    subStyle.alignment = .center
    let sub = NSAttributedString(string: s.sub, attributes: [
        .font: NSFont.systemFont(ofSize: 44, weight: .medium),
        .foregroundColor: c(150, 186, 222),
        .paragraphStyle: subStyle,
    ])
    let subH = sub.boundingRect(with: NSSize(width: W - 140, height: 200),
                                options: .usesLineFragmentOrigin).height
    let subTop = H - 120 - titleH - 26
    sub.draw(with: NSRect(x: 70, y: subTop - subH, width: W - 140, height: subH),
             options: .usesLineFragmentOrigin)

    // Device shot — as big as the canvas allows. Bleeding off the bottom edge
    // is deliberate: a whole phone floating in a gradient wastes the half of
    // the frame the App Store actually shows in a filmstrip.
    // Source rect in the capture, minus the trimmed map. AppKit's origin is
    // bottom-left, so "trim the top" means shrinking the height and leaving y
    // at 0.
    let src = NSRect(x: 0, y: 0,
                     width: shot.size.width,
                     height: shot.size.height * (1 - s.cropTop))
    let ratio = src.height / src.width

    // FILL the space under the copy rather than centring a fixed-width phone
    // in it: a cropped capture is shorter, and a fixed width left a third of
    // the canvas as empty gradient. Grow to the available height, bleed off
    // the bottom edge, and clamp the width so a barely-cropped capture can't
    // run past the side margins.
    let topOfShot = subTop - subH - 80
    let bleed: CGFloat = 70
    var shotH = topOfShot + bleed
    var shotW = shotH / ratio
    let maxW: CGFloat = 1180
    if shotW > maxW {
        shotW = maxW
        shotH = shotW * ratio
    }
    // Centre what's left in the band under the copy. Top-anchoring it dumped
    // every spare pixel below the phone, which read as a cropped screenshot
    // sitting in a void rather than a composed slide.
    let rect = NSRect(x: (W - shotW) / 2,
                      y: max((topOfShot - shotH) / 2, -bleed),
                      width: shotW, height: shotH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40), blur: 90,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    let path = NSBezierPath(roundedRect: rect, xRadius: 74, yRadius: 74)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    shot.draw(in: rect, from: src, operation: .sourceOver, fraction: 1)
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
