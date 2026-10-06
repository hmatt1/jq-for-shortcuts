import Foundation

/// Serializes JSON exactly the way jq 1.7.1 prints it.
public enum JSONWriter {
    public struct Options: Sendable, Equatable {
        /// Indent width for pretty output; nil prints compact JSON (`jq -c`).
        public var indent: Int?
        /// Sort object keys by their UTF-8 bytes (`jq -S`).
        public var sortKeys: Bool
        /// Escape every non-ASCII character (`jq -a`).
        public var asciiOnly: Bool

        public init(indent: Int? = nil, sortKeys: Bool = false, asciiOnly: Bool = false) {
            self.indent = indent
            self.sortKeys = sortKeys
            self.asciiOnly = asciiOnly
        }

        public static let compact = Options()
        public static let pretty = Options(indent: 2)
    }

    public static func string(_ value: JSON, options: Options = .compact) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        write(value, options: options, level: 0, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// jq's MAX_PRINT_DEPTH: deeper values print as "<skipped: too deep>".
    static let maxPrintDepth = 256

    static func write(_ value: JSON, options: Options, level: Int, into out: inout [UInt8]) {
        if level > maxPrintDepth {
            out.append(contentsOf: "<skipped: too deep>".utf8)
            return
        }
        switch value {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        case .bool(let b):
            if b {
                out.append(contentsOf: [0x74, 0x72, 0x75, 0x65])
            } else {
                out.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65])
            }
        case .number(let n):
            out.append(contentsOf: n.jqText.utf8)
        case .string(let s):
            writeString(s, asciiOnly: options.asciiOnly, into: &out)
        case .array(let items):
            if items.isEmpty {
                out.append(contentsOf: [0x5B, 0x5D])
                return
            }
            out.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x2C) }
                newline(options, level + 1, &out)
                write(item, options: options, level: level + 1, into: &out)
            }
            newline(options, level, &out)
            out.append(0x5D)
        case .object(let object):
            if object.isEmpty {
                out.append(contentsOf: [0x7B, 0x7D])
                return
            }
            out.append(0x7B)
            let keys = options.sortKeys ? object.sortedKeys : object.keys
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(0x2C) }
                newline(options, level + 1, &out)
                writeString(key, asciiOnly: options.asciiOnly, into: &out)
                out.append(0x3A)
                if options.indent != nil { out.append(0x20) }
                write(object[key] ?? .null, options: options, level: level + 1, into: &out)
            }
            newline(options, level, &out)
            out.append(0x7D)
        }
    }

    @inline(__always)
    private static func newline(_ options: Options, _ level: Int, _ out: inout [UInt8]) {
        guard let indent = options.indent else { return }
        out.append(0x0A)
        let spaces = indent * level
        if spaces > 0 {
            out.append(contentsOf: repeatElement(0x20, count: spaces))
        }
    }

    static func writeString(_ s: String, asciiOnly: Bool, into out: inout [UInt8]) {
        out.append(0x22)
        var needsSlowPath = false
        for c in s.utf8 {
            if c < 0x20 || c == 0x22 || c == 0x5C || c == 0x7F || (asciiOnly && c >= 0x80) {
                needsSlowPath = true
                break
            }
        }
        if !needsSlowPath {
            out.append(contentsOf: s.utf8)
            out.append(0x22)
            return
        }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v >= 0x20 && v <= 0x7E {
                if v == 0x22 || v == 0x5C { out.append(0x5C) }
                out.append(UInt8(v))
            } else if v < 0x20 || v == 0x7F {
                switch v {
                case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
                case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
                case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
                case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
                case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
                default: appendUnicodeEscape(v, &out)
                }
            } else if asciiOnly {
                if v <= 0xFFFF {
                    appendUnicodeEscape(v, &out)
                } else {
                    let u = v - 0x10000
                    appendUnicodeEscape(0xD800 | ((u & 0xFFC00) >> 10), &out)
                    appendUnicodeEscape(0xDC00 | (u & 0x3FF), &out)
                }
            } else {
                var buffer: [UInt8] = []
                JSONParser.Scanner.appendUTF8(v, to: &buffer)
                out.append(contentsOf: buffer)
            }
        }
        out.append(0x22)
    }

    private static func appendUnicodeEscape(_ v: UInt32, _ out: inout [UInt8]) {
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        out.append(0x5C)
        out.append(UInt8(ascii: "u"))
        out.append(hex[Int((v >> 12) & 0xF)])
        out.append(hex[Int((v >> 8) & 0xF)])
        out.append(hex[Int((v >> 4) & 0xF)])
        out.append(hex[Int(v & 0xF)])
    }
}

extension JSON: CustomStringConvertible {
    /// Compact JSON, as `jq -c` prints it.
    public var description: String {
        JSONWriter.string(self, options: .compact)
    }
}
