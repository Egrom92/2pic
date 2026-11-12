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

/// What a comparison saw, for the log when no offset was accepted.
public struct StitchProbe: CustomStringConvertible {
    public var reason = ""
    public var activeBands = 0
    public var staticTop = 0       // rows at the top / bottom that didn't change (before capping)
    public var staticBottom = 0
    public var height = 0
    public var expected = 0
    public var bestShift = -1
    public var bestScore = 0.0

    /// Most of the frame stayed in place: nothing really scrolled, something on the page just changed
    /// (a video, an animation). For a capture that means the end of the content.
    public var mostlyStatic: Bool { height > 0 && staticTop + staticBottom >= height * 6 / 10 }

    public var description: String {
        "\(reason); active bands \(activeBands)/\(FrameSignature.bands), static top \(staticTop) bottom \(staticBottom) of \(height), "
            + "best shift \(bestShift) (expected \(expected)) score \(String(format: "%.2f", bestScore))"
    }
}

public enum StitchMatcher {
    /// Finds how far the content scrolled from `a` to `b`. `expected` is the scroll we asked for,
    /// in pixels; it breaks ties for repetitive content. Returns nil if no offset fits.
    public static func match(_ a: FrameSignature, _ b: FrameSignature, expected: Int) -> StitchMatch? {
        probe(a, b, expected: expected, confirmed: false).match
    }

