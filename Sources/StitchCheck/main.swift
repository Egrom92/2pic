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
    let body = viewH - header - footer
    let slice = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: body))!
    return makeFrame(slice: slice, pageH: page.height, offset: offset, viewH: viewH, header: header, footer: footer)
}

/// Same, from an already cut (and possibly altered) slice of the page.
func makeFrame(slice: CGImage, pageH: Int, offset: Int, viewH: Int, header: Int, footer: Int) -> CGImage {
    let w = slice.width, body = viewH - header - footer
    let ctx = Stitcher.context(w, viewH, slice.colorSpace)!
    // page slice (CG origin is bottom-left)
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
    let range = max(1, pageH - body)
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

func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage {
    var p = px
    return p.withUnsafeMutableBytes { b in
        CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }
}

/// A page whose content changes while it is being captured, like real sites and apps do:
/// - `lazy`: whatever first shows up in the bottom 30 % of the viewport is a light-grey skeleton
///   (lazy images, virtualized lists) and is "loaded" once it has moved higher;
/// - `video`: these page rows show different noise in every frame (a video, a carousel, an animation).
/// The capture must not stop, must find the right shifts, and must end with the loaded content.
/// `actual`: how far the app really scrolls on each step, if not `step` (smooth scrolling cut short, acceleration).
/// `mayStop`: stopping is acceptable here; gluing at a wrong offset never is.
func runDynamic(name: String, pageH: Int, viewH: Int, header: Int, footer: Int, step: Int, seed: UInt64,
                lazy: Bool, video: Range<Int>?, actual: [Int]? = nil, mayStop: Bool = false) -> Bool {
    let width = 1200, row = width * 4
    let page = makePage(width: width, height: pageH, seed: seed)
    let pagePx = pixels(page)
    var skelPx = pagePx
    if lazy {
        for i in stride(from: 0, to: skelPx.count, by: 4) {
            let l = (Int(skelPx[i]) + Int(skelPx[i + 1]) + Int(skelPx[i + 2])) / 3
            let v: UInt8 = l < 250 ? 226 : 255
            skelPx[i] = v; skelPx[i + 1] = v; skelPx[i + 2] = v
        }
    }
    let body = viewH - header - footer
    var loadedUpTo = 0, frameNo = 0
    func frame(_ offset: Int) -> CGImage {
        frameNo += 1
        var px = Array(pagePx[(offset * row)..<((offset + body) * row)])
        if lazy {
            let edge = offset + body * 7 / 10
            let from = max(loadedUpTo, edge), to = offset + body
            if from < to {
                px.replaceSubrange(((from - offset) * row)..<((to - offset) * row), with: skelPx[(from * row)..<(to * row)])
            }
            loadedUpTo = max(loadedUpTo, edge)
        }
        if let v = video, max(v.lowerBound, offset) < min(v.upperBound, offset + body) {
            var r = LCG(s: UInt64(frameNo) &* 7919 &+ 17)
            for y in max(v.lowerBound, offset)..<min(v.upperBound, offset + body) {
                let o = (y - offset) * row
                for x in stride(from: 40, to: width - 60, by: 4) {
                    let g = UInt8(r.next() % 256)
                    for d in 0..<4 { px[o + (x + d) * 4] = g; px[o + (x + d) * 4 + 1] = g; px[o + (x + d) * 4 + 2] = g }
                }
            }
        }
        return makeFrame(slice: image(px, width, body), pageH: pageH, offset: offset, viewH: viewH, header: header, footer: footer)
    }

    let st = Stitcher(maxHeight: 100_000)
    var offset = 0, last = 0, frames = 1
    _ = st.add(frame(0), requestedShift: 0)
    while frames < 100 {
        offset = min(offset + (actual.map { $0[(frames - 1) % $0.count] } ?? step), pageH - body)
        let r = st.add(frame(offset), requestedShift: step)
        frames += 1
        if r == .noChange { break }
        if r == .failed && mayStop {
            print("  \(name): OK — stopped safely at offset \(offset) of \(pageH - body), no wrong seam before it")
            return true
        }
        if r == .failed {
            print("  \(name): FAILED at offset \(offset) of \(pageH - body) — \(st.lastProbe.map { "\($0)" } ?? "")")
            return false
        }
        if case .appended(let s) = r, s != offset - last {
            print("  \(name): wrong shift \(s), expected \(offset - last)"); return false
        }
        last = offset
    }
    guard let out = st.compose() else { print("  \(name): compose failed"); return false }
    let expected = makeFrame(page: page, offset: 0, viewH: header + pageH + footer, header: header, footer: footer)
    guard out.width == expected.width, out.height == expected.height else {
        print("  \(name): size \(out.width)x\(out.height), expected \(expected.width)x\(expected.height)"); return false
    }
    // The last viewport may keep its skeleton (nothing came after it); video rows differ by design.
    let checkH = lazy ? header + pageH - body : out.height
    let skip = video.map { (header + $0.lowerBound)..<(header + $0.upperBound) } ?? 0..<0
    let a = pixels(out), b = pixels(expected)
    var bad = 0
    for y in 0..<checkH where !skip.contains(y) {
        for x in 0..<(out.width - 20) {
            let o = (y * out.width + x) * 4
            if a[o] != b[o] || a[o + 1] != b[o + 1] || a[o + 2] != b[o + 2] { bad += 1 }
        }
    }
    print("  \(name): \(bad == 0 ? "OK" : "MISMATCH \(bad) px") — \(frames) frames")
    return bad == 0
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
// Content that changes during the capture (what made real captures stop early).
allOK = runDynamic(name: "lazy loading", pageH: 9000, viewH: 1400, header: 120, footer: 60, step: 610, seed: 5,
                   lazy: true, video: nil) && allOK
allOK = runDynamic(name: "video mid-page", pageH: 7000, viewH: 1400, header: 120, footer: 60, step: 610, seed: 6,
                   lazy: false, video: 3000..<3280) && allOK
allOK = runDynamic(name: "video at the end", pageH: 5000, viewH: 1400, header: 120, footer: 60, step: 610, seed: 7,
                   lazy: false, video: 4500..<4780) && allOK
allOK = runDynamic(name: "video + uneven scrolling", pageH: 7000, viewH: 1400, header: 120, footer: 60, step: 610,
                   seed: 8, lazy: false, video: 2600..<2880, actual: [610, 520, 640, 610, 470], mayStop: true) && allOK
print(allOK ? "ALL OK" : "SOME FAILED")
exit(allOK ? 0 : 1)
