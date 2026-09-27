import Foundation

// Copy-Window-Rule snippet builder: turns a focused window into a
// ready-to-paste `[windows]` rule. Ports `src/config/snippet.rs`
// (`window_rule_snippet`, `rule_key`, `title_pattern`, `quote`,
// `identity_comment`) in both TOML and Lua dialects.
//
// Regex escaping is implemented by hand (escape every non-`[A-Za-z0-9_]`
// character) to match `regex::escape` exactly, rather than depending on
// `NSRegularExpression.escapedPattern`, whose escape set differs.

public enum SnippetDialect: Sendable {
    case toml
    case lua
}

/// The window a rule is written for.
public struct RuleSubject: Sendable {
    public var appName: String
    public var bundleID: String
    public var title: String
    public var role: String
    public var subrole: String

    public init(
        appName: String, bundleID: String, title: String,
        role: String = "AXWindow", subrole: String = "AXStandardWindow"
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.subrole = subrole
    }
}

/// Builds the snippet for `subject` in `dialect`.
public func windowRuleSnippet(_ dialect: SnippetDialect, subject: RuleSubject) -> String {
    let key = ruleKey(subject.appName)
    let title = titlePattern(subject.title)
    // An anchored empty title matches nothing useful, so the wildcard is
    // already the live pattern and there is no alternative left to suggest.
    let wildcardAlternative = !subject.title.isEmpty
    let identity = identityComment(subject)
    let bundleID = quote(subject.bundleID)

    var lines: [String] = []
    switch dialect {
    case .toml:
        lines.append("[windows.\(key)]")
        if subject.bundleID.isEmpty {
            lines.append("# bundle_id = \"\"   # unknown; rule matches every app")
        } else {
            lines.append("bundle_id = \"\(bundleID)\"")
        }
        lines.append("title = \"\(title)\"")
        if wildcardAlternative {
            lines.append("# title = \".*\"   # all windows of this app")
        }
        lines.append("# \(identity)")
        lines.append("# floating = true")
        lines.append("# manage = true")
        lines.append("# width = 0.5")
    case .lua:
        lines.append("windows = {")
        lines.append("  \(key) = {")
        if subject.bundleID.isEmpty {
            lines.append("    -- bundle_id = \"\",   -- unknown; rule matches every app")
        } else {
            lines.append("    bundle_id = \"\(bundleID)\",")
        }
        lines.append("    title = \"\(title)\",")
        if wildcardAlternative {
            lines.append("    -- title = \".*\",   -- all windows of this app")
        }
        lines.append("    -- \(identity)")
        lines.append("    -- floating = true,")
        lines.append("    -- manage = true,")
        lines.append("    -- width = 0.5,")
        lines.append("  },")
        lines.append("}")
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

/// Table key from an app name: lowercased, runs of non-alphanumerics
/// collapsed to one underscore. A leading digit expands to an English word
/// so the key stays a valid bare identifier in TOML and Lua.
public func ruleKey(_ appName: String) -> String {
    var key = ""
    key.reserveCapacity(appName.count + 4)
    var firstAlnum = true
    for character in appName {
        let isAlnum = character.isLetter || character.isNumber
        if firstAlnum {
            if character.isWhitespace || !isAlnum { continue }
            firstAlnum = false
            switch character {
            case "0": key += "zero"
            case "1": key += "one"
            case "2": key += "two"
            case "3": key += "three"
            case "4": key += "four"
            case "5": key += "five"
            case "6": key += "six"
            case "7": key += "seven"
            case "8": key += "eight"
            case "9": key += "nine"
            case let c where c.isASCII && c.isLetter:
                key.append(contentsOf: String(c).lowercased())
            default: break
            }
            continue
        }
        if character.isASCII && (character.isLetter || character.isNumber) {
            key.append(contentsOf: String(character).lowercased())
        } else if !key.hasSuffix("_") {
            key.append("_")
        }
    }
    let trimmed = key.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return trimmed.isEmpty ? "window" : trimmed
}

/// The regex a rule carries to match exactly this title: escaped so the
/// title's punctuation stays literal, anchored so it never also matches
/// longer titles (`is_match` is unanchored).
public func titlePattern(_ title: String) -> String {
    guard !title.isEmpty else { return ".*" }
    return quote("^\(regexEscape(title))$")
}

/// Escape for regex: exactly the meta characters `regex::escape` escapes.
/// Mirrors `regex_syntax::is_meta_character` verbatim — spaces, quotes,
/// and other literals pass through untouched.
public func regexEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{",
             "}", "^", "$", "#", "&", "-", "~":
            out.append("\\")
        default:
            break
        }
        out.append(character)
    }
    return out
}

/// Escape for a TOML basic string or Lua double-quoted string. Runs after
/// `regexEscape`, whose backslashes need escaping in turn.
public func quote(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.append(character)
        }
    }
    return out
}

/// The comment identifying the window. None of these match anything; they
/// only tell the pasted rule apart from the next one.
public func identityComment(_ subject: RuleSubject) -> String {
    let name = subject.appName.isEmpty ? "?" : subject.appName
    let role = subject.role.isEmpty ? "?" : subject.role
    let subrole = subject.subrole.isEmpty ? "?" : subject.subrole
    return "app: \(name)  role: \(role)  subrole: \(subrole)"
}
