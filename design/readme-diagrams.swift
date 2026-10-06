// Hand-drawn README diagrams. Run from repo root: swift design/readme-diagrams.swift
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let out = "docs/images/"
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255)/255, green: CGFloat((h >> 8) & 255)/255, blue: CGFloat(h & 255)/255, alpha: a)
}
let coral = rgb(0xF2603F), accent = rgb(0xBF4129), cream = rgb(0xFFF8F2), ink = rgb(0x2B2B2B), grey = rgb(0x8A8580), green = rgb(0x2E9E5B)

var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) - 0.5 }

final class Pad {
    let W: CGFloat, H: CGFloat, ctx: CGContext
    init(_ w: CGFloat, _ h: CGFloat) {
        W = w; H = h
        ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
    }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: H - y) }  // top-left coords

    // Sketchy stroke: two jittered passes along a polyline.
    func line(_ pts: [CGPoint], _ c: CGColor = ink, _ w: CGFloat = 3, j: CGFloat = 2.2) {
        ctx.setStrokeColor(c); ctx.setLineWidth(w)
        for _ in 0..<2 {
            ctx.beginPath()
            for (i, a) in pts.enumerated() {
                let q = p(a.x + rnd()*j, a.y + rnd()*j)
                if i == 0 { ctx.move(to: q); continue }
                let b = pts[i-1], mid = p((a.x+b.x)/2 + rnd()*j*2, (a.y+b.y)/2 + rnd()*j*2)
                ctx.addQuadCurve(to: q, control: mid)
            }
            ctx.strokePath()
        }
    }
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor = ink, fill: CGColor? = nil, lw: CGFloat = 3) {
        if let f = fill { ctx.setFillColor(f); ctx.fill(CGRect(x: x+3, y: H-y-h+3, width: w-6, height: h-6)) }
        let o: CGFloat = 4
        line([CGPoint(x: x-o, y: y), CGPoint(x: x+w, y: y), CGPoint(x: x+w, y: y+h), CGPoint(x: x, y: y+h), CGPoint(x: x, y: y-o)], c, lw)
    }
    func hatch(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor, gap: CGFloat = 12) {
        ctx.saveGState(); ctx.clip(to: CGRect(x: x, y: H-y-h, width: w, height: h))
        var s = -h; while s < w { line([CGPoint(x: x+s, y: y+h), CGPoint(x: x+s+h, y: y)], c, 2, j: 1.5); s += gap }
        ctx.restoreGState()
    }
    func arrow(_ a: CGPoint, _ b: CGPoint, _ c: CGColor = ink, curve: CGFloat = 20) {
        let m = CGPoint(x: (a.x+b.x)/2 - (b.y-a.y)/200*curve, y: (a.y+b.y)/2 + (b.x-a.x)/200*curve)
        line([a, m, b], c, 3.5)
        let ang = atan2(b.y - m.y, b.x - m.x), L: CGFloat = 18
        line([CGPoint(x: b.x - L*cos(ang-0.45), y: b.y - L*sin(ang-0.45)), b, CGPoint(x: b.x - L*cos(ang+0.45), y: b.y - L*sin(ang+0.45))], c, 3.5)
    }
    func cross(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat = 22) {
        line([CGPoint(x: x-s, y: y-s), CGPoint(x: x+s, y: y+s)], accent, 5)
        line([CGPoint(x: x+s, y: y-s), CGPoint(x: x-s, y: y+s)], accent, 5)
    }
    func check(_ x: CGFloat, _ y: CGFloat) {
        line([CGPoint(x: x-14, y: y), CGPoint(x: x-3, y: y+12), CGPoint(x: x+18, y: y-16)], green, 5)
    }
    // Text: y = baseline (top-left coords). Emoji fall back to Apple Color Emoji via CoreText cascade.
    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: CGColor = ink, font: String = "Chalkboard SE", bold: Bool = false, center: Bool = false) -> CGFloat {
        let f = CTFontCreateWithName((bold ? font + " Bold" : font) as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): c])
        let ln = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(ln, nil, nil, nil))
        ctx.textPosition = CGPoint(x: center ? x - w/2 : x, y: H - y)
        CTLineDraw(ln, ctx)
        return w
    }
    func underline(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) { line([CGPoint(x: x, y: y), CGPoint(x: x+w*0.5, y: y+3), CGPoint(x: x+w, y: y-2)], coral, 6) }
    func save(_ name: String) {
        let url = URL(fileURLWithPath: out + name) as CFURL
        let d = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        print("wrote", out + name)
    }
}

