import Foundation

/// Number text exactly as jq 1.7.1 prints it.
enum NumberFormat {
    /// Formats a computed (non-literal) double like jq's `jvp_dtoa_fmt`:
    /// shortest round-trip digits, fixed notation unless the decimal exponent
    /// is below -4 or more than 15 places past the last digit.
    static func jqFormat(_ input: Double) -> String {
        if input.isNaN { return "null" }
        var value = input
        if value > Double.greatestFiniteMagnitude { value = Double.greatestFiniteMagnitude }
        if value < -Double.greatestFiniteMagnitude { value = -Double.greatestFiniteMagnitude }
        if value == 0 {
            return value.sign == .minus ? "-0" : "0"
        }
        if value == value.rounded(.towardZero), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let (negative, digits, decpt) = shortestDigits(value)
        return format(negative: negative, digits: digits, decpt: decpt)
    }

    /// Splits Swift's shortest round-trip description into sign, significant
    /// digits (no leading or trailing zeros) and the decimal point position
    /// relative to the first digit.
    static func shortestDigits(_ value: Double) -> (negative: Bool, digits: [UInt8], decpt: Int) {
        let text = Array(value.description.utf8)
        var i = 0
        var negative = false
        if i < text.count, text[i] == UInt8(ascii: "-") {
            negative = true
            i += 1
        }
        var mantissa: [UInt8] = []
        var intDigits = 0
        var seenPoint = false
        var exponent = 0
        while i < text.count {
            let c = text[i]
            if c >= 48 && c <= 57 {
                mantissa.append(c)
                if !seenPoint { intDigits += 1 }
            } else if c == UInt8(ascii: ".") {
                seenPoint = true
            } else if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                var j = i + 1
                var expNegative = false
                if j < text.count, text[j] == UInt8(ascii: "+") || text[j] == UInt8(ascii: "-") {
                    expNegative = text[j] == UInt8(ascii: "-")
                    j += 1
                }
                var e = 0
                while j < text.count, text[j] >= 48, text[j] <= 57 {
                    e = e * 10 + Int(text[j] - 48)
                    j += 1
                }
                exponent = expNegative ? -e : e
                break
            }
            i += 1
        }
        var decpt = intDigits + exponent
        var start = 0
        while start < mantissa.count - 1, mantissa[start] == 48 {
            start += 1
            decpt -= 1
        }
        var end = mantissa.count
        while end > start + 1, mantissa[end - 1] == 48 {
            end -= 1
        }
        return (negative, Array(mantissa[start..<end]), decpt)
    }

    static func format(negative: Bool, digits: [UInt8], decpt: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(digits.count + 8)
        if negative { out.append(UInt8(ascii: "-")) }
        if decpt <= -4 || decpt > digits.count + 15 {
            out.append(digits[0])
            if digits.count > 1 {
                out.append(UInt8(ascii: "."))
                out.append(contentsOf: digits[1...])
            }
            out.append(UInt8(ascii: "e"))
            var e = decpt - 1
            if e < 0 {
                out.append(UInt8(ascii: "-"))
                e = -e
            } else {
                out.append(UInt8(ascii: "+"))
            }
            let expText = Array(String(e).utf8)
            if expText.count < 2 { out.append(UInt8(ascii: "0")) }
            out.append(contentsOf: expText)
        } else if decpt <= 0 {
            out.append(UInt8(ascii: "0"))
            out.append(UInt8(ascii: "."))
            for _ in 0..<(-decpt) { out.append(UInt8(ascii: "0")) }
            out.append(contentsOf: digits)
        } else {
            for (index, d) in digits.enumerated() {
                out.append(d)
                if index + 1 == decpt && index + 1 < digits.count {
                    out.append(UInt8(ascii: "."))
                }
            }
            if decpt > digits.count {
                for _ in 0..<(decpt - digits.count) { out.append(UInt8(ascii: "0")) }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A decimal literal as decNumber parses it: sign, coefficient digits and
/// exponent. jq 1.7.1 keeps these for every number literal and prints them
/// in decNumber's to-scientific-string form while the number is unchanged.
struct DecimalLiteral {
    enum Special { case infinity, nan }

    var negative: Bool
    /// Coefficient digits as ASCII bytes, leading zeros removed ("0" for zero).
    var digits: [UInt8]
    /// value = coefficient × 10^exponent
    var exponent: Int
    var special: Special?

    /// decNumber's exponent limit; literals outside it overflow.
    private static let maxExponent = 999_999_999

    init?(_ text: Substring) {
        let bytes = Array(text.utf8)
        var i = 0
        negative = false
        exponent = 0
        special = nil
        digits = []
        guard !bytes.isEmpty else { return nil }
        if bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        guard i < bytes.count else { return nil }
        let rest = String(decoding: bytes[i...], as: UTF8.self).lowercased()
        if rest == "inf" || rest == "infinity" {
            special = .infinity
            digits = [UInt8(ascii: "0")]
            return
        }
        if rest == "nan" {
            // NaN payloads ("nan1234") are rejected, as in jq's fix for
            // CVE-2024-53427.
            special = .nan
            digits = [UInt8(ascii: "0")]
            return
        }
        var coefficient: [UInt8] = []
        var fractionDigits = 0
        var sawDigit = false
        var sawPoint = false
        while i < bytes.count {
            let c = bytes[i]
            if c >= 48 && c <= 57 {
                coefficient.append(c)
                sawDigit = true
                if sawPoint { fractionDigits += 1 }
            } else if c == UInt8(ascii: ".") {
                if sawPoint { return nil }
                sawPoint = true
            } else {
                break
            }
            i += 1
        }
        guard sawDigit else { return nil }
        var exp = 0
        if i < bytes.count {
            guard bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") else { return nil }
            i += 1
            var expNegative = false
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
                expNegative = bytes[i] == UInt8(ascii: "-")
                i += 1
            }
            guard i < bytes.count else { return nil }
            var expDigits = 0
            while i < bytes.count {
                let c = bytes[i]
                guard c >= 48 && c <= 57 else { return nil }
                if exp < 10_000_000_000 { exp = exp * 10 + Int(c - 48) }
                expDigits += 1
                i += 1
            }
            guard expDigits > 0 else { return nil }
            if expNegative { exp = -exp }
        }
        var start = 0
        while start < coefficient.count - 1, coefficient[start] == UInt8(ascii: "0") {
            start += 1
        }
        digits = Array(coefficient[start...])
        exponent = exp - fractionDigits
        if digits == [UInt8(ascii: "0")] {
            // Zero keeps its exponent so "0.0" prints as "0.0".
        }
        let adjusted = exponent + digits.count - 1
        if adjusted > Self.maxExponent && !isZero {
            special = .infinity
        }
    }

    var isZero: Bool {
        special == nil && digits.allSatisfy { $0 == UInt8(ascii: "0") }
    }

    /// decNumber's to-scientific-string conversion.
    var canonicalText: String? {
        if special != nil { return nil }
        let adjusted = exponent + digits.count - 1
        var out: [UInt8] = []
        out.reserveCapacity(digits.count + 8)
        if negative { out.append(UInt8(ascii: "-")) }
        if exponent <= 0 && adjusted >= -6 {
            if exponent == 0 {
                out.append(contentsOf: digits)
            } else {
                let point = digits.count + exponent
                if point > 0 {
                    out.append(contentsOf: digits[0..<point])
                    out.append(UInt8(ascii: "."))
                    out.append(contentsOf: digits[point...])
                } else {
                    out.append(UInt8(ascii: "0"))
                    out.append(UInt8(ascii: "."))
                    for _ in 0..<(-point) { out.append(UInt8(ascii: "0")) }
                    out.append(contentsOf: digits)
                }
            }
        } else {
            out.append(digits[0])
            if digits.count > 1 {
                out.append(UInt8(ascii: "."))
                out.append(contentsOf: digits[1...])
            }
            out.append(UInt8(ascii: "E"))
            out.append(adjusted >= 0 ? UInt8(ascii: "+") : UInt8(ascii: "-"))
            out.append(contentsOf: Array(String(abs(adjusted)).utf8))
        }
        return String(decoding: out, as: UTF8.self)
    }

    var doubleValue: Double {
        switch special {
        case .infinity: return negative ? -.infinity : .infinity
        case .nan: return .nan
        case nil: break
        }
        guard let text = canonicalText, let d = Double(text) else {
            return negative ? -.infinity : .infinity
        }
        return d
    }

    func makeNumber() -> JSONNumber {
        let value = doubleValue
        guard special == nil, let text = canonicalText else {
            return JSONNumber(value: value, literal: nil, needsDecimalComparison: false)
        }
        let needsDecimal = digits.count > 15 || !value.isFinite || (value == 0 && !isZero)
        return JSONNumber(value: value, literal: text, needsDecimalComparison: needsDecimal)
    }

    /// Exact decimal comparison of two finite literals.
    static func compare(_ a: DecimalLiteral, _ b: DecimalLiteral) -> Int {
        if a.special == .infinity || b.special == .infinity {
            let av: Double = a.special == .infinity ? (a.negative ? -.infinity : .infinity) : 0
            let bv: Double = b.special == .infinity ? (b.negative ? -.infinity : .infinity) : 0
            if a.special == .infinity && b.special == .infinity { return av == bv ? 0 : (av < bv ? -1 : 1) }
            if a.special == .infinity { return a.negative ? -1 : 1 }
            return b.negative ? 1 : -1
        }
        let aZero = a.isZero
        let bZero = b.isZero
        if aZero && bZero { return 0 }
        if aZero { return b.negative ? 1 : -1 }
        if bZero { return a.negative ? -1 : 1 }
        if a.negative != b.negative { return a.negative ? -1 : 1 }
        let magnitude = compareMagnitude(a, b)
        return a.negative ? -magnitude : magnitude
    }

    private static func compareMagnitude(_ a: DecimalLiteral, _ b: DecimalLiteral) -> Int {
        let aAdjusted = a.exponent + a.digits.count - 1
        let bAdjusted = b.exponent + b.digits.count - 1
        if aAdjusted != bAdjusted { return aAdjusted < bAdjusted ? -1 : 1 }
        let ad = a.digits.reversed().drop(while: { $0 == UInt8(ascii: "0") }).reversed()
        let bd = b.digits.reversed().drop(while: { $0 == UInt8(ascii: "0") }).reversed()
        let n = max(ad.count, bd.count)
        let aArr = Array(ad)
        let bArr = Array(bd)
        for i in 0..<n {
            let x = i < aArr.count ? aArr[i] : UInt8(ascii: "0")
            let y = i < bArr.count ? bArr[i] : UInt8(ascii: "0")
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
