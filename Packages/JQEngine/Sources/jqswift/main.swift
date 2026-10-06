import Foundation
import JQEngine

// A small jq-compatible command line for trying the engine on a Mac or
// Linux: jqswift [-c] [-n] [-s] [-r] [-S] [--arg name value]
//                [--argjson name json] FILTER [FILE]

var compact = false
var nullInput = false
var slurp = false
var raw = false
var sortKeys = false
var asciiOnly = false
var arguments: [String: JSON] = [:]
var positional: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while let first = args.first {
    args.removeFirst()
    switch first {
    case "-c": compact = true
    case "-n": nullInput = true
    case "-s": slurp = true
    case "-r": raw = true
    case "-S": sortKeys = true
    case "-a": asciiOnly = true
    case "--arg":
        guard args.count >= 2 else { fatalError("--arg needs a name and a value") }
        arguments[args[0]] = .string(args[1])
        args.removeFirst(2)
    case "--argjson":
        guard args.count >= 2, let value = try? JSONParser.parseSingle(args[1]) else {
            fatalError("--argjson needs a name and JSON text")
        }
        arguments[args[0]] = value
        args.removeFirst(2)
    default:
        positional.append(first)
    }
}

guard let filterText = positional.first else {
    FileHandle.standardError.write("usage: jqswift [-c] [-n] [-s] [-r] [-S] FILTER [FILE]\n".data(using: .utf8)!)
    exit(2)
}

func writeError(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

let filter: JQFilter
do {
    filter = try JQFilter(filterText, argumentNames: arguments.keys.sorted())
} catch let error as JQCompileError {
    writeError("jq: error: \(error.message)")
    writeError("jq: 1 compile error")
    exit(3)
}

var inputs: [JSON] = []
if nullInput {
    inputs = [.null]
} else {
    let data: Data
    if positional.count > 1 {
        data = (try? Data(contentsOf: URL(fileURLWithPath: positional[1]))) ?? Data()
    } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    do {
        inputs = try JSONParser.parseAll(data)
    } catch let error as JSONParseError {
        writeError("jq: error (at <stdin>:0): \(error.jqDescription)")
        exit(2)
    }
    if slurp { inputs = [.array(inputs)] }
}

let options = JSONWriter.Options(indent: compact ? nil : 2, sortKeys: sortKeys, asciiOnly: asciiOnly)
var exitCode: Int32 = 0
for input in inputs {
    do {
        try filter.run(input, arguments: arguments, limits: JQLimits(timeout: 60), onMessage: { message in
            switch message {
            case .debug(let text): writeError(text)
            case .stderr(let text): FileHandle.standardError.write(text.data(using: .utf8)!)
            }
        }) { value in
            if raw, case .string(let s) = value {
                print(s)
            } else {
                print(JSONWriter.string(value, options: options))
            }
        }
    } catch let error as JQRuntimeError {
        if case .string(let message) = error.value {
            writeError("jq: error (at <stdin>:0): \(message)")
        } else {
            writeError("jq: error (at <stdin>:0) (not a string): \(JSONWriter.string(error.value))")
        }
        exitCode = 5
    } catch let halt as JQHalt {
        if let message = halt.message {
            if case .string(let s) = message {
                FileHandle.standardError.write(s.data(using: .utf8)!)
            } else {
                writeError(JSONWriter.string(message))
            }
        }
        exit(Int32(halt.exitCode))
    } catch let stop as JQStopReason {
        writeError("jq: stopped: \(stop)")
        exitCode = 5
    }
}
exit(exitCode)
