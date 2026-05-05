//
//  ToolCallDetector.swift
//  Gepetto
//
//  Parses `<tool_call>{...}</tool_call>` blocks (and a few common variants)
//  out of an AI-generated assistant response. Returns the parsed tool call
//  if present, or just the surrounding visible text if not.
//

import Foundation

/// A tool-call request emitted by the AI inside its assistant turn.
public struct GepettoToolCall: Sendable, Equatable {
    public let name: String
    public let arguments: [String: AnyCodable]

    public init(name: String, arguments: [String: AnyCodable]) {
        self.name = name
        self.arguments = arguments
    }
}

/// Type-erased Codable wrapper for tool-call arguments. Round-trips through
/// JSON without losing type information (string / number / bool / null).
public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Bool:   try container.encode(v)
        case let v as Int:    try container.encode(v)
        case let v as Double: try container.encode(v)
        case is NSNull:       try container.encodeNil()
        default:              try container.encode(String(describing: value))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self.value = NSNull(); return }
        if let v = try? container.decode(Bool.self)    { self.value = v; return }
        if let v = try? container.decode(Int.self)     { self.value = v; return }
        if let v = try? container.decode(Double.self)  { self.value = v; return }
        if let v = try? container.decode(String.self)  { self.value = v; return }
        self.value = NSNull()
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - Backward-compat shape used by the agent

/// A simpler tool call shape with `[String: Any]` arguments — what the agent
/// actually wants when dispatching to `BrowserToolExecutor`.
public struct ParsedToolCall {
    public let name: String
    public let arguments: [String: Any]
}

public enum ToolCallDetector {

    private static let patterns = [
        #"<tool_call>\s*\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}\s*</tool_call>"#,
        #"```tool_call\n\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}\n```"#,
        #"<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>"#
    ]

    /// Detect a tool call inside a stream of assistant text. Returns the
    /// parsed (name, arguments) tuple, or nil if no recognizable call.
    public static func detectToolCall(in text: String) -> ParsedToolCall? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }

            // Pattern with separate name + args groups.
            if match.numberOfRanges >= 3 {
                if let nameRange = Range(match.range(at: 1), in: text),
                   let argsRange = Range(match.range(at: 2), in: text) {
                    let name = String(text[nameRange])
                    let argsString = String(text[argsRange])
                    if let argsData = argsString.data(using: .utf8),
                       let arguments = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        return ParsedToolCall(name: name, arguments: arguments)
                    }
                }
            }

            // Pattern with a single JSON object containing name+arguments.
            if match.numberOfRanges == 2 {
                if let blockRange = Range(match.range(at: 1), in: text) {
                    let block = String(text[blockRange])
                    if let data = block.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = obj["name"] as? String,
                       let args = obj["arguments"] as? [String: Any] {
                        return ParsedToolCall(name: name, arguments: args)
                    }
                }
            }
        }
        return nil
    }

    /// Strip every detected tool_call block from the text so we can stream
    /// just the visible commentary into the chat UI.
    public static func extractTextWithoutToolCall(from text: String) -> String {
        var cleaned = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let range = NSRange(location: 0, length: cleaned.utf16.count)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
