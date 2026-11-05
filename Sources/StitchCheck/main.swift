// Offline check of the scrolling-capture stitcher: builds a synthetic tall "page", cuts it
// into overlapping viewport frames (with a sticky header, a footer and a moving overlay
// scrollbar, like a real browser), stitches them back and compares with the original.
import CoreGraphics
import Foundation
import Stitch

struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

func makePage(width: Int, height: Int, seed: UInt64) -> CGImage {
    let ctx = Stitcher.context(width, height, CGColorSpace(name: CGColorSpace.sRGB))!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var r = LCG(s: seed)
    var y = 20
    while y < height - 40 {
        let kind = r.next() % 10
        if kind == 0 {   // blank gap
            y += 60 + Int(r.next() % 120)
            continue
        }
        if kind == 1 {   // colored block (image)
            let h = 80 + Int(r.next() % 200)
            ctx.setFillColor(CGColor(red: CGFloat(r.next() % 255) / 255, green: CGFloat(r.next() % 255) / 255, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 40, y: height - y - h, width: width / 2, height: h))
            y += h + 16
            continue
        }
        // a "text line": words of random width
        var x = 40
        while x < width - 120 {
            let w = 20 + Int(r.next() % 90)
            ctx.setFillColor(CGColor(gray: CGFloat(r.next() % 80) / 255, alpha: 1))
            ctx.fill(CGRect(x: x, y: height - y - 18, width: w, height: 18))
            x += w + 10
        }
        y += 30
    }
    return ctx.makeImage()!
}

/// One viewport frame: header + page[offset ..< offset+body] + footer, plus a scrollbar thumb.
var sidebar = 0   // width of a static panel on the left (another window / fixed sidebar)

func makeFrame(page: CGImage, offset: Int, viewH: Int, header: Int, footer: Int) -> CGImage {
    let w = page.width, body = viewH - header - footer
    let ctx = Stitcher.context(w, viewH, page.colorSpace)!
    // page slice (CG origin is bottom-left)
    let slice = page.cropping(to: CGRect(x: 0, y: offset, width: w, height: body))!
    ctx.draw(slice, in: CGRect(x: 0, y: footer, width: w, height: body))
    if header > 0 {
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: viewH - header, width: w, height: header))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 30, y: viewH - header + 20, width: 200, height: 20))
    }
    if footer > 0 {
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: footer))
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 10, width: 300, height: min(14, footer)))
    }
    if sidebar > 0 {   // static panel with its own "text"
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: sidebar, height: viewH))
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        var yy = 20; while yy < viewH - 30 { ctx.fill(CGRect(x: 20, y: yy, width: sidebar / 2 + (yy * 7) % (sidebar / 3), height: 14)); yy += 26 }
    }
    // overlay scrollbar thumb, position depends on offset
    let track = body - 80
    let range = max(1, page.height - body)
    let thumbY = footer + body - 80 - Int(Double(track) * Double(offset) / Double(range))
    ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
    ctx.fill(CGRect(x: w - 14, y: thumbY, width: 8, height: 80))
    return ctx.makeImage()!
}

func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    buf.withUnsafeMutableBytes { b in
        let ctx = CGContext(data: b.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return buf
}

func run(name: String, pageH: Int, viewH: Int, header: Int, footer: Int, steps: [Int], seed: UInt64) -> Bool {
    let width = 1200
    let page = makePage(width: width, height: pageH, seed: seed)
    let body = viewH - header - footer
    let st = Stitcher(maxHeight: 100_000)
    var offset = 0
    var lastOffset = 0
    let t0 = Date()
    _ = st.add(makeFrame(page: page, offset: 0, viewH: viewH, header: header, footer: footer), requestedShift: 0)
    var i = 0
    while true {
        let req = steps[i % steps.count]; i += 1
        offset = min(offset + req, pageH - body)
        let r = st.add(makeFrame(page: page, offset: offset, viewH: viewH, header: header, footer: footer), requestedShift: req)
        if r == .noChange { break }
        if r == .failed { print("  \(name): FAILED at offset \(offset)"); return false }
        if case .appended(let s) = r, s != offset - lastOffset {
            print("  \(name): wrong shift \(s), expected \(offset - lastOffset)"); return false
        }
        lastOffset = offset
    }
    let dt = Date().timeIntervalSince(t0)
    guard let out = st.compose() else { print("  \(name): compose failed"); return false }
    // Expected: header + whole page + footer
    let expected = makeFrame(page: page, offset: 0, viewH: header + pageH + footer, header: header, footer: footer)
    // makeFrame with viewH = full height draws the whole page; scrollbar differs, so ignore right 20 px
    guard out.width == expected.width, out.height == expected.height else {
        print("  \(name): size \(out.width)x\(out.height), expected \(expected.width)x\(expected.height)"); return false
    }
    let a = pixels(out), b = pixels(expected)
    var bad = 0
    for y in 0..<out.height {
        for x in 0..<(out.width - 20) {
            let o = (y * out.width + x) * 4
            if a[o] != b[o] || a[o + 1] != b[o + 1] || a[o + 2] != b[o + 2] { bad += 1 }
        }
    }
    let ok = bad == 0
    print("  \(name): \(ok ? "OK" : "MISMATCH \(bad) px") — \(out.width)x\(out.height), \(i + 1) frames, \(String(format: "%.0f", dt * 1000)) ms")
    return ok
}

func runSidebar() -> Bool {
    // The expected image can't be built the same way (the panel repeats), so only check shifts and size.
    sidebar = 520
    defer { sidebar = 0 }
    let page = makePage(width: 1200, height: 6000, seed: 9)
    let st = Stitcher(maxHeight: 100_000)
    var off = 0
    _ = st.add(makeFrame(page: page, offset: 0, viewH: 1300, header: 0, footer: 0), requestedShift: 0)
    while true {
        let prevOff = off
        off = min(off + 600, 6000 - 1300)
        let r = st.add(makeFrame(page: page, offset: off, viewH: 1300, header: 0, footer: 0), requestedShift: 600)
        if r == .noChange { break }
        guard case .appended(let s) = r, s == off - prevOff else { print("  static sidebar: FAILED (\(r)) at \(off)"); return false }
    }
    let ok = st.height == 6000
    print("  static sidebar: \(ok ? "OK" : "height \(st.height)") — 520 px static panel beside scrolling content")
    return ok
}

var allOK = true
allOK = runSidebar() && allOK
allOK = run(name: "browser-like", pageH: 9000, viewH: 1400, header: 120, footer: 60, steps: [700], seed: 1) && allOK
allOK = run(name: "no header", pageH: 5000, viewH: 1000, header: 0, footer: 0, steps: [500, 430, 610], seed: 2) && allOK
allOK = run(name: "big steps", pageH: 7000, viewH: 1600, header: 80, footer: 0, steps: [1200], seed: 3) && allOK
allOK = run(name: "retina tall", pageH: 14000, viewH: 2200, header: 140, footer: 90, steps: [1000], seed: 4) && allOK
print(allOK ? "ALL OK" : "SOME FAILED")
exit(allOK ? 0 : 1)