// 1. Problem
do {
    let d = Pad(1600, 900)
    let tw = d.text("The storage horror", 800, 110, 64, bold: true, center: true)
    d.underline(800 - tw/2, 128, tw)
    d.text("one 2 TB family iCloud plan, five people…", 800, 180, 30, grey, center: true)
    // bar
    let bx: CGFloat = 120, by: CGFloat = 230, bw: CGFloat = 1360, bh: CGFloat = 110
    let me = bw * 0.5
    d.box(bx, by, me, bh, accent, fill: rgb(0xF2603F, 0.85), lw: 4)
    let others: [(String, CGFloat, UInt32)] = [("🧑", 0.14, 0xFFD9CC), ("👩", 0.12, 0xFFE8DF), ("👦", 0.08, 0xFFF1EA), ("👧", 0.06, 0xFFF8F2)]
    var x = bx + me
    for (_, f, col) in others { d.box(x, by, bw*f, bh, ink, fill: rgb(col)); x += bw*f }
    d.hatch(x, by, bx + bw - x, bh, rgb(0xCCCCCC)); d.box(x, by, bx + bw - x, bh, grey)
    d.text("~1 TB  — just me", bx + me/2, by + 70, 40, rgb(0xFFFFFF), bold: true, center: true)
    d.text("2 TB", bx + bw + 8, by + bh + 40, 26, grey, center: true)
    // people
    d.text("😱", bx + me/2, by + bh + 105, 72, center: true)
    d.text("that's me", bx + me/2, by + bh + 150, 28, accent, bold: true, center: true)
    x = bx + me
    for (e, f, _) in others { d.text(e, x + bw*f/2, by + bh + 80, 44, center: true); x += bw*f }
    d.text("everyone else 😬", bx + me + bw*0.2, by + bh + 135, 26, grey, center: true)
    d.text("free", x + (bx + bw - x)/2, by + 68, 26, grey, center: true)
    // suggestions
    let sy: CGFloat = 610
    d.text("Apple's suggestions:", 120, sy, 34, bold: true)
    let tips = [("🗑️", "delete big videos", "they're memories!"), ("⚙️", "optimise storage", "still counts in iCloud"),
                ("👯", "merge duplicates", "barely moves it"), ("🧹", "empty trash", "a few GB, tops")]
    for (i, t) in tips.enumerated() {
        let cx = 120 + CGFloat(i) * 345, cy = sy + 40
        d.box(cx, cy, 315, 170, grey, lw: 2.5)
        d.text(t.0, cx + 157, cy + 70, 48, center: true)
        d.text(t.1, cx + 157, cy + 115, 28, center: true)
        d.text(t.2, cx + 157, cy + 152, 22, grey, center: true)
        d.cross(cx + 285, cy + 30)
        d.line([CGPoint(x: cx + 40, y: cy + 106), CGPoint(x: cx + 275, y: cy + 104)], rgb(0xBF4129, 0.7), 3)
    }
    d.save("problem.png")
}

