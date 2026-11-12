import CoreGraphics
import Foundation
import Vision

/// Reads the text on a picture (Vision, on-device; Russian and English).
enum TextRecognizer {
    /// The recognized text, line by line from top to bottom; "" if there is none.
    static func text(in img: CGImage) async -> String {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: recognize(img)) }
        }
    }

    static func recognize(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["ru-RU", "en-US"]
        do { try VNImageRequestHandler(cgImage: img).perform([req]) } catch {
            Log.error("ocr", "recognition failed: \(error)")
            return ""
        }
        let found: [(box: CGRect, text: String)] = (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, s)
        }
        // Vision's boxes have a bottom-left origin. Group pieces into rows (top first), then read each row left to right.
        var rows: [[(box: CGRect, text: String)]] = []
        for o in found.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - o.box.midY) < min(first.box.height, o.box.height) / 2 {
                rows[rows.count - 1].append(o)
            } else {
                rows.append([o])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
