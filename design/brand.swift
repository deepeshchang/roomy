// Regenerates every Roomy brand asset. Run from the repo root:  swift design/brand.swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(v >> 16 & 255)/255, CGFloat(v >> 8 & 255)/255, CGFloat(v & 255)/255, a])!
}

// Palette (mirrored in docs/brand/brand-notes.md and the .colorset files)
let coralTop: UInt32    = 0xFF7A59   // icon wash top
let coral: UInt32       = 0xF2603F   // icon wash bottom, photo hills/sun, LaunchBackground (light)
let coralSoft: UInt32   = 0xFF9C80   // far hill
let peach: UInt32       = 0xFFE3D6   // photo sky
let cream: UInt32       = 0xFFF8F2   // card + slabs
let accentLight: UInt32 = 0xBF4129   // AccentColor (light)
let accentDark: UInt32  = 0xFF8A6B   // AccentColor (dark)
let launchDark: UInt32  = 0x2A1510   // LaunchBackground (dark)

// The mark, drawn in a 1024 icon grid: one photo card (sun + mountains) above two
// thinner, fainter slabs — the same memories, squeezed. Extent x 202...822, y 236...802.
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
func fill(_ c: CGContext, _ p: CGPath, _ col: CGColor) { c.addPath(p); c.setFillColor(col); c.fillPath() }
func drawMark(_ c: CGContext, center: CGPoint, scale k: CGFloat) {
    c.saveGState()
    c.translateBy(x: center.x, y: center.y); c.scaleBy(x: k, y: k); c.translateBy(x: -512, y: -519)
    fill(c, rr(CGRect(x: 262, y: 236, width: 500, height: 44), 22), hex(cream, 0.45))
    fill(c, rr(CGRect(x: 232, y: 300, width: 560, height: 56), 28), hex(cream, 0.7))
    let card = CGRect(x: 202, y: 382, width: 620, height: 420)
    fill(c, rr(card, 64), hex(cream))
    let r = card.insetBy(dx: 44, dy: 44)
    c.addPath(rr(r, 30)); c.clip()
    fill(c, rr(r, 30), hex(peach))
    let sr = r.width * 0.11
    c.setFillColor(hex(coral)); c.fillEllipse(in: CGRect(x: r.maxX - r.width * 0.30 - sr, y: r.maxY - r.height * 0.30 - sr, width: sr * 2, height: sr * 2))
    let h2 = CGMutablePath()
    h2.move(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY)); h2.addLine(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.50))
    h2.addLine(to: CGPoint(x: r.maxX + 40, y: r.minY)); h2.closeSubpath(); fill(c, h2, hex(coralSoft))
    let h1 = CGMutablePath()
    h1.move(to: CGPoint(x: r.minX - 40, y: r.minY)); h1.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.62))
    h1.addLine(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY)); h1.closeSubpath(); fill(c, h1, hex(coral))
    c.restoreGState()
}

func canvas(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(d)); print("wrote \(path)")
}

func background(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [hex(coralTop), hex(coral)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
}

let A = "VideoCompressor/Assets.xcassets"

// App icon: opaque, square corners (iOS masks it).
do {
    let S: CGFloat = 1024, c = canvas(1024, 1024, opaque: true)
    background(c, S, S)
    drawMark(c, center: CGPoint(x: S/2, y: S/2), scale: 1)
    save(c, "\(A)/AppIcon.appiconset/icon-1024.png")
}

// Launch logo: 120pt canvas, mark (620 wide in the icon grid) fills it on clear.
for scale in [2, 3] {
    let px = 120 * scale, c = canvas(px, px, opaque: false)
    drawMark(c, center: CGPoint(x: px/2, y: px/2), scale: CGFloat(px) / 640)
    save(c, "\(A)/LaunchLogo.imageset/LaunchLogo@\(scale)x.png")
}

// GitHub social preview 1280x640.
do {
    let W: CGFloat = 1280, H: CGFloat = 640, c = canvas(1280, 640, opaque: true)
    background(c, W, H)
    drawMark(c, center: CGPoint(x: 330, y: H/2), scale: 0.62)
    func text(_ s: String, _ size: CGFloat, _ weight: CGFloat, _ alpha: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): hex(0xFFFFFF, alpha)])
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attr), c)
    }
    text("Roomy", 128, 0.4, 1, 580, 330)
    text("Free up your iPhone. Keep your memories.", 36, 0.0, 0.85, 588, 262)
    save(c, "docs/brand/social-preview.png")
}

// WCAG AA self-check: a palette edit that fails contrast stops the script.
func lum(_ v: UInt32) -> Double {
    let ch = [v >> 16 & 255, v >> 8 & 255, v & 255].map { x -> Double in
        let c = Double(x) / 255; return c <= 0.03928 ? c/12.92 : pow((c + 0.055)/1.055, 2.4) }
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
}
func ratio(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
let checks: [(UInt32, UInt32, String)] = [
    (accentLight, 0xFFFFFF, "accent on white"), (accentLight, 0xF2F2F7, "accent on grouped light"),
    (accentDark, 0x000000, "accent-dark on black"), (accentDark, 0x1C1C1E, "accent-dark on grouped dark"),
    (0xFFFFFF, accentLight, "white on accent button"), (0x000000, accentDark, "black on accent-dark button")]
for (fg, bg, name) in checks {
    let r = ratio(fg, bg); print(String(format: "%@ %.2f:1", name, r)); precondition(r >= 4.5, name)
}
