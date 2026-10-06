import Foundation

/// The `@format` filters, matching jq 1.7.1's `f_format`.
enum Formats {
    static let names = ["text", "json", "csv", "tsv", "html", "uri", "sh", "base64", "base64d"]

    static func apply(_ name: String, to value: JSON) throws -> String {
        switch name {
        case "text":
            return Ops.toString(value)
        case "json":
            return JSONWriter.string(value)
        case "csv":
            return try row(value, csv: true)
        case "tsv":
            return try row(value, csv: false)
        case "html":
            return escape(Ops.toString(value), [
                "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&apos;", "\"": "&quot;"
            ])
        case "uri":
            return uri(Ops.toString(value))
        case "sh":
            return try shell(value)
        case "base64":
            return base64Encode(Array(Ops.toString(value).utf8))
        case "base64d":
            return try base64Decode(value)
        default:
            throw JQRuntimeError("\(name) is not a valid format")
        }
    }

    /// `escape_string`: NUL always becomes `\0`, plus the given replacements.
    private static func escape(_ s: String, _ table: [Character: String]) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            if scalar.value == 0 {
                out += "\\0"
            } else if scalar.isASCII, let replacement = table[Character(scalar)] {
                out += replacement
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func row(_ value: JSON, csv: Bool) throws -> String {
        guard case .array(let items) = value else {
            throw Ops.typeError(value, csv ? "cannot be csv-formatted, only array" : "cannot be tsv-formatted, only array")
        }
        var line = ""
        for (i, item) in items.enumerated() {
            if i > 0 { line += csv ? "," : "\t" }
            switch item {
            case .null:
                break
            case .bool:
                line += JSONWriter.string(item)
            case .number(let n):
                if !n.value.isNaN { line += JSONWriter.string(item) }
            case .string(let s):
                if csv {
                    line += "\"" + escape(s, ["\"": "\"\""]) + "\""
                } else {
                    line += escape(s, ["\t": "\\t", "\r": "\\r", "\n": "\\n", "\\": "\\\\"])
                }
            default:
                throw Ops.typeError(item, "is not valid in a csv row")
            }
        }
        return line
    }

    private static func uri(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            let c = Character(Unicode.Scalar(byte))
            if byte < 128 && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." || c == "~") {
                out.append(c)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func shell(_ value: JSON) throws -> String {
        let items: [JSON]
        if case .array(let a) = value { items = a } else { items = [value] }
        var parts: [String] = []
        for item in items {
            switch item {
            case .null, .bool, .number:
                parts.append(JSONWriter.string(item))
            case .string(let s):
                parts.append("'" + escape(s, ["'": "'\\''"]) + "'")
            default:
                throw Ops.typeError(item, "can not be escaped for shell")
            }
        }
        return parts.joined(separator: " ")
    }

    private static let encodeTable = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    static func base64Encode(_ data: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((data.count + 2) / 3 * 4)
        var i = 0
        while i < data.count {
            let n = min(3, data.count - i)
            var code: UInt32 = 0
            for j in 0..<3 {
                code <<= 8
                if j < n { code |= UInt32(data[i + j]) }
            }
            var chunk = [UInt8](repeating: 0, count: 4)
            for j in 0..<4 {
                chunk[j] = encodeTable[Int((code >> UInt32(18 - j * 6)) & 0x3F)]
            }
            if n < 3 { chunk[3] = UInt8(ascii: "=") }
            if n < 2 { chunk[2] = UInt8(ascii: "=") }
            out.append(contentsOf: chunk)
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func decodeValue(_ c: UInt8) -> UInt32? {
        switch c {
        case 65...90: return UInt32(c - 65)
        case 97...122: return UInt32(c - 71)
        case 48...57: return UInt32(c + 4)
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }

    private static func base64Decode(_ value: JSON) throws -> String {
        let text = Ops.toString(value)
        let data = Array(text.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(data.count * 3 / 4)
        var code: UInt32 = 0
        var count = 0
        for c in data {
            if c == UInt8(ascii: "=") { break }
            guard let v = decodeValue(c) else {
                throw Ops.typeError(.string(text), "is not valid base64 data")
            }
            code = code << 6 | v
            count += 1
            if count == 4 {
                result.append(UInt8((code >> 16) & 0xFF))
                result.append(UInt8((code >> 8) & 0xFF))
                result.append(UInt8(code & 0xFF))
                count = 0
                code = 0
            }
        }
        if count == 3 {
            result.append(UInt8((code >> 10) & 0xFF))
            result.append(UInt8((code >> 2) & 0xFF))
        } else if count == 2 {
            result.append(UInt8((code >> 4) & 0xFF))
        } else if count == 1 {
            throw Ops.typeError(.string(text), "trailing base64 byte found")
        }
        return String(decoding: result, as: UTF8.self)
    }
}
