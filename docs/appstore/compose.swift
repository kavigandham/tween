import AppKit
import Foundation

// Composes App Store screenshots at exact 6.9" size (1320 x 2868) from a real
// simulator capture plus a headline. No third-party tooling — AppKit is already
// on the machine, unlike PIL/ImageMagick.

let W: CGFloat = 1320, H: CGFloat = 2868

struct Slide {
    let file: String, title: String, sub: String, out: String
    let top: NSColor, bottom: NSColor
}

func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

let slides: [Slide] = [
    .init(file: "HARNESS_PROPOSAL_DRAFT.png",
          title: "It lives in your chat",
          sub: "Your friend doesn't need the app",
          out: "01-chat.png", top: c(10, 37, 64), bottom: c(6, 16, 28)),
    .init(file: "HARNESS_MEETUP.png",
          title: "Fair means fair",
          sub: "Everyone's travel time, side by side",
          out: "02-fair.png", top: c(12, 42, 58), bottom: c(6, 16, 28)),
    .init(file: "spotcard.png",
          title: "Search like Maps",
          sub: "Coffee, food, gas — or by name",
          out: "03-search.png", top: c(18, 35, 58), bottom: c(6, 16, 28)),
]

func render(_ s: Slide) {
    guard let shot = NSImage(contentsOfFile: s.file) else {
        print("MISSING \(s.file)"); return
    }
    let image = NSImage(size: NSSize(width: W, height: H))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // Background gradient
    let grad = NSGradient(colors: [s.top, s.bottom])!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -75)

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
    title.draw(with: NSRect(x: 80, y: H - 150 - titleH, width: W - 160, height: titleH),
               options: .usesLineFragmentOrigin)

    let subStyle = NSMutableParagraphStyle()
    subStyle.alignment = .center
    let sub = NSAttributedString(string: s.sub, attributes: [
        .font: NSFont.systemFont(ofSize: 50, weight: .medium),
        .foregroundColor: c(143, 180, 217),
        .paragraphStyle: subStyle,
    ])
    let subH = sub.boundingRect(with: NSSize(width: W - 160, height: 200),
                                options: .usesLineFragmentOrigin).height
    let subTop = H - 150 - titleH - 34
    sub.draw(with: NSRect(x: 80, y: subTop - subH, width: W - 160, height: subH),
             options: .usesLineFragmentOrigin)

    // Device shot, rounded, centred under the copy
    let shotW: CGFloat = 880
    let ratio = shot.size.height / shot.size.width
    let shotH = shotW * ratio
    let shotX = (W - shotW) / 2
    let shotY = subTop - subH - 110 - shotH
    let rect = NSRect(x: shotX, y: shotY, width: shotW, height: shotH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40), blur: 90,
                  color: NSColor.black.withAlphaComponent(0.55).cgColor)
    let path = NSBezierPath(roundedRect: rect, xRadius: 60, yRadius: 60)
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

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: s.out))
    print("wrote \(s.out)")
}

slides.forEach(render)
