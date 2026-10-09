import Foundation

/// The environment for every `claude` child, built from scratch.
///
/// Verified on this Mac: ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN,
/// CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_USE_BEDROCK/VERTEX each silently move
/// auth off the subscription, and a Claude Code terminal leaks CLAUDECODE /
/// CLAUDE_CODE_*. Scrubbing a denylist would miss the next such variable, so
/// only this allowlist ever reaches the child.
package enum ChildEnvironment {
    package static let keys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "NO_COLOR", "DISABLE_AUTOUPDATER", "PATH",
    ]

    package static let basePath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// `binaryDir` goes first on PATH (the CLI may re-exec helpers next to itself;
    /// `/opt/homebrew/bin` provides `pdftoppm`). Only HOME/USER/LOGNAME/TMPDIR
    /// are taken from `parent`, with passwd / NSTemporaryDirectory fallbacks.
    package static func make(binaryDir: String, parent: [String: String]) -> [String: String] {
        let user = nonEmpty(parent["USER"]) ?? passwdName() ?? NSUserName()
        var path: [String] = []
        if !binaryDir.isEmpty, !binaryDir.contains(":") { path.append(binaryDir) }
        for dir in basePath where !path.contains(dir) { path.append(dir) }
        return [
            "HOME": nonEmpty(parent["HOME"]) ?? SharedPaths.realHome.path,
            "USER": user,
            "LOGNAME": nonEmpty(parent["LOGNAME"]) ?? user,
            "SHELL": "/bin/zsh",
            "TMPDIR": nonEmpty(parent["TMPDIR"]) ?? NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "DISABLE_AUTOUPDATER": "1",
            "PATH": path.joined(separator: ":"),
        ]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func passwdName() -> String? {
        guard let pw = getpwuid(getuid()), let name = pw.pointee.pw_name else { return nil }
        return nonEmpty(String(cString: name))
    }
}
