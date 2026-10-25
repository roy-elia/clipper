import Foundation
import ImageIO

/// The small facts shown at the foot of a card: size of an image, length of a text, and so on.
public extension ClipItem {
    var pixelSize: (width: Int, height: Int)? {
        guard kind == .image, let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    var wordCount: Int { (text ?? "").split(whereSeparator: \.isWhitespace).count }
    var lineCount: Int { (text ?? "").isEmpty ? 0 : (text ?? "").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count }

    /// One line for the card footer.
    var detail: String {
        if isSecret { return "Hidden" }
        switch kind {
        case .image:
            if let s = pixelSize { return "\(s.width) × \(s.height)" }
            return ByteCountFormatter.string(fromByteCount: Int64(data?.count ?? 0), countStyle: .file)
        case .file:
            let n = fileURLs?.count ?? 0
            let size = (fileURLs ?? []).compactMap { URL(string: $0) }.reduce(Int64(0)) { acc, u in
                acc + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let label = n == 1 ? "1 file" : "\(n) files"
            return size > 0 ? "\(label) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))" : label
        case .link:
            return URL(string: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Link"
        case .color:
            return (text ?? "").uppercased()
        case .text:
            let c = (text ?? "").count
            return c == 1 ? "1 character" : "\(c) characters"
        }
    }

    /// Extra facts for the preview window.
    var moreDetails: [String] {
        guard !isSecret else { return [] }
        var d: [String] = [detail]
        if kind == .text { d.append("\(wordCount) words"); d.append(lineCount == 1 ? "1 line" : "\(lineCount) lines") }
        if isRich { d.append("Formatted") }
        return d
    }
}
