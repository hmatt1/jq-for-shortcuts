import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc)
/// `strptime` needs _XOPEN_SOURCE, which Swift's Glibc module does not set.
@_silgen_name("strptime")
private func platformStrptime(_ s: UnsafePointer<CChar>, _ format: UnsafePointer<CChar>,
                              _ tm: UnsafeMutablePointer<tm>) -> UnsafeMutablePointer<CChar>?
#else
@inline(__always)
private func platformStrptime(_ s: UnsafePointer<CChar>, _ format: UnsafePointer<CChar>,
                              _ tm: UnsafeMutablePointer<tm>) -> UnsafeMutablePointer<CChar>? {
    strptime(s, format, tm)
}
#endif

/// Date builtins, following jq 1.7.1's C implementations. Broken-down times
/// are arrays: [year, month (0-11), day, hours, minutes, seconds, weekday,
/// day of year].
enum Dates {
    static func builtins() -> [NativeBuiltin] {
        var list: [NativeBuiltin] = []
        list.append(Builtins.unary("now") { _, _ in .number(Date().timeIntervalSince1970) })
        list.append(Builtins.unary("gmtime") { v, _ in try brokenDown(v, local: false) })
        list.append(Builtins.unary("localtime") { v, _ in try brokenDown(v, local: true) })
        list.append(Builtins.unary("mktime") { v, _ in
            guard case .array(let fields) = v else { throw JQRuntimeError("mktime requires array inputs") }
            guard fields.count >= 6 else { throw JQRuntimeError("mktime requires parsed datetime inputs") }
            guard var t = toTM(fields) else { throw JQRuntimeError("mktime requires parsed datetime inputs") }
            let seconds = timegm(&t)
            if seconds == -1 { throw JQRuntimeError("invalid gmtime representation") }
            return .number(Double(seconds))
        })
        list.append(Builtins.valued("strftime", 1) { v, a, _ in
            try format(v, a[0], local: false, name: "strftime/1")
        })
        list.append(Builtins.valued("strflocaltime", 1) { v, a, _ in
            try format(v, a[0], local: true, name: "strflocaltime/1")
        })
        list.append(Builtins.valued("strptime", 1) { v, a, _ in
            guard case .string(let input) = v, case .string(let fmt) = a[0] else {
                throw JQRuntimeError("strptime/1 requires string inputs and arguments")
            }
            return try parse(input, fmt)
        })
        return list
    }

    static func tmToJSON(_ t: tm) -> [JSON] {
        [
            .number(Int(t.tm_year) + 1900), .number(Int(t.tm_mon)), .number(Int(t.tm_mday)),
            .number(Int(t.tm_hour)), .number(Int(t.tm_min)), .number(Int(t.tm_sec)),
            .number(Int(t.tm_wday)), .number(Int(t.tm_yday))
        ]
    }

    /// `jv2tm`: needs numbers at indices 0 through 7.
    static func toTM(_ fields: [JSON]) -> tm? {
        var t = tm()
        func field(_ i: Int) -> Int32? {
            guard i < fields.count, case .number(let n) = fields[i] else { return nil }
            return Int32(clamping: Int(n.value.isFinite ? n.value.rounded(.towardZero) : 0))
        }
        guard let year = field(0), let mon = field(1), let mday = field(2), let hour = field(3),
              let minute = field(4), let sec = field(5), let wday = field(6), let yday = field(7) else {
            return nil
        }
        t.tm_year = year - 1900
        t.tm_mon = mon
        t.tm_mday = mday
        t.tm_hour = hour
        t.tm_min = minute
        t.tm_sec = sec
        t.tm_wday = wday
        t.tm_yday = yday
        return t
    }