// 2. How it works
do {
    let d = Pad(1600, 1100)
    let tw = d.text("How Roomy frees up space", 800, 105, 62, bold: true, center: true)
    d.underline(800 - tw/2, 123, tw)
    d.text("everything happens on your iPhone — nothing is uploaded", 800, 172, 28, grey, center: true)
    let steps: [(String, String, [String])] = [
        ("📱", "1. Find the big ones", ["library sorted", "biggest-first"]),
        ("✅", "2. Pick", ["Top 20 in one tap", "or drag-select"]),
        ("🗜️", "3. Compress on device", ["video → HEVC", "photo → HEIC"]),
        ("💾", "4. Save a copy", ["same 📅 date  📍 place", "same 🗂️ albums"]),
        ("🗑️", "5. Delete originals", ["only when YOU confirm", "⏳ 30-day safety net"]),
        ("🎉", "6. Celebrate", ["", ""]),
    ]
    let bw: CGFloat = 400, bh: CGFloat = 300, gx: CGFloat = 110
    let x0 = (1600 - (3*bw + 2*gx)) / 2
    func pos(_ i: Int) -> CGPoint {   // snake: row 1 left→right, row 2 right→left
        let r = i / 3, c = r == 0 ? i % 3 : 2 - i % 3
        return CGPoint(x: x0 + CGFloat(c)*(bw+gx), y: 230 + CGFloat(r)*(bh+120))
    }
    for (i, s) in steps.enumerated() {
        let o = pos(i), last = i == steps.count - 1
        d.box(o.x, o.y, bw, bh, last ? accent : ink, fill: last ? rgb(0xF2603F, 0.12) : cream, lw: last ? 4 : 3)
        d.text(s.0, o.x + bw/2, o.y + 105, 72, center: true)
        d.text(s.1, o.x + bw/2, o.y + 165, 32, last ? accent : ink, bold: true, center: true)
        if last {
            d.text("“Saved 23 GB”", o.x + bw/2, o.y + 230, 44, accent, bold: true, center: true)
            d.text("(example)", o.x + bw/2, o.y + 268, 20, grey, center: true)
        } else {
            d.text(s.2[0], o.x + bw/2, o.y + 215, 26, i == 4 ? accent : ink, center: true)
            d.text(s.2[1], o.x + bw/2, o.y + 255, 26, i == 4 ? accent : grey, center: true)
        }
    }
    for i in 0..<5 {
        let a = pos(i), b = pos(i+1)
        if i == 2 { d.arrow(CGPoint(x: a.x + bw/2, y: a.y + bh + 12), CGPoint(x: b.x + bw/2, y: b.y - 14), coral, curve: 0) }
        else if i < 2 { d.arrow(CGPoint(x: a.x + bw + 12, y: a.y + bh/2), CGPoint(x: b.x - 14, y: b.y + bh/2), coral) }
        else { d.arrow(CGPoint(x: a.x - 12, y: a.y + bh/2), CGPoint(x: b.x + bw + 14, y: b.y + bh/2), coral) }
    }
    d.save("how-it-works.png")
}

// 3. Before / after
do {
    let d = Pad(1600, 900)
    let tw = d.text("Same memory. A quarter of the space.", 800, 105, 56, bold: true, center: true)
    d.underline(800 - tw/2, 123, tw)
    func card(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat, _ label: String, _ size: String, _ c: CGColor, _ fill: CGColor) {
        let y: CGFloat = 640 - h
        d.box(x, y, w, h, c, fill: fill, lw: 4)
        d.text("💍", x + w/2, y + h/2 + 10, h > 300 ? 120 : 70, center: true)
        d.text("▶︎ 3:12  🔊", x + w/2, y + h - 22, 24, grey, center: true)
        d.text(label, x + w/2, y - 78, 28, grey, center: true)
        d.text(size, x + w/2, y - 18, 52, c, bold: true, center: true)
    }
    card(150, 520, 400, "wedding video — before", "1.8 GB", ink, rgb(0xF4F1EE))
    card(1050, 260, 200, "after (HEVC)", "~450 MB", accent, rgb(0xF2603F, 0.15))
    d.arrow(CGPoint(x: 710, y: 450), CGPoint(x: 1010, y: 470), coral, curve: 12)
    d.text("🗜️ squeezed on your phone", 855, 440, 26, accent, center: true)
    d.text("✓ same length   ✓ same sound   ✓ same date & place", 800, 720, 32, center: true)
    d.text("❤️ your memories stay — they just take up less room", 800, 790, 34, accent, bold: true, center: true)
    d.text("example numbers — real savings depend on the video", 800, 850, 22, grey, center: true)
    d.save("before-after.png")
}

// 4. Safety
do {
    let d = Pad(1600, 900)
    let tw = d.text("Never lose a memory", 800, 105, 64, bold: true, center: true)
    d.underline(800 - tw/2, 123, tw)
    let items: [(String, String, String)] = [
        ("🔒", "Originals are only read", "never edited in place"),
        ("✅", "Copy saved & confirmed first", "before anything is deleted"),
        ("📏", "Never makes a file bigger", "no saving → no copy"),
        ("🧯", "Cancel = nothing half-written", "stop any time, safely"),
        ("☁️🚫", "Nothing is uploaded", "no servers, no account"),
        ("⏳", "30 days in Recently Deleted", "change your mind? undo it"),
    ]
    for (i, it) in items.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let x = 110 + col * 720, y = 190 + row * 220
        d.box(x, y, 660, 180, ink, fill: cream, lw: 2.5)
        d.box(x + 30, y + 30, 44, 44, ink, lw: 3)
        d.check(x + 52, y + 54)
        d.text(it.0, x + 110, y + 75, 46)
        d.text(it.1, x + 30, y + 125, 32, bold: true)
        d.text(it.2, x + 30, y + 162, 24, grey)
    }
    d.save("safety.png")
}
