# Assist spike — real CLI results (2026-10-01, user-approved ≤ 6 quick-model calls)

Budget: 6 real calls approved. Used: **5** (1 Claude failed locally at zero cost because the login had expired; 2 Codex success; 2 Claude success after the user signed in again). **1 remains** (spare).

## Codex (`codex-cli 0.153.4`, `gpt-5.6-luna`, reasoning effort low) — ✅ verified
- Turn 0 (synthetic bar-chart PNG via `--image=<path>` + text over stdin): success. Answer correctly read the image ("B > C > A"). First (whole) answer after **6.5 s**, total 7.5 s. Tokens: 6,302 in / 78 out (32 reasoning).
- Turn 1 (follow-up, context resent): success, "Bar B is the tallest." **3.5 s / 4.2 s**. 6,231 in (4,864 cached) / 10 out.
- `--json` delivers no deltas: one `item.completed{agent_message}` per turn (as designed — Codex answers appear whole).
- Every turn starts with a benign `item.completed{type:"error"}`: "Code Mode is unavailable because code-mode host is disabled…". This is caused by our intentional `--disable code_mode_host`; it must stay non-fatal (the parser already treats it so — outcome success).

## Claude (`claude 2.1.286`, `haiku`) — ✅ verified (after re-login, 2026-10-01 23:28)
- Turn 0 (synthetic bar-chart PNG as a base64 image content block + text, one stream-json user line over stdin, warm process): success, **20 text deltas** (`stream_event/content_block_delta` with `text_delta`), 310 chars, image read correctly. First token **4.6 s**, total 5.1 s. Usage 595 in / 546 out.
- Turn 1 (follow-up sent into the SAME open stream-json session): success, first token **1.26 s**, total 1.3 s, "Bar B is the tallest."
- **`total_cost_usd` (and usage) on each `result` line are CUMULATIVE for the session** (turn 0: 0.003325, turn 1: 0.004983). Per-turn cost/usage = the delta from the previous result line.
- Extra line types to ignore: `system/thinking_tokens`, `rate_limit_event`, `system/status`, `system/commands_changed`. Each turn has 2 content blocks (a thinking block and the text block) — only `text_delta` counts as answer text.
- Idle pre-started process (10 s): only `system/commands_changed`, no request, no usage → idle warm processes cost nothing.
- Raw recordings (synthetic figure, no personal data): scratchpad `spike/claude2/claude-turn{0,1,idle}.jsonl` — to be added as parser fixtures.

### Earlier attempt (login expired)
- The CLI's OAuth session had expired and could not be refreshed. `claude -p` answered locally: `system/init` (model claude-haiku-4-5, apiKeySource none, tools []), then an assistant message with model `<synthetic>` and zero usage, then a result line `subtype: "success", is_error: true, result: "Failed to authenticate: OAuth session expired and could not be refreshed"`, `total_cost_usd: 0`. No API request, no quota.
- Afterwards `claude auth status --json` → `loggedIn: false`. The user must run `claude` → `/login`.
- Fix landed: `ClaudeEnvelope.notLoggedInPattern` now matches "failed to authenticate", "oauth session expired", "could not be refreshed" (tests `ClaudeAuthExpiredTurnTests`, `ClaudeEnvelopeTests.stderrOnlyDiagnostics`).
- The items left open by this attempt (image block over stream-json, text_delta streaming, a follow-up in the same open session, the idle warm process costing nothing) were all verified after re-login — see the section above.