    static func brokenDown(_ v: JSON, local: Bool) throws -> JSON {
        guard case .number(let n) = v else {
            throw JQRuntimeError(local ? "localtime() requires numeric inputs" : "gmtime() requires numeric inputs")
        }
        let fsecs = n.value
        guard fsecs.isFinite, abs(fsecs) < 1e17 else {
            throw JQRuntimeError("error converting number of seconds since epoch to datetime")
        }
        var secs = time_t(fsecs)
        var t = tm()
        let ok = local ? localtime_r(&secs, &t) : gmtime_r(&secs, &t)
        guard ok != nil else {
            throw JQRuntimeError("error converting number of seconds since epoch to datetime")
        }
        var fields = tmToJSON(t)
        fields[5] = .number(Double(t.tm_sec) + (fsecs - Foundation.floor(fsecs)))
        return .array(fields)
    }

    static func format(_ v: JSON, _ fmtValue: JSON, local: Bool, name: String) throws -> JSON {
        var value = v
        if case .number = v {
            value = try brokenDown(v, local: local)
        } else if case .array = v {
            guard case .string = fmtValue else {
                throw JQRuntimeError("\(name) requires a string format")
            }
        } else {
            throw JQRuntimeError("\(name) requires parsed datetime inputs")
        }
        guard case .array(let fields) = value, var t = toTM(fields) else {
            throw JQRuntimeError("\(name) requires parsed datetime inputs")
        }
        guard case .string(let fmt) = fmtValue else {
            throw JQRuntimeError("\(name) requires a string format")
        }
        let capacity = fmt.utf8.count + 100
        var buffer = [CChar](repeating: 0, count: capacity)
        let written = fmt.withCString { strftime(&buffer, capacity, $0, &t) }
        if written == 0 && !fmt.isEmpty {
            throw JQRuntimeError("\(name): unknown system failure")
        }
        let bytes = buffer.prefix(written).map { UInt8(bitPattern: $0) }
        return .string(String(decoding: bytes, as: UTF8.self))
    }

    static func parse(_ input: String, _ fmt: String) throws -> JSON {
        var t = tm()
        t.tm_wday = 8
        t.tm_yday = 367
        var remainder: String?
        let matched: Bool = input.withCString { inputPtr in
            fmt.withCString { fmtPtr in
                guard let end = platformStrptime(inputPtr, fmtPtr, &t) else { return false }
                if end.pointee != 0 {
                    let first = UInt8(bitPattern: end.pointee)
                    guard first == 0x20 || (first >= 0x09 && first <= 0x0D) else { return false }
                    remainder = String(cString: end)
                }
                return true
            }
        }
        guard matched else {
            throw JQRuntimeError("date \"\(input)\" does not match format \"\(fmt)\"")
        }
        setWeekday(&t)
        setYearDay(&t)
        var fields = tmToJSON(t)
        if let remainder { fields.append(.string(remainder)) }
        return .array(fields)
    }

    /// jq's `set_tm_wday` (Gauss's algorithm).
    static func setWeekday(_ t: inout tm) {
        let century = (1900 + Int(t.tm_year)) / 100
        var year = (1900 + Int(t.tm_year)) % 100
        if t.tm_mon < 2 { year -= 1 }
        var mon = Int(t.tm_mon) - 1
        if mon < 1 { mon += 12 }
        var wday = (Int(t.tm_mday) + Int(Foundation.floor(2.6 * Double(mon) - 0.2)) + year
                    + Int(Foundation.floor(Double(year) / 4.0)) + Int(Foundation.floor(Double(century) / 4.0)) - 2 * century) % 7
        if wday < 0 { wday += 7 }
        t.tm_wday = Int32(wday)
    }

    /// jq's `set_tm_yday`.
    static func setYearDay(_ t: inout tm) {
        let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        var mon = Int(t.tm_mon)
        let year = 1900 + Int(t.tm_year)
        var leapDay = 0
        if t.tm_mon > 1 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) { leapDay = 1 }
        if mon < 0 { mon = -mon }
        if mon > 11 { mon %= 12 }
        t.tm_yday = Int32(cumulative[mon] + leapDay + Int(t.tm_mday) - 1)
    }
}
