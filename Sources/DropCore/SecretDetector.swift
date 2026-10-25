import Foundation

/// Rule-based detector for clips that look like credentials. Runs locally and instantly; an on-device language
/// model can refine the ambiguous cases afterwards (see `isAmbiguous`).
public enum SecretDetector {
    public enum Reason: String, Sendable, Equatable {
        case privateKey, cloudKey, apiToken, jwt, credentialAssignment, creditCard, highEntropy
    }

    public static func classify(_ text: String) -> Reason? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 20_000 else { return nil }
        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY") { return .privateKey }
        if matches(t, #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#) { return .cloudKey }
        if matches(t, #"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#)
            || matches(t, #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#)
            || matches(t, #"\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{16,}"#)
            || matches(t, #"\bsk-[A-Za-z0-9_-]{20,}"#)
            || matches(t, #"\bAIza[0-9A-Za-z_-]{30,}"#) { return .apiToken }
        if matches(t, #"^eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#) { return .jwt }
        if matches(t, #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{20,}"#) { return .apiToken }
        if matches(t, #"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret)\b\s*[:=]\s*\S{4,}"#) { return .credentialAssignment }
        if isCreditCard(t) { return .creditCard }
        if isSingleToken(t), t.count >= 24, entropy(t) >= 3.6, classes(t) >= 3 { return .highEntropy }
        return nil
    }

    /// Short, space-free, mixed-class strings that could be a password but might just be an identifier.
    public static func isAmbiguous(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return classify(t) == nil && isSingleToken(t) && (8...64).contains(t.count) && classes(t) >= 3 && !looksLikeWords(t)
    }

    /// "release-notes-draft-2" or "ALLOWED-1792965659": separators between mostly real-looking words and numbers
    /// are identifiers, not passwords, so the model is not asked about them.
    static func looksLikeWords(_ t: String) -> Bool {
        let segs = t.split(whereSeparator: { "-_. /".contains($0) })
        guard segs.count >= 2 else { return false }
        let wordy = segs.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) || $0.allSatisfy(\.isNumber) }.count
        return Double(wordy) / Double(segs.count) >= 0.6
    }

    static func isSingleToken(_ t: String) -> Bool { !t.contains(where: \.isWhitespace) && !t.hasPrefix("http") && !t.hasPrefix("/") }

    static func classes(_ t: String) -> Int {
        [t.contains { $0.isLowercase }, t.contains { $0.isUppercase }, t.contains { $0.isNumber },
         t.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
    }

    static func entropy(_ t: String) -> Double {
        let counts = Dictionary(grouping: t, by: { $0 }).mapValues(\.count)
        return counts.values.reduce(0.0) { acc, c in let p = Double(c) / Double(t.count); return acc - p * log2(p) }
    }

    static func isCreditCard(_ t: String) -> Bool {
        let digits = t.filter(\.isNumber)
        guard (13...19).contains(digits.count), t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue!
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
