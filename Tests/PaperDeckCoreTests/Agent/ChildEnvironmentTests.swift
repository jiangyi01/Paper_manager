import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ChildEnvironmentTests {
    /// What a developer shell launched from a Claude Code terminal can look like.
    private let poisoned: [String: String] = [
        "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester-login", "TMPDIR": "/var/folders/xy/T/",
        "SHELL": "/opt/homebrew/bin/fish", "LANG": "zh_CN.UTF-8", "TERM": "xterm-256color", "PATH": "/evil/bin:/usr/bin",
        "ANTHROPIC_API_KEY": "sk-ant-dummy", "ANTHROPIC_AUTH_TOKEN": "tok-dummy",
        "ANTHROPIC_BASE_URL": "https://evil.example", "ANTHROPIC_MODEL": "opus",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth-dummy", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1",
        "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SIMPLE": "1", "CLAUDE_CONFIG_DIR": "/tmp/other",
        "OPENAI_API_KEY": "sk-openai-dummy", "AWS_ACCESS_KEY_ID": "AKIADUMMY",
        "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "NODE_OPTIONS": "--require /tmp/x.js",
    ]

    @Test func outputKeySetIsExactlyTheAllowlist() {
        let env = ChildEnvironment.make(binaryDir: "/Users/tester/.local/bin", parent: poisoned)
        #expect(Set(env.keys) == ChildEnvironment.keys)
        #expect(Set(env.keys) == ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "NO_COLOR",
                                  "DISABLE_AUTOUPDATER", "PATH"])
    }

    @Test func noPoisonedValueSurvives() {
        let env = ChildEnvironment.make(binaryDir: "/Users/tester/.local/bin", parent: poisoned)
        let all = env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        for needle in ["dummy", "evil", "ANTHROPIC", "CLAUDE", "OPENAI", "AWS", "DYLD", "NODE", "fish", "zh_CN", "/tmp/other"] {
            #expect(!all.contains(needle), "leaked \(needle)")
        }
    }

    @Test func fixedAndCopiedValues() {
        let env = ChildEnvironment.make(binaryDir: "/Users/tester/.local/bin", parent: poisoned)
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["USER"] == "tester")
        #expect(env["LOGNAME"] == "tester-login")
        #expect(env["TMPDIR"] == "/var/folders/xy/T/")
        #expect(env["SHELL"] == "/bin/zsh")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["TERM"] == "dumb")
        #expect(env["NO_COLOR"] == "1")
        #expect(env["DISABLE_AUTOUPDATER"] == "1")
        #expect(env["PATH"] == "/Users/tester/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func fallbacksWhenParentIsEmpty() {
        let env = ChildEnvironment.make(binaryDir: "", parent: [:])
        #expect(Set(env.keys) == ChildEnvironment.keys)
        #expect(env["HOME"] == SharedPaths.realHome.path)
        #expect(env["USER"]?.isEmpty == false)
        #expect(env["LOGNAME"] == env["USER"])
        #expect(env["TMPDIR"]?.isEmpty == false)
        #expect(env["PATH"] == ChildEnvironment.basePath.joined(separator: ":"))
    }

    @Test func emptyParentValuesUseFallbacks() {
        let env = ChildEnvironment.make(binaryDir: "", parent: ["HOME": "", "USER": "", "TMPDIR": ""])
        #expect(env["HOME"] == SharedPaths.realHome.path)
        #expect(env["USER"]?.isEmpty == false)
        #expect(env["TMPDIR"]?.isEmpty == false)
    }

    @Test func pathDeduplicatesAndRejectsColonDirs() {
        let base = ChildEnvironment.basePath.joined(separator: ":")
        #expect(ChildEnvironment.make(binaryDir: "/opt/homebrew/bin", parent: [:])["PATH"] == base)
        #expect(ChildEnvironment.make(binaryDir: "/weird:dir", parent: [:])["PATH"] == base)
    }
}
