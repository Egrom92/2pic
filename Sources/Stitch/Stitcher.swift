import CoreGraphics
import Foundation

/// Per-row fingerprint of a frame: each row is split into vertical bands, and every band gets
/// a hash plus a flag saying whether it has any detail (a plain background band says nothing
/// about the scroll offset). Bands make the matching tolerant of a scrollbar or a blinking
/// caret that changes a small part of a row.
public struct FrameSignature {
    public static let bands = 16
    public let width: Int
    public let height: Int
    var hash: [UInt64]     // height * bands
    var info: [UInt8]      // 1 if the band has detail
    var rowInfo: [Int32]   // number of detailed bands per row

    public init(_ image: CGImage) {
        width = image.width
        height = image.height
        let n = Self.bands
        let w = max(n, image.width / 2)   // half horizontal resolution is plenty
        let h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var hash = [UInt64](repeating: 0, count: h * n)
        var info = [UInt8](repeating: 0, count: h * n)
        var rowInfo = [Int32](repeating: 0, count: h)
        let bw = w / n
        gray.withUnsafeBufferPointer { g in
            for y in 0..<h {
                let row = y * w
                var cnt: Int32 = 0
                for k in 0..<n {
                    let x0 = k * bw, x1 = (k == n - 1) ? w : x0 + bw
                    var hv: UInt64 = 0xcbf29ce484222325
                    var lo: UInt8 = 255, hi: UInt8 = 0
                    for x in x0..<x1 {
                        let v = g[row + x]
                        hv = (hv ^ UInt64(v)) &* 0x100000001b3
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                    }
                    hash[y * n + k] = hv
                    if hi &- lo >= 6 { info[y * n + k] = 1; cnt += 1 }
                }
                rowInfo[y] = cnt
            }
        }
        self.hash = hash
        self.info = info
        self.rowInfo = rowInfo
    }
}

public struct StitchMatch {
    /// How many pixel rows the content moved up between the two frames (0 = nothing moved).
    public let shift: Int
    /// Rows at the top / bottom that stayed in place (sticky header, footer, window chrome).
    public let header: Int
    public let footer: Int
    public let score: Double
}

public enum StitchMatcher {
    /// Finds how far the content scrolled from `a` to `b`. `expected` is the scroll we asked for,
    /// in pixels; it breaks ties for repetitive content. Returns nil if no offset fits.
    public static func match(_ a: FrameSignature, _ b: FrameSignature, expected: Int) -> StitchMatch? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let h = a.height, n = FrameSignature.bands

        // Columns (bands) that did not move at all — another window or a fixed sidebar inside the
        // region — say nothing about the scroll offset, so they are left out of the matching.
        var active = [Bool](repeating: false, count: n)
        for k in 0..<n {
            var detailed = 0, same = 0
            for y in 0..<h where a.info[y * n + k] != 0 || b.info[y * n + k] != 0 {
                detailed += 1
                if a.hash[y * n + k] == b.hash[y * n + k] { same += 1 }
            }
            active[k] = detailed > 0 && Double(same) < Double(detailed) * 0.85
        }
        let activeCount = active.filter { $0 }.count
        if activeCount == 0 { return StitchMatch(shift: 0, header: h, footer: 0, score: 1) }

        let staticNeed = max(1, activeCount * 9 / 10)
        func equalBands(_ y: Int) -> Int {
            var c = 0
            let o = y * n
            for k in 0..<n where active[k] && a.hash[o + k] == b.hash[o + k] { c += 1 }
            return c
        }
        var top = 0
        while top < h && equalBands(top) >= staticNeed { top += 1 }
        if top == h { return StitchMatch(shift: 0, header: h, footer: 0, score: 1) }
        var bottom = 0
        while bottom < h - top && equalBands(h - 1 - bottom) >= staticNeed { bottom += 1 }
        let cap = h * 45 / 100
        let T = min(top, cap), F = min(bottom, cap)
        let body = h - T - F
        guard body > 24 else { return nil }
        let minOverlap = max(12, body / 10)
        let maxShift = body - minOverlap
        guard maxShift >= 1 else { return nil }

        // Detailed active bands of b, per row, and their prefix sums.
        var mask = [UInt8](repeating: 0, count: h * n)
        var pre = [Int](repeating: 0, count: h + 1)
        for y in 0..<h {
            var c = 0
            for k in 0..<n where active[k] && b.info[y * n + k] != 0 { mask[y * n + k] = 1; c += 1 }
            pre[y + 1] = pre[y] + c
        }

        let exp = min(max(expected, 1), maxShift)
        var order: [Int] = [exp]
        order.reserveCapacity(maxShift)
        var d = 1
        while order.count < maxShift {
            if exp - d >= 1 { order.append(exp - d) }
            if exp + d <= maxShift { order.append(exp + d) }
            d += 1
        }

