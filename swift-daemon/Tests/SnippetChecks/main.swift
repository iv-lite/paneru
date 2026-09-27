import Foundation
import Snippets

// Parity ports of `src/config/snippet.rs` tests: verbatim TOML/Lua
// documents, key sanitization, escaping order (verified behaviorally
// through NSRegularExpression, like the Rust parse-back tests),
// anchoring, and empty-field fallbacks.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual(_ a: String, _ b: String, _ message: String) {
    check(a == b, "\(message)\n--- got ---\n\(a)\n--- want ---\n\(b)")
}

private func subject(app: String = "Ghostty", bundle: String = "com.mitchellh.ghostty", title: String = "paneru") -> RuleSubject {
    RuleSubject(appName: app, bundleID: bundle, title: title)
}

// toml_snippet_has_both_matchers
do {
    checkEqual(
        windowRuleSnippet(.toml, subject: subject()),
        """
        [windows.ghostty]
        bundle_id = "com.mitchellh.ghostty"
        title = "^paneru$"
        # title = ".*"   # all windows of this app
        # app: Ghostty  role: AXWindow  subrole: AXStandardWindow
        # floating = true
        # manage = true
        # width = 0.5

        """,
        "toml snippet verbatim"
    )
}

// lua_snippet_has_both_matchers
do {
    checkEqual(
        windowRuleSnippet(.lua, subject: subject()),
        """
        windows = {
          ghostty = {
            bundle_id = "com.mitchellh.ghostty",
            title = "^paneru$",
            -- title = ".*",   -- all windows of this app
            -- app: Ghostty  role: AXWindow  subrole: AXStandardWindow
            -- floating = true,
            -- manage = true,
            -- width = 0.5,
          },
        }

        """,
        "lua snippet verbatim"
    )
}

// Escaping order: regex metachars escaped, then config-string escaping.
// The regex stage matches regex::escape verbatim (spaces, quotes bare);
// quote() then escapes for the config string.
do {
    let title = "Find \"a.b\" (2) \\ [x]"
    checkEqual(
        regexEscape(title),
        "Find \"a\\.b\" \\(2\\) \\\\ \\[x\\]",
        "regex stage mirrors regex::escape"
    )
    let pattern = titlePattern(title)
    check(pattern.hasPrefix("^") && pattern.hasSuffix("$"), "pattern anchored")
    // The unquoted core matches its title and rejects a longer one
    // (mirrors the Rust parse-back + is_match tests).
    let core = "^\(regexEscape(title))$"
    let regex = try! NSRegularExpression(pattern: core)
    let range = NSRange(title.startIndex..., in: title)
    check(regex.firstMatch(in: title, range: range) != nil, "pattern matches its title")
    let longer = title + "!"
    let longRange = NSRange(longer.startIndex..., in: longer)
    check(regex.firstMatch(in: longer, range: longRange) == nil, "anchored pattern rejects longer titles")
    // quote() escapes the quotes for the config string.
    let snippet = windowRuleSnippet(.toml, subject: RuleSubject(
        appName: "Term", bundleID: "com.apple.Terminal", title: title
    ))
    check(snippet.contains("\\\""), "quotes escaped for the config string")
}

// anchored_pattern_rejects_a_longer_title (simple title).
do {
    let pattern = titlePattern("build")
    checkEqual(pattern, "^build$", "plain title anchors with no escapes")
    let regex = try! NSRegularExpression(pattern: pattern)
    func matches(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return regex.firstMatch(in: s, range: r) != nil
    }
    check(matches("build"), "exact title matches")
    check(!matches("rebuild all"), "longer title rejected")
}

// empty_title_falls_back_to_wildcard
do {
    let snippet = windowRuleSnippet(.toml, subject: RuleSubject(
        appName: "Term", bundleID: "com.x", title: ""
    ))
    check(snippet.contains("title = \".*\"\n"), "empty title is the wildcard")
    check(!snippet.contains("# title = \".*\""), "no alternative suggested")
}

// empty_bundle_id_is_commented_out
do {
    let snippet = windowRuleSnippet(.toml, subject: RuleSubject(
        appName: "Term", bundleID: "", title: "hello"
    ))
    check(
        snippet.contains("# bundle_id = \"\"   # unknown; rule matches every app\n"),
        "empty bundle commented"
    )
}

// rule_keys_are_sanitized
do {
    checkEqual(ruleKey("Ghostty"), "ghostty", "lowercased")
    checkEqual(ruleKey("Visual Studio Code"), "visual_studio_code", "runs collapse")
    checkEqual(ruleKey("1Password 8"), "onepassword_8", "leading digit expands")
    checkEqual(ruleKey("7-Zip"), "seven_zip", "digit plus dash")
    checkEqual(ruleKey("  —  "), "window", "punctuation-only falls back")
    checkEqual(ruleKey(""), "window", "empty falls back")
}

if failures == 0 {
    print("SnippetChecks: all checks passed")
} else {
    print("SnippetChecks: \(failures) failure(s)")
    exit(1)
}
