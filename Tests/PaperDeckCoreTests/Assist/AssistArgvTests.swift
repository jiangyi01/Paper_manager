import Foundation
import Testing
@testable import PaperDeckCore

/// The assist command lines (dive-cli §3.1, §4.1; plan §4 "CLI argv"): no positional prompt for
/// Claude, `--tools ""` followed by a flag, stream-json both ways, no `--json-schema` /
/// `--fallback-model`; Codex without `--output-schema`, `--ephemeral`, the denylist kept, the
/// `--image=` form, the prompt last. The card argv is untouched (ArgvTests, unchanged).
@Suite struct AssistArgvTests {
    static func helpCaps(_ name: String, _ dir: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/\(dir)"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func claudeAssistArgvIsExactlyTheDesign() {
        let argv = ClaudeCodeProvider.assistArgv(binary: "/x/claude", model: "haiku", systemPrompt: "SYSTEM", effort: "low")
        #expect(argv == ["/x/claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--tools", "", "--strict-mcp-config", "--safe-mode",
                         "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk",
                         "--permission-prompts", "none", "--system-prompt", "SYSTEM", "--model", "haiku",
                         "--effort", "low", "--max-turns", "24"])
        // `--tools ""` is followed by a flag, so the variadic option can't swallow anything.
        let i = argv.firstIndex(of: "--tools") ?? 0
        #expect(argv[i + 1] == "" && argv[i + 2].hasPrefix("--"))
        for banned in ["--json-schema", "--fallback-model", "--resume", "--continue", "--mcp-config", "--dangerously-skip-permissions"] {
            #expect(!argv.contains(banned))
        }
        // No positional prompt: every value follows its own flag.
        let flagsWithValue: Set<String> = ["--input-format", "--output-format", "--tools", "--permission-mode",
                                           "--permission-prompts", "--system-prompt", "--model", "--effort", "--max-turns"]
        var j = 2
        while j < argv.count {
            #expect(argv[j].hasPrefix("--"), "positional at \(j): \(argv[j])")
            j += flagsWithValue.contains(argv[j]) ? 2 : 1
        }
    }

    @Test func claudeOptionalFlagsFollowTheCapabilities() {
        let caps = ClaudeCodeProvider.Capabilities(flags: Set(ClaudeCodeProvider.Capabilities.assistRequired))
        let argv = ClaudeCodeProvider.assistArgv(binary: "claude", model: "sonnet", systemPrompt: "-dash first", effort: "low",
                                                 capabilities: caps)
        for optional in ["--include-partial-messages", "--safe-mode", "--permission-prompts", "--effort"] {
            #expect(!argv.contains(optional))
        }
        // A value can never be read as an option.
        let s = argv.firstIndex(of: "--system-prompt") ?? 0
        #expect(argv[s + 1] == "System: -dash first")
        let m = ClaudeCodeProvider.assistArgv(binary: "claude", model: "--evil", systemPrompt: "x", effort: "--x")
        #expect(m[m.firstIndex(of: "--model")! + 1] == "haiku" && !m.contains("--x"))
    }

    @Test func theInstalledClaudeHelpHasEveryAssistFlag() throws {
        let caps = ClaudeCodeProvider.Capabilities.parse(help: try Self.helpCaps("claude-help-2.1.284", "agent"))
        #expect(caps.missingAssistRequired.isEmpty, "\(caps.missingAssistRequired)")
        #expect(caps.has("--include-partial-messages"))
        // An old CLI without stream-json input is refused by name.
        let old = ClaudeCodeProvider.Capabilities(flags: caps.flags.subtracting(["--input-format", "--verbose"]))
        #expect(old.missingAssistRequired == ["--input-format", "--verbose"])
    }

    @Test func codexAssistArgvIsTheIsolatedDesign() {
        let argv = CodexProvider.assistArgv(binary: "/x/codex", model: "gpt-5.6-luna", effort: "low", prompt: "PROMPT",
                                            agentCwd: "/cwd", lastMessagePath: "/jobs/assist-1/last.txt",
                                            imagePath: "/jobs/assist-1/shot.png",
                                            disabledFeatures: ["shell_tool", "view_image"], authCredentialsStore: "file")
        #expect(argv == ["/x/codex", "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--ephemeral",
                         "-C", "/cwd", "--sandbox", "read-only", "-m", "gpt-5.6-luna",
                         "-c", "model_reasoning_effort=\"low\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                         "-c", "cli_auth_credentials_store=\"file\"", "--disable", "shell_tool", "--disable", "view_image",
                         "--image=/jobs/assist-1/shot.png", "-o", "/jobs/assist-1/last.txt", "--json", "--color", "never",
                         "PROMPT"])
        #expect(!argv.contains("--output-schema") && !argv.contains("-i") && !argv.contains("--image"))
        #expect(argv.last == "PROMPT")
        let noImage = CodexProvider.assistArgv(binary: "codex", model: "sonnet", effort: nil, prompt: "-starts with dash",
                                               agentCwd: "/c", lastMessagePath: "/l", imagePath: nil)
        #expect(!noImage.contains { $0.hasPrefix("--image") })
        #expect(noImage.last == "Instructions:\n-starts with dash")
        #expect(noImage[noImage.firstIndex(of: "-m")! + 1] == CodexProvider.defaultModel)        // Claude alias → Codex default
        #expect(noImage.contains("model_reasoning_effort=\"low\""))
        // The default denylist is the card path's (view_image included).
        #expect(CodexProvider.Features.denylist.contains("view_image") && CodexProvider.Features.denylist.allSatisfy { noImage.contains($0) })
    }

    @Test func theInstalledCodexHelpHasEveryAssistFlag() throws {
        let caps = CodexProvider.Capabilities.parse(help: try Self.helpCaps("codex-exec-help-0.153.4", "codex"))
        #expect(caps.missingAssistRequired.isEmpty, "\(caps.missingAssistRequired)")
        let old = CodexProvider.Capabilities(flags: caps.flags.subtracting(["--ephemeral", "--image"]))
        #expect(old.missingAssistRequired == ["ephemeral", "image"])
    }

    @Test func theStdinLineCarriesTheImageFirstAndIsOneLine() throws {
        let png = AssistImage(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), mediaType: "image/png", pixelSize: CGSize(width: 2, height: 1))
        let line = ClaudeAssistSession.userLine(text: "<selection>a\nb</selection>", image: png)
        #expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil)
        let v = try JSONDecoder().decode(JSONValue.self, from: line)
        #expect(v["type"]?.stringValue == "user" && v["parent_tool_use_id"]?.isNull == true)
        let content = try #require(v["message"]?["content"]?.arrayValue)
        #expect(content.map { $0["type"]?.stringValue } == ["image", "text"])
        try #require(content.count > 1)          // no index past a failed expectation (QA-15)
        #expect(content[0]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(content[0]["source"]?["data"]?.stringValue == png.data.base64EncodedString())
        #expect(content[1]["text"]?.stringValue == "<selection>a\nb</selection>")
        let textOnly = try JSONDecoder().decode(JSONValue.self, from: ClaudeAssistSession.userLine(text: "q", image: nil))
        #expect(textOnly["message"]?["content"]?.arrayValue?.count == 1)
    }

    @Test func theDryRunShowsNoContentAndSpawnsNothing() throws {
        for provider in AIProviderKind.allCases {
            for surface in AssistSurface.allCases {
                let dry = AssistSmoke.dryRun(surface: surface, provider: provider, agentCwd: "/tmp/agent-cwd",
                                             parentEnvironment: ["HOME": "/Users/x", "ANTHROPIC_API_KEY": "k", "OPENAI_API_KEY": "k",
                                                                 "CLAUDE_CODE_OAUTH_TOKEN": "t", "PATH": "/evil"])
                #expect(AssistSmoke.leakedKeys(dry.environmentKeys).isEmpty)
                #expect(Set(dry.environmentKeys).isSubset(of: ChildEnvironment.keys))
                #expect(!dry.argv.contains { $0.contains("synthetic bar chart") || $0.contains("tallest") })
                #expect(dry.argv.first == provider.rawValue)                       // never a located path
                if provider == .codex {
                    #expect(dry.argv.contains("--image=<jobDir>/shot.png") == (surface == .explain))
                } else {
                    #expect(dry.stdinShape.contains("\"media_type\":\"image/png\"") == (surface == .explain))
                    #expect(!dry.stdinShape.contains("iVBOR"))                       // base64 is sized, not shown
                }
            }
        }
    }
}