        // Pick the offset with the best match ratio, discounted for thin evidence (a few rows of a
        // tiny overlap can match by chance). `order` runs outward from the expected offset, so on
        // equal scores the one closest to the requested scroll wins.
        var best = -1.0, bestShift = 0, bestRaw = 0.0
        var anyInformative = false
        let minTotal = max(24, activeCount * 4)
        a.hash.withUnsafeBufferPointer { ah in
        b.hash.withUnsafeBufferPointer { bh in
        mask.withUnsafeBufferPointer { bm in
            for s in order {
                let y0 = T, y1 = h - F - s
                guard y1 > y0 else { continue }
                let total = pre[y1] - pre[y0]
                if total < minTotal { continue }
                anyInformative = true
                let penalty = 1.5 / Double(total).squareRoot()
                let allowedMiss = Int(Double(total) * (1 - max(best + penalty, 0.7)))
                guard allowedMiss >= 0 else { continue }
                var miss = 0
                var ok = true
                rows: for y in y0..<y1 where pre[y + 1] != pre[y] {
                    let bo = y * n, ao = (y + s) * n
                    for k in 0..<n where bm[bo + k] != 0 && ah[ao + k] != bh[bo + k] {
                        miss += 1
                        if miss > allowedMiss { ok = false; break rows }
                    }
                }
                if !ok { continue }
                let raw = 1 - Double(miss) / Double(total)
                if raw - penalty > best + 1e-9 { best = raw - penalty; bestShift = s; bestRaw = raw }
            }
        }}}
        if !anyInformative {
            // Only plain background in the overlap: trust the scroll we requested.
            return StitchMatch(shift: exp, header: T, footer: F, score: 0)
        }
        guard bestRaw >= 0.7 else { return nil }
        return StitchMatch(shift: bestShift, header: T, footer: F, score: bestRaw)
    }
}

/// Glues frames of a scrolling region into one tall image.
public final class Stitcher {
    public enum Step: Equatable { case first, appended(Int), noChange, failed, full }

    public let maxHeight: Int
    public private(set) var height = 0
    public private(set) var lastMatch: StitchMatch?
    /// Result of the latest comparison, including "nothing moved" (nil = no offset fitted).
    public private(set) var lastRaw: StitchMatch?
    private var segments: [CGImage] = []
    private var prev: FrameSignature?
    private var ratio = 1.0   // measured shift / requested shift

    public init(maxHeight: Int = 16000) { self.maxHeight = maxHeight }

    public var isFull: Bool { height >= maxHeight }

    /// Height of the part that actually scrolls (frame minus sticky header/footer), in pixels.
    public var bodyHeight: Int? {
        guard let p = prev else { return nil }
        guard let m = lastMatch else { return p.height }
        return p.height - m.header - m.footer
    }

    public func add(_ img: CGImage, requestedShift: Int) -> Step {
        let sig = FrameSignature(img)
        guard let p = prev else {
            guard let seg = Self.copyRows(img, 0, img.height) else { return .failed }
            segments = [seg]
            height = img.height
            prev = sig
            return .first
        }
        let expected = Int((Double(requestedShift) * ratio).rounded())
        let raw = StitchMatcher.match(p, sig, expected: expected)
        lastRaw = raw
        guard let m = raw else { return .failed }
        if m.shift == 0 { return .noChange }
        lastMatch = m
        if requestedShift > 0 && m.score > 0 {
            ratio = min(4, max(0.25, Double(m.shift) / Double(requestedShift)))
        }
        // Drop the previous frame's footer, then append the newly revealed rows plus the footer.
        let from = img.height - m.footer - m.shift
        let room = maxHeight - height
        trim(m.footer)
        if m.shift >= room {   // size limit: keep what fits, skip the footer
            if room > 0, let seg = Self.copyRows(img, from, room) { segments.append(seg); height += room }
            prev = sig
            return .full
        }
        guard let seg = Self.copyRows(img, from, m.shift + m.footer) else { return .failed }
        segments.append(seg)
        height += m.shift + m.footer
        prev = sig
        return .appended(m.shift)
    }

    private func trim(_ rows: Int) {
        var n = rows
        while n > 0, let last = segments.last {
            if last.height <= n {
                segments.removeLast()
                n -= last.height
                height -= last.height
            } else if let c = last.cropping(to: CGRect(x: 0, y: 0, width: last.width, height: last.height - n)) {
                segments[segments.count - 1] = c
                height -= n
                n = 0
            } else { break }
        }
    }

    public func compose() -> CGImage? {
        guard let first = segments.first, height > 0 else { return nil }
        let w = first.width
        guard let ctx = Self.context(w, height, first.colorSpace) else { return nil }
        var yTop = 0
        for s in segments {
            ctx.draw(s, in: CGRect(x: 0, y: height - yTop - s.height, width: w, height: s.height))
            yTop += s.height
        }
        return ctx.makeImage()
    }

    public static func context(_ w: Int, _ h: Int, _ cs: CGColorSpace?) -> CGContext? {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let cs, cs.supportsOutput,
           let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) {
            return c
        }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    /// Copies rows [y, y+count) into a standalone image so the full frame can be freed.
    static func copyRows(_ img: CGImage, _ y: Int, _ count: Int) -> CGImage? {
        guard count > 0, let crop = img.cropping(to: CGRect(x: 0, y: y, width: img.width, height: count)),
              let ctx = context(img.width, count, img.colorSpace) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: img.width, height: count))
        return ctx.makeImage()
    }
}