    /// `confirmed`: earlier frames have shown how this content scrolls, so a weaker match right at the
    /// expected offset is enough (part of the page changed between the frames: a video, an animation).
    public static func probe(_ a: FrameSignature, _ b: FrameSignature, expected: Int, confirmed: Bool)
        -> (match: StitchMatch?, probe: StitchProbe) {
        var pr = StitchProbe()
        pr.height = a.height
        pr.expected = expected
        guard a.width == b.width, a.height == b.height else { pr.reason = "frame size changed"; return (nil, pr) }
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
        pr.activeBands = activeCount
        if activeCount == 0 { return (StitchMatch(shift: 0, header: h, footer: 0, score: 1), pr) }

        let staticNeed = max(1, activeCount * 9 / 10)
        func equalBands(_ y: Int) -> Int {
            var c = 0
            let o = y * n
            for k in 0..<n where active[k] && a.hash[o + k] == b.hash[o + k] { c += 1 }
            return c
        }
        var top = 0
        while top < h && equalBands(top) >= staticNeed { top += 1 }
        if top == h { return (StitchMatch(shift: 0, header: h, footer: 0, score: 1), pr) }
        var bottom = 0
        while bottom < h - top && equalBands(h - 1 - bottom) >= staticNeed { bottom += 1 }
        pr.staticTop = top
        pr.staticBottom = bottom
        let cap = h * 45 / 100
        let T = min(top, cap), F = min(bottom, cap)
        let body = h - T - F
        guard body > 24 else { pr.reason = "almost nothing moved"; return (nil, pr) }
        let minOverlap = max(12, body / 10)
        let maxShift = body - minOverlap
        guard maxShift >= 1 else { pr.reason = "almost nothing moved"; return (nil, pr) }

        // Detailed active bands of b, per row, and their prefix sums.
        var mask = [UInt8](repeating: 0, count: h * n)
        var pre = [Int](repeating: 0, count: h + 1)
        for y in 0..<h {
            var c = 0
            for k in 0..<n where active[k] && b.info[y * n + k] != 0 { mask[y * n + k] = 1; c += 1 }
            pre[y + 1] = pre[y] + c
        }

        let exp = min(max(expected, 1), maxShift)
        pr.expected = exp
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
        //
        // Each offset is scored on the whole overlap and on its upper half alone. The upper half lies in
        // the middle of the previous frame, where the content had settled. The lower half was the previous
        // frame's bottom edge: that's where lazy images, skeleton placeholders of virtualized lists and
        // entrance animations still show — they look different one frame later and spoil the full score.
        let floor = 0.5
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
                let mid = y0 + (y1 - y0) / 2
                let totalUpper = pre[mid] - pre[y0]
                let upperUsable = totalUpper >= minTotal / 2
                // Misses beyond these can no longer beat the best offset so far (or reach the floor).
                let needFull = max(best + 1.5 / Double(total).squareRoot(), floor)
                let allowFull = Int(Double(total) * (1 - needFull))
                let needUpper = upperUsable ? max(best + 1.5 / Double(totalUpper).squareRoot() + 0.05, floor + 0.05) : 2
                let allowUpper = Int(Double(totalUpper) * (1 - needUpper))
                if allowFull < 0 && allowUpper < 0 { continue }
                var miss = 0, missUpper = -1
                var completed = true
                rows: for y in y0..<y1 {
                    if y == mid { missUpper = miss }
                    if pre[y + 1] == pre[y] { continue }
                    let bo = y * n, ao = (y + s) * n
                    for k in 0..<n where bm[bo + k] != 0 && ah[ao + k] != bh[bo + k] { miss += 1 }
                    if miss > allowFull && (missUpper >= 0 || miss > allowUpper) { completed = false; break rows }
                }
                var raw = -1.0, used = total
                if completed && miss <= allowFull { raw = 1 - Double(miss) / Double(total) }
                if upperUsable, missUpper >= 0, missUpper <= allowUpper {
                    let up = 1 - Double(missUpper) / Double(totalUpper) - 0.05
                    if up > raw { raw = up; used = totalUpper }
                }
                guard raw >= 0 else { continue }
                let penalty = 1.5 / Double(used).squareRoot()
                if raw - penalty > best + 1e-9 { best = raw - penalty; bestShift = s; bestRaw = raw }
            }
        }}}
        if !anyInformative {
            // Only plain background in the overlap: trust the scroll we requested.
            return (StitchMatch(shift: exp, header: T, footer: F, score: 0), pr)
        }
        pr.bestShift = best < 0 ? -1 : bestShift
        pr.bestScore = bestRaw
        let near = { (s: Int) in abs(s - exp) <= max(2, exp / 100) }
        // A clear match anywhere; or a weaker one exactly where the scroll was expected to land.
        if bestRaw >= 0.7 || (best >= 0 && near(bestShift) && bestRaw >= (confirmed ? 0.5 : 0.6)) {
            return (StitchMatch(shift: bestShift, header: T, footer: F, score: bestRaw), pr)
        }

        // Last resort, for a big area that changes on its own (a video, a carousel): it matches at no
        // offset, but the rest of the page still matches at one offset far better than at its neighbours.
        // Accept that offset only where the scroll was expected to land.
        let win = max(40, exp / 6)
        var scores: [(shift: Int, raw: Double)] = []
        a.hash.withUnsafeBufferPointer { ah in
        b.hash.withUnsafeBufferPointer { bh in
        mask.withUnsafeBufferPointer { bm in
            for s in max(1, exp - win)...min(maxShift, exp + win) {
                let y0 = T, y1 = h - F - s
                guard y1 > y0 else { continue }
                let total = pre[y1] - pre[y0]
                if total < minTotal { continue }
                var miss = 0
                for y in y0..<y1 where pre[y + 1] != pre[y] {
                    let bo = y * n, ao = (y + s) * n
                    for k in 0..<n where bm[bo + k] != 0 && ah[ao + k] != bh[bo + k] { miss += 1 }
                }
                scores.append((s, 1 - Double(miss) / Double(total)))
            }
        }}}
        if let top1 = scores.max(by: { $0.raw < $1.raw }) {
            // The runner-up is looked for more than a text line away: within a line, rows can look alike.
            let runnerUp = scores.filter { abs($0.shift - top1.shift) > 20 }.map(\.raw).max() ?? 0
            pr.bestShift = top1.shift
            pr.bestScore = top1.raw
            if near(top1.shift) && top1.raw >= 0.25 && top1.raw >= 2.5 * max(runnerUp, 0.04) {
                return (StitchMatch(shift: top1.shift, header: T, footer: F, score: top1.raw), pr)
            }
            pr.reason = String(format: "no distinct offset (best %.2f, runner-up %.2f)", top1.raw, runnerUp)
        } else {
            pr.reason = best < 0 ? "no offset matched" : "best offset matched too weakly"
        }
        return (nil, pr)
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
    /// What the latest comparison saw (why it failed, if it did).
    public private(set) var lastProbe: StitchProbe?
    /// The latest step moved clearly less than asked: the end of the content is near.
    public private(set) var lastStepShort = false
    private var segments: [CGImage] = []
    private var prev: FrameSignature?
    private var ratio = 1.0       // measured shift / requested shift
    private var confirmed = false // a real match has shown how this content scrolls

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
        let (raw, probe) = StitchMatcher.probe(p, sig, expected: expected, confirmed: confirmed)
        lastRaw = raw
        lastProbe = probe
        // Nothing really scrolled and only part of the page changed (a video, an animation): the end.
        guard let m = raw else { return probe.mostlyStatic ? .noChange : .failed }
        if m.shift == 0 { return .noChange }
        lastMatch = m
        lastStepShort = m.shift < expected * 3 / 4
        if requestedShift > 0 && m.score > 0 {
            ratio = min(4, max(0.25, Double(m.shift) / Double(requestedShift)))
            confirmed = true
        }
        // Seam: rows seen in both frames come from the newer frame in the lower two thirds of the overlap.
        // The previous frame may have shown placeholders there (lazy loading, virtualized lists) that are
        // filled in now. The upper third, next to a sticky header whose edge may be misjudged, stays as is.
        let body = img.height - m.header - m.footer
        let renew = max(0, body - m.shift) * 2 / 3
        let from = img.height - m.footer - m.shift - renew
        let kept = height - m.footer - renew   // after dropping the previous frame's footer and the renewed rows
        var count = m.shift + renew + m.footer
        var step = Step.appended(m.shift)
        if kept + count > maxHeight {   // size limit: keep what fits
            count = max(0, maxHeight - kept)
            step = .full
        }
        let seg = count > 0 ? Self.copyRows(img, from, count) : nil
        if count > 0 && seg == nil { return .failed }
        trim(m.footer + renew)
        if let seg { segments.append(seg); height += count }
        prev = sig
        return step
    }

    private func trim(_ rows: Int) {
        var n = rows
        while n > 0, let last = segments.last {
            if last.height <= n {
                segments.removeLast()
                n -= last.height
                height -= last.height
            } else if let c = Self.copyRows(last, 0, last.height - n) {   // a copy: the cut rows' memory is freed
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
