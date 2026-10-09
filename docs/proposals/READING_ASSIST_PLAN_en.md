# PaperDeck reading assist: engineering plan (execute only after the user approves PROPOSAL_zh.md)

Status: PLAN. Nothing has been implemented, built or run.

Inputs. Where this plan disagrees with them, **this plan wins** (see §2):
- `reading-assist/design-dedupe-qa.md` (cited **DQ**)
- `reading-assist/design-lens.md` (**LN**)
- `reading-assist/dive-cli.md` (**CLI**)
- `portability/design-architecture.md` (**PORT**)

Code references are `file:line` in the read-only snapshot `pd-port-snapshot/`.

Ground rules during execution:
- Development and tests use the mock provider only.
- The real-CLI spike (≤ 6 small-model turns, §9.2) runs only after the user says yes in chat.
- The user is running the installed app. Rebuild it only with `./build_app.sh`, **never `--dev`**: `--dev` forces `agent.mode off`, build_app.sh:147-151. Rebuild only at batch ends, and only with the user's OK.
- Quit the app before inspecting or changing preferences.
- Never read the user's library, App Support, CloudStorage or keychain without asking.

---

## 1. Decisions (PROPOSAL §"需要你决定的问题") and what each changes

| # | Default (recommended) | If the user picks the alternative |
|---|---|---|
| D1 "选取多少篇" | C: multi-select for batch actions **and** ask-across-N | A only: drop the Ask window (C3-b, −1.5 d). B only: keep the selection model, cut the batch bar to "Ask" and "Check duplicates" (−1.5 d). Something else: re-plan Slice C. |
| D2 AI judge | On click only (`dedupe.ai.auto = false`). "Likely" duplicates are committed **held**. | Auto on: build B4 (AgentQueue utility lane) in v1 (+1 d). Hold-back: likely hits take the parked path like certain hits (−0.5 d, but decisions are lost on restart, IntakeActor.swift:130-136). |
| D3 language | Explain `zh` with English terms. Q&A `auto` (follows the question's language). | `en`, or "follow UI" (UI default is English): only the default of `assist.explain.lang` changes. |
| D4 hotkey | ⌃⌥E, frame mode by default, Space toggles to the lens | Only defaults change. |
| D5 reader | Minimal PDFKit reader in v1, last batch (C4) | Skip: the Q&A PagePeek still ships, and LN M4 moves to v1.1 (−3 d). |
| D6 models / caps / storage | Explain = quick (haiku / gpt-5.6-luna). Q&A = quick too (haiku / gpt-5.6-luna, effort low; "Thorough" = sonnet / gpt-5.6-terra on request — proposal decision 6, approved). Soft cap 50/day across explain + Q&A. History in the DB only. | `qa.json` sidecar for non-confidential threads (DQ §6.4, +0.5 d, owned by C). Different caps or models change defaults only. |

---

## 2. Reconciliation: one shared core, one set of names

The three designs each invented their own interactive-AI plumbing. They are merged here, and the names below are final.

| Concept | DQ | LN | CLI | **Final** |
|---|---|---|---|---|
| Opt-in switch (independent of `agent.mode`) | `ai.interactive` | `explain.provider` | `assist.mode` | **`assist.mode` ∈ {off, claude, codex, local, mock}**, default `off`. `local` is offered only if spike S7 passes. |
| Per-gesture consent | `UserIntent` (10 s) | ticket (120 s) | `ConsentTicket` (30 s) | **`ConsentTicket`**: minted only in UI action handlers, single use, valid 60 s, consumed when the turn is written to the CLI |
| Gate | `AgentSpawnGate` lane | `ExplainGate` | `AssistGate` | **`AssistGate`** (new file). It shares the engine's `RunBudget` instance and the `agent.<p>.pausedUntil` keys. |
| Lane | `AgentQueue.runInteractive` | `ExplainRunner` | `AssistLane` | **`AssistLane`** actor, independent of the AgentQueue slot (AgentQueue.swift:1655-1661) |
| Streaming child | `ProcessRunner.run(onStdout:)` | `StreamingProcess` | `StreamingProcess` | **`StreamingProcess`**. `ProcessRunner.run` keeps its signature and behaviour for cards. |
| Follow-ups | stateless resend | warm session | live session, plus resend fallback | **Claude:** one live stream-json process per surface with `--no-session-persistence`; it falls back to a stateless resend after a crash, cancel or idle close. **Codex:** stateless resend with `--ephemeral`. **Never `--resume`.** |
| Concurrency | ≤ 2 children | own slot | 1, latest wins | ≤ **1 generating assist turn** app-wide; a new submit cancels the old one and keeps its partial text marked "stopped". ≤ **1 live/warm Claude assist process**. AgentQueue does not *claim* a new job while assist is busy, and a running card is never cancelled. So at most 2 CLI processes. |
| Daily limits | judge 10/day | soft 50 | hard 150 | `assist.dailySoftCap` = 50: confirm to continue, the override needs a fresh ticket. Hard 150 per provider per day. Burst ≤ 6 turns/min. The judge's auto mode has its own `dedupe.ai.dailyCap` = 10. |
| Gesture debounce | — | 600 ms lens | 1.5 s | 600 ms lens click, 1 s box release, plus one in-flight turn per panel |
| History | `qa_*` tables + `qa.json` | `explanation` table | — | Both tables, **DB only** (D6). |
| Confidential marker | `paper_policy` | `aiNote`/provenance | — | One pure **`AssistPrivacy.verdict`** used by Explain, Q&A and the judge. Inputs: `paper_policy` (confidential, never_ai), `aiNote == "mail_unpublished"` (Intake.swift:88), person-sourced provenance without ids (OperationsMail.swift:571-582), and the host app. |
| Judge transport | AgentQueue utility lane + `--json-schema` | — | — | v1 (on click): **AssistLane one-shot, text answer with "one JSON object only"**, tolerant parse, then `DupJudgeSanitizer`. The card path's `--json-schema` A/B tools machinery stays untouched. v1.1 auto mode: AgentQueue utility lane (DQ §3.6). |
| Persona in prompts | — | "PhD-level comp-bio reader" | — | `reader` string injected by a closure (§8, PORT §3.4). Core holds no field or org literal. |

---

## 3. Architecture

### 3.1 Module map (all new code; existing files only where listed in §6)

```
PaperDeckCore
  Assist/    shared interactive-AI core: models, gate, counter, lane, streaming, backends, prompts, sanitizer, privacy, BlockTags
  Explain/   OCR post-process, region classifier, paper locator, context builder, geometry, explain prompts
  QA/        QAService, context builder, ephemeral page index, estimator, citation parser, prompts
  Dedupe/    fingerprint, MinHash, title normalizer, detector, version rank, explainer, index, judge prompt + sanitizer, scan, merge planner
  Batch/     selection logic, select-N, batch operations, export (BibTeX / RIS / CSV / MD)
  DB/        SchemaAssist.swift (all new tables), Database+{Policy,Dedupe,QA,Explain}.swift
  Engine/    Operations{Policy,Dedupe,Batch,QA,Explain}.swift
PaperDeck (app, MainActor)
  Assist/    AssistUIModel, ConsentSheet, AssistBanner, StreamingTextView, QuotaFooter, ConfidentialAck
  Explain/   HotKeyCenter, CaptureOverlay*, ScreenCapturer, ScreenPermission, WindowContext,
             ExplainServiceProvider, ExplainCoordinator, ExplainPanel*, ExplainHistoryView
  Views/Dedupe/  DuplicateSheet, DuplicateBatchSheet, DuplicatesList, DuplicateRibbon, DuplicateChip, LibraryScanView, MergeSheet
  Views/Library/ SelectionBar, MultiInspector, SelectMenu (+ CardGridView / PaperContextMenu edits)
  Views/Detail/  DetailTabsHost, AskTab, ExplanationsSection
  Views/Ask/     AskWindowView     Windows/AskWindowController
  Reader/        PagePeek, ReaderRouter, ReaderWindowController, ReaderView, SelectionToolbar
  Views/Settings/ AssistSettingsTab, DedupeSettingsSection, QASettingsSection
  App/       L10n+{assist,explain,dedupe,qa,select}.swift, {Selection,Dedupe}UIModel.swift
```

No Package.swift change is needed. Vision, ScreenCaptureKit, NaturalLanguage, Accelerate, PDFKit, Carbon, Translation and FoundationModels are linked automatically when imported. PDFKit is already used by Core (PDFExtractor.swift:4). FoundationModels is guarded by `#if canImport(FoundationModels)`.

### 3.2 One assist turn, end to end

```
UI gesture ─▶ ConsentTicket.mint(gesture, surface)            (App action handler only)
          ─▶ surface builder (pure, Core): ExplainPrompt / QAContextBuilder / DupJudgePrompt → AssistRequest
          ─▶ AssistPrivacy.verdict(...)  → .ok | .confirm(reason) | .blocked(neverAI)
                 confirm → ConfidentialAck sheet (org policy text from the App adapter, §8) → the same ticket proceeds
          ─▶ AssistLane.submit(request, ticket) → AsyncStream<AssistEvent>
                 AssistGate.check(provider, ticket, surface, now)   (mode, ticket, pause, burst, caps, RunBudget)
                 backend: ClaudeAssistSession (live) | CodexAssistTurn (one-shot) | LocalAssistBackend | MockAssistBackend
          ─▶ UI coalesces .delta to ~30 Hz; .replace is authoritative; .done → AssistSanitizer → persist → counters
```

### 3.3 Resource model
- **Idle:** no timers, no OCR, no indexing.
- **CLI processes:** ≤ 2 (1 card + 1 assist). The warm Claude process is killed after 3 min idle (`assist.keepWarm`), on sleep, on quit, and when the provider or surface changes.
- **OCR:** detached, one capture at a time.
- **Dedupe:**
  - Intake adds ≤ 10 ms per paper (title_norm + MinHash).
  - Embeddings only at enrich or scan time.
  - The library scan backfills at 1 paper / 50 ms on a BlockingIO task, pauses in Low Power Mode, and can be cancelled.
- **Q&A:** the ephemeral page index is an in-memory FTS5 and is never persisted.

---

## 4. Shared core contracts (frozen in Slice 0; implementations per slice)

```swift
// Assist/AssistModels.swift (Slice 0)
package enum AssistMode: String, Sendable, CaseIterable { case off, claude, codex, local, mock }
package enum AssistSurface: String, Sendable { case explain, qa, dupJudge }
package struct ConsentTicket: Sendable, Hashable {
    package enum Gesture: String, Sendable { case box, lens, clipboard, service, drop, reader, ask, followUp, action, retry, judge, capOverride }
    package let id: UUID; package let gesture: Gesture; package let surface: AssistSurface; package let issuedAt: Date
    package static func mint(_ g: Gesture, surface: AssistSurface, now: Date = .now) -> ConsentTicket
}
package struct ArmingToken: Sendable { let issuedAt: Date }        // hotkey press; allows pre-spawn only, never a turn
package struct AssistImage: Sendable { let data: Data; let mediaType: String; let pixelSize: CGSize }   // png | jpeg, ≤1568 px long edge
package enum AssistResponseFormat: Sendable { case text, jsonInText }
package enum AssistSessionPolicy: Sendable { case oneShot, reuse(threadKey: String) }
package struct AssistLimits: Sendable { var firstTokenWatchdog: Duration; var turnTimeout: Duration; var maxOutputChars: Int }
package struct AssistRequest: Sendable {
    let surface: AssistSurface; let systemPrompt: String          // static per surface → cacheable
    let turnText: String                                          // neutralized blocks (BlockTags)
    let image: AssistImage?; let history: [AssistTurnText]        // history is used only by the stateless fallback
    let model: String; let effort: String?; let format: AssistResponseFormat
    let session: AssistSessionPolicy; let limits: AssistLimits
}
package struct AssistMeta: Sendable, Codable { provider; model; warm: Bool; turnIndex: Int; ttftMs: Int?; totalMs: Int;
                                               inputTokens: Int?; outputTokens: Int?; costUSD: Double? }
package enum AssistFailure: Sendable, Equatable { case refused(AssistGate.Verdict), usageLimit(resetsAt: Date?), notLoggedIn(ProviderReason),
    overloaded, timeout, cancelled, binaryMissing, unsupported(missingFlags: [String]), invalidOutput(String), generic(String) }
package enum AssistEvent: Sendable { case waiting(warm: Bool), phase(AssistPhase), delta(String), replace(String),
                                     done(text: String, meta: AssistMeta), failed(AssistFailure, partial: String?) }

// Assist/AssistGate.swift (Slice 0, full implementation; safety-critical, owned by the Lead)
package final class AssistGate: @unchecked Sendable {
    package enum Verdict: Sendable, Equatable { case allowed, disabled, wrongProvider, consentMissing, consentReused, consentExpired,
        paused(until: Date), burst, dailySoftCap(Int), dailyHardCap(Int), budgetExhausted, policyBlocked }
    package init(budget: RunBudget, load: @escaping @Sendable () -> EngineSettings,
                 pause: @escaping @Sendable (AIProviderKind) -> Date?, counter: AssistDailyCounter)
    package func checkTurn(_ p: AIProviderKind, ticket: ConsentTicket?, now: Date) -> Verdict   // consumes on .allowed
    package func checkSpawn(_ p: AIProviderKind, arming: ArmingToken?, now: Date) -> Bool        // pre-warm; consumes nothing
}

// Assist/AssistLane.swift (contract in Slice 0 with a Mock-backed stub; real implementation in Slice A)
package actor AssistLane {
    package func submit(_ r: AssistRequest, ticket: ConsentTicket) -> AsyncStream<AssistEvent>
    package func cancel(surface: AssistSurface)
    package func prewarm(_ arming: ArmingToken) async
    package func closeSession(threadKey: String) async
    package var isBusy: Bool { get }
    package func status() async -> AssistStatus          // provider detected / logged in / paused until / today's count
}

// Assist/AssistPrivacy.swift (Slice 0). Pure. Reason codes only; no institution text in Core (PORT §2.1 rule 1).
package enum AssistPrivacy {
    package enum Reason: String, Sendable { case markedConfidential, mailUnpublished, personSourcedNoID, messagingHost }
    package enum Verdict: Sendable, Equatable { case ok, confirm([Reason]), blocked }   // blocked = never_ai
    package static func verdict(policy: PaperPolicy?, aiNote: String?, provenance: [PaperSourceSummary], hostBundleID: String?) -> Verdict
}
// Assist/BlockTags.swift (Slice 0). Generalizes CardSchema.swift:190-198 WITHOUT editing CardSchema.swift
package enum BlockTags { static func neutralize(_ s: String, tags: Set<String>) -> String }
//   tags: paper, paper_meta, paper_context, context, selection, excerpt, ocr_hint, history, question, task,
//         metadata, card, conversation, new, candidate, stdin
```

Surface APIs. Contracts are in Slice 0; the stubs return mock data.

```swift
// Explain (A)
@MainActor final class ExplainCoordinator { func begin(capture: ExplainCapture, ticket: ConsentTicket); func arm(mode: OverlayMode) }
package enum ExplainOps { /* Engine ext */ locatePaper(_:) ; paperContext(_:budget:) ; saveExplanation(_:) ; explanations(paperID:limit:) ;
                          appendExplanationToNotes(id:) ; setExplanationPinned(id:_:) ; pruneExplanations(olderThan:) }
// Q&A (C)
package actor QAService { threads(paperID:) ; newThread(paperIDs:mode:) ; estimate(threadID:question:options:) ;
                          ask(threadID:question:options:ticket:) -> AsyncStream<QAEvent> ; cancel(threadID:) ; saveToNotes(messageID:) ; deleteMessage(id:) }
@MainActor protocol ReaderRouting { func open(paperID: String, page: Int?, highlight: String?) }   // PagePeek in C2, reader in C4
@MainActor enum AskRouter { static func ask(paperIDs: [String], prefill: String?) }                 // detail tab (1) or window (≥2)
// Dedupe (B)  — DQ §9 signatures, plus:
func askDuplicateJudge(reviewID: String, ticket: ConsentTicket) async -> DupReview     // through AssistLane (.dupJudge, .oneShot, .jsonInText)
@MainActor final class DedupeUIModel { func handle(_ e: EngineEvent) -> Bool; func checkSelected(ids: [String]); var openCount: Int }
// Batch (C)  — DQ §5.4: applyBatch(_ op: BatchOperation, paperIDs:) -> BatchOutcome (one txn + one UndoToken)
@MainActor final class SelectionModel { var ids: Set<String>; var anchor: String?; var focused: String? /* = AppState.selectedPaperID */ }
```

Turn parameters (final):

| Surface | Model (Claude / Codex) | Context cap | First-token watchdog | Turn timeout (Claude / Codex) | Output cap | Session |
|---|---|---|---|---|---|---|
| explain | haiku / gpt-5.6-luna, effort low (deep = sonnet / terra) | stdin ≤ 6,000 chars (3k/6k/12k); 1 image ≤ 1568 px | 20 s → "still waiting" | 90 s / 150 s | 6,000 chars | reuse per panel; 12 turns; 10 min idle |
| qa | haiku / gpt-5.6-luna, effort low (thorough = sonnet / terra) | 80,000 chars; multi = 100k/N, full text only if N ≤ 3 | 30 s | 180 s / 300 s | 20,000 chars | reuse per thread while the tab is open |
| dupJudge | haiku / luna, effort low | ~2–4 k tokens (≤ 3 candidates) | — | 90 s / 240 s | 4,000 chars | oneShot |

CLI argv: Claude as in CLI §3.1. Codex as in CLI §4.1, using `--image=<jobDir>/shot.png` (the `=` form, so the variadic flag cannot swallow the prompt), `-o last.txt`, `--json`, and no `--output-schema`. Content travels on stdin only, never in argv. The env comes from the existing `ChildEnvironment.make` / `environment(for:)` (ClaudeCodeProvider.swift:448), so PORT P7's config-dir injection also applies to assist.

---

## 5. Data model (Slice 0; one additive feature migration)

- `Migrations.swift`:
  - Add `case 3` that creates every table below and writes `schema_feature('assist', 1)`.
  - Set `latestVersion = 3`.
  - `level()` returns 3 when `featureVersion('assist') ≥ 1` and throws `newerSchema` when it is > 1. This mirrors mail (Migrations.swift:109-129, 163-168, 206-226).
- `user_version` stays 1. An older build's `level()` reads only the `mail` row, so it still opens the library and ignores the new tables.
- `PRAGMA foreign_keys = ON` (Migrations.swift:59) means the `ON DELETE CASCADE` rules still apply when an old build hard-deletes a paper.
- The pre-migration backup runs as for any migration (Migrations.swift:92-95).

| Table | Owner (writes) | DDL source | Notes |
|---|---|---|---|
| `paper_key` | B | DQ §8 | preprint ↔ published aliases, OpenAlex, DataCite arXiv DOI |
| `paper_fingerprint` | B | DQ §8 | recomputable; rechecked against `paper.updated_at` |
| `paper_history` | B | DQ §8 | tombstones written inside `hardRemove`; metadata only |
| `dup_review`, `dup_pair` | B | DQ §8 | `held_schedule_json` restores scheduling |
| `reading_cycle` | B (written by "re-read earlier"); C reads it for the multi-inspector | DQ §8 | |
| `paper_policy` | Slice 0 (OperationsPolicy); UI toggle in the inspector, Lead | DQ §8 | confidential, never_ai |
| `qa_thread`, `qa_thread_paper`, `qa_message` | C | DQ §8 | rows still `streaming` at launch are set to `cancelled` |
| `explanation` | A | LN §7.6, changed | `source IN('services','clipboard','screenshot','region','lens','reader','drop')`; follow-ups are `turn > 0` (drop `followup` / `paper_qa`). Excerpt ≤ 2,000 chars. Unpinned, unsaved rows pruned after 90 days by Maintenance. |

The CHECK lists are frozen once shipped; widening one needs `('assist', 2)`. In v1 the sidecar (`card.json`) gains only `policy` (Slice 0) and `readingCycles` / `distinctFrom` (B), all optional and written only when non-empty (Sidecar.swift:4-15). There is no `qa.json` in v1 (D6).

**Settings keys.** Added in Slice 0 to `EngineSettings` (EngineSettings.swift:14-40) and `SettingsStore` (SettingsStore.swift:117-134):

| Key | Default | Exported by PORT settings export? |
|---|---|---|
| `assist.mode` | off | **never**, like `agent.mode` |
| `assist.consentVersion` | 0 | never |
| `assist.dailySoftCap` / `assist.dailyHardCap` | 50 / 150 | yes |
| `assist.keepWarm` | 180 s | yes |
| `assist.explain.lang` | zh (D3) | yes |
| `assist.explain.depth` / `assist.qa.depth` | quick / quick | yes |
| `assist.explain.level` | student | yes |
| `assist.explain.contextChars` | 6000 | yes |
| `assist.explain.hotkey` | {keyCode E, ⌃⌥} | yes |
| `assist.explain.defaultMode` | frame | yes |
| `assist.explain.askBeforeSend` | false | yes |
| `assist.explain.historyDays` | 90 | yes |
| `assist.qa.lang` | auto | yes |
| `assist.qa.textBudget` | 80000 | yes |
| `assist.qa.multiMax` | 10 | yes |
| `assist.model.{claude,codex}.{quick,thorough}` | haiku/sonnet, gpt-5.6-luna/gpt-5.6-terra | yes |
| `dedupe.enabled` | true | yes |
| `dedupe.sensitivity` | balanced | yes |
| `dedupe.history` | true | yes |
| `dedupe.ai.auto` | false | **never** |
| `dedupe.ai.dailyCap` | 10 | yes |
| `pdf.opener` | gains `"paperdeck"` (C4); default stays `preview` | existing |

Counters live in kv rows, not exported: `assist.count.<day>.<provider>`, `dedupe.ai.count.<day>`.

`build_app.sh --dev` also writes `assist.mode off` and `dedupe.ai.auto false`. This is one edit in the block at build_app.sh:147-151.

---

## 6. Slices, ownership and contracts

### 6.0 Protocol
- There are four workstreams: **Lead** (Slice 0 + integration), **A**, **B**, **C**.
- Each agent works in its own worktree or copy, based on the Slice 0 commit.
- A file has exactly one owner. Any change to another owner's file goes through a change request to that owner. Lead-owned shared files change only through the Lead.
- Merge order at each batch end: Lead → A → B → C. After each merge, `./test.sh` must be green.
- Shared UI insertion points are **slot views** that Slice 0 creates in the owning slice's file. For example, `DuplicateRibbon(row:)` lives in `Views/Dedupe/DuplicateRibbon.swift` and returns `EmptyView` until B fills it, so B never edits `PaperCardView.swift` again.
- `AppState` stored properties can't live in extensions. Slice 0 therefore adds `let selection = SelectionModel()`, `let dedupe = DedupeUIModel()` and `let assist = AssistUIModel()`. Each slice owns its model's file.

### 6.1 Slice 0: contracts and skeleton (Lead, about 1 day, blocks everyone)

Owns permanently, as shared files; changes go through the Lead:
- `DB/Migrations.swift`, `DB/SchemaAssist.swift`, `DB/Database+Policy.swift`, `Engine/OperationsPolicy.swift`, `Models/PaperPolicy.swift`
- `Assist/AssistModels.swift`, `Assist/AssistGate.swift`, `Assist/AssistDailyCounter.swift`, `Assist/AssistPrivacy.swift`, `Assist/BlockTags.swift`, `Assist/MockAssistBackend.swift`
- `Engine/EngineSettings.swift`, `Engine/EngineEvents.swift` (new event cases for dedupe, batch undo and assist status), `Engine/Engine.swift` (wiring)
- `Agent/AgentQueue.swift`, edited only for:
  - the yield hook `assistBusy: @Sendable () -> Bool`, checked before a job is claimed (around AgentQueue.swift:607-622);
  - `pause(for:)` and `recordUsageLimit(kind:resetsAt:)`, next to `setPause` (CLI §1)
- `App/AppState.swift`:
  - the 3 model properties;
  - `RecentOpens` push in `openPDF` (AppState.swift:345-358);
  - event forwarding to `dedupe.handle` before the existing `.replaceKeepingChecklist` handling (AppState.swift:284)
- `App/SettingsStore.swift`, `App/AppDelegate.swift`: the install hooks `ExplainBootstrap.install()`, `NSApp.servicesProvider` and lane start
- `Windows/SettingsWindowController.swift`: `SettingsTab.assist`, coordinated with PORT `.profile` (§8)
- `Windows/LibraryWindowController.swift`: menu items wired to stub actions:
  - Edit ▸ Select All / Select ▸ …
  - Library ▸ Check for Duplicates…
  - Explain ▸ Explain… / Explain Copied Text / History
- `Windows/StatusBarController.swift`: an `appendAssistItems(to:)` helper call near StatusBarController.swift:220-230
- `Views/Detail/PaperDetailView.swift`: wraps content in `DetailTabsHost` (Overview | Ask), and adds the `ExplanationsSection` and `DuplicateChip` slots plus the inspector "Unpublished / confidential" and "Never use AI" toggles
- `Views/Components/PaperCardView.swift`: the `DuplicateRibbon` slot
- `Views/Settings/SettingsView.swift`: the `pdfOpener` picker gains an option slot (SettingsView.swift:65)
- `Views/Settings/LibrarySettingsTab.swift`: the `DedupeSettingsSection` slot
- `Resources/Info.plist`: two `NSServices` entries (LN §9.2)
- `build_app.sh`: the `--dev` line
- Tests: `Tests/PaperDeckCoreTests/AssistContracts/`

Delivers:
- Every type and signature in §4.
- `AssistLane` stub backed by `MockAssistBackend`, so B and C can build their UIs on day 1.
- Slot views in each slice's own files.
- The migration with tests.
- Contract tests:
  - `ConsentTicket.mint` appears only in an allowlist of App action-handler files.
  - No `StreamingProcess.spawn` call site bypasses `AssistGate`.
  - `CGRequestScreenCaptureAccess` is called only in `ScreenPermission.swift`.
  - No `WashU` literal in the new `L10n+*` or Core files.
  - Info.plist has `NSServices`.
  - The build_app.sh `--dev` block writes `assist.mode off`.
  - `CardSchema.swift` and `ProcessRunner.run`'s signature are unchanged; the existing ArgvTests still pass.

Acceptance: `./test.sh` and `--selftest` green; a migration test on a level-2 fixture DB checks `user_version == 1`, the `mail` row unchanged and the `assist` row = 1.

### 6.2 Slice A: assist backends + Explain Lens (Agent A, about 10.5 days)

| Area | Files owned |
|---|---|
| Streaming | `Agent/ProcessRunner.swift`: streaming mode inside `SpawnedChild`, with `drain` → `LineSplitter`, `pump`/`closeInput` suspend/resume, interactive grace 2 s/2 s (ProcessRunner.swift:87-384). `run` is unchanged. Also `Assist/StreamingProcess.swift`, `Assist/LineSplitter.swift`. |
| Backends | `Assist/ClaudeStreamParser.swift`, `Assist/ClaudeAssistSession.swift`, `Assist/CodexAssistEvents.swift`, `Assist/CodexAssistTurn.swift`, `Assist/LocalAssistBackend.swift`, `Assist/AssistLane.swift` (the real one, replacing the stub behind the same API), `Assist/AssistSanitizer.swift` (reuses CardSanitizer's control / bidi stripping, CardSanitizer.swift:334-341) |
| Provider edits (minimal) | `Agent/ClaudeCodeProvider.swift`: `checkAuth` / `capabilities` / `environment(for:)` / `ensureAgentCwd` go from `private` to `package` (:180, :232, :448, :452); add a static `assistArgv` and an `assistRequired` flag set. **No logic change to the card path.** `Agent/CodexProvider.swift`: the same pattern. `Agent/ClaudeEnvelope.swift`: + `classifyTurn` (empty stdout passed to the failure table, CLI §3.3). `Agent/CodexEvents.swift`: + `item.updated`, split out `classifyFailure`. |
| Explain Core | `Explain/OCREngine.swift`, `OCRPostProcess.swift`, `RegionClassifier.swift`, `PaperLocator.swift` (+ `WindowTitle.normalize`), `PaperContextBuilder.swift`, `ExplainPrompt.swift`, `CaptureGeometry.swift`, `PanelPlacement.swift`; `DB/Database+Explain.swift` (+ `fullTextCandidates`, following the Database+Mail.swift pattern); `DB/FTSQuery.swift` (+ `anyOf`, additive); `Engine/OperationsExplain.swift` |
| App | `Assist/*` (shared views; signatures fixed in Slice 0), `Explain/*`, `Views/Detail/ExplanationsSection.swift`, `Views/Settings/AssistSettingsTab.swift` (C supplies `QASettingsSection` as a subview), `App/L10n+assist.swift`, `App/L10n+explain.swift`, `Drop/DropIntake.swift` (route all-image drops to Explain; PDFs unchanged, DropIntake.swift:22-24) |
| CLI | `CLI/CLIRunner.swift`: `--assist-argv` dry run, and `--assist-smoke --yes --max-runs N`, which refuses without `--yes` and caps at 6. `CLI/PreviewRenderer.swift`: explain and assist states. |
| Tests | `Tests/PaperDeckCoreTests/Assist/`, `Explain/`, `Fixtures/assist/` (JSONL), `Fixtures/explain/` (OCR line fixtures) |

Milestones:
- **A0** (day 1): the spike, §9.2.
- **A1** (3 d): streaming, parsers, sessions, lane, sanitizer, the real gate wiring, explanation DB and ops.
- **A2** (2.5 d):
  - panel UI and states, consent sheet;
  - hotkey and overlay with the clipboard offer only;
  - Services, menu bar, image drop;
  - Settings tab, L10n en/zh, history section, `--render` states.
- **A3** (2.5 d): frame and lens visuals, SCK capture, permission flow and explainer, Vision OCR, block-at-point, figure path, window-title and text matching, multi-display hardening.
- **A4** (1.5 d): reader integration (the selection toolbar calls `ExplainCoordinator.begin` with an exact `readerAnchor`), edge cases (LN §12), a DESIGN.md "讲解" section, and amendments to DESIGN.md:62 and §12 (reader, OCR and Services move from v2 to v1).

### 6.3 Slice B: dedupe (Agent B, about 8 days in v1, plus about 3.5 later)

| Area | Files owned |
|---|---|
| Core | `Dedupe/*` (DupFingerprint, MinHash, TitleNormalizer, DupDetector, VersionRank, DupExplainer, DedupeIndex, DupJudgePrompt, DupJudgeSanitizer; later LibraryScan, MergePlanner, Embedder), `DB/Database+Dedupe.swift`, `Engine/OperationsDedupe.swift` |
| Existing (B only) | `Import/IntakeActor.swift`: fingerprint after extraction; certain → parked + review; likely → held commit with the review **in the same DB call**; possible → normal commit + review (DQ §3.7; IntakeActor.swift:436-452, 494-503). `Import/EnrichActor.swift`: L1/L2a re-run, aliases, the review replaces the lookalike toast, AI job held while a review is open (EnrichActor.swift:185-247, 508). `Metadata/MetadataClients.swift`: `has-preprint`, `is-version-of`, OpenAlex id (MetadataClients.swift:285-287). `Engine/OperationsFiles.swift`: tombstone in `hardRemove` before `hardDelete` (OperationsFiles.swift:106-125). `Engine/OperationsMail.swift`: only the same-work merge branch (OperationsMail.swift:570-582). |
| App | `Views/Dedupe/*`, `App/DedupeUIModel.swift`, `Views/Library/SidebarView.swift` (Duplicates row), `Views/Settings/DedupeSettingsSection.swift`, `App/L10n+dedupe.swift`, `Views/Mail/MailMergePopover.swift` (shows the match before merging) |
| CLI | `--dedupe-report --root LIB`: local only, no AI. Run it on the user's library only with their OK. |
| Tests | `Tests/PaperDeckCoreTests/Dedupe/`, `Fixtures/dedupe/pairs.json` (about 40 pairs, DQ §7) |

Milestones:
- **B1** (4.5 d): fingerprint, MinHash and normalization; detector, version rank, guards and explanations en/zh; aliases; tombstones; intake and enrich hooks.
- **B2** (3 d): resolution engine (4 choices × {parked, held, soft-deleted, tombstone}); decision sheet; ribbon, chip and sidebar; undo.
- **B3** (1 d, needs A1): batch review sheet, mail popover, **judge on click** through `AssistLane`.
- **B4** (later, 3.5 d): L3 `NLEmbedding` + vDSP kNN; library scan + union-find; merge tool; optional auto judge in the AgentQueue utility lane, which needs a Lead change request for AgentQueue.swift.

**Compatibility rule.** With `dedupe.enabled = false`, today's 2-button toast flow is unchanged (`replaceKeepingChecklist` / `ignorePending`, EngineEvents.swift:52-53).

### 6.4 Slice C: selection, batch, Q&A, reader (Agent C, about 11.5 days)

| Area | Files owned |
|---|---|
| Core | `Batch/SelectionLogic.swift`, `Batch/SelectN.swift`, `Batch/BatchOperation.swift`, `Batch/Export.swift`, `Engine/OperationsBatch.swift` (one txn + one UndoToken; the undo ledger follows the `skipToday` pattern, OperationsSchedule.swift:75-134), `QA/QAService.swift`, `QA/QAContextBuilder.swift`, `QA/EphemeralPageIndex.swift`, `QA/QAEstimator.swift`, `QA/QACitations.swift`, `QA/QAPrompts.swift`, `DB/Database+QA.swift`, `Engine/OperationsQA.swift` |
| App | `App/SelectionModel.swift`, `Views/Library/CardGridView.swift` (gestures and selection bar overlay; CardGridView.swift:48-72), `Views/Library/PaperContextMenu.swift` (`rows:` variant, PaperContextMenu.swift:32-148), `Views/Library/LibraryToolbar.swift` (Select ▾), `Views/Library/SelectionBar.swift`, `MultiInspector.swift`, `SelectMenu.swift`, `Views/Detail/AskTab.swift`, `Views/Ask/*`, `Windows/AskWindowController.swift`, `Reader/*`, `Views/Settings/QASettingsSection.swift`, `App/L10n+qa.swift`, `App/L10n+select.swift` |
| Tests | `Tests/PaperDeckCoreTests/Batch/`, `QA/` |

Milestones:
- **C1** (2.5 d): selection logic and gestures (with the AppKit click-catcher fallback for `LazyVGrid`), Select-N, the bar, the multi-inspector, batch ops + undo, export, the multi context menu. "Check duplicates" calls `DedupeUIModel.checkSelected`; "Re-read with AI" shows a confirm sheet and then enqueues ordinary card jobs.
- **C2** (4.5 d, needs A1; builds against the mock from day 1):
  - context builder with question-aware page selection;
  - QAService;
  - persistence and crash recovery;
  - Ask tab with streaming Markdown, citation chips, the estimate line, suggested questions;
  - PagePeek (PDFKit single page plus `findString` highlight; physical-page vs printed-label chip).
- **C3** (1.5 d): Ask window for ≥ 2 papers, with cards / excerpts / full-text modes.
- **C4** (3 d, D5): minimal reader (LN §8): `ReaderWindowController` (as in LibraryWindowController.swift:87), `PDFView` + thumbnails, find bar, page memory, selection mini-toolbar (Explain · Terms · Translate · Ask), ⌘-drag box, `pdf.opener = "paperdeck"`. `ReaderRouting` switches from PagePeek to the reader.

### 6.5 Cross-slice dependency graph

```
Slice 0 ──▶ A1 ──▶ A2 ──▶ A3 ──▶ A4 (needs C4)
       ├──▶ B1 ──▶ B2 ──▶ B3 (needs A1) ──▶ B4 (v1.1)
       └──▶ C1 ──▶ C2 (needs A1) ──▶ C3 ──▶ C4
Batch 1 = A1+A2, B1+B2, C1  |  Batch 2 = A3, B3, C2  |  Batch 3 = A4, C3+C4, (B4)
```

---

## 7. UI states

- **AssistBanner** (shared, shown on every assist surface). States:
  - `off` → [Turn on Explain & Ask]
  - `needsConsent` → first-use sheet (versioned)
  - `notInstalled`
  - `notLoggedIn(reason)` → "run `claude /login`", reusing `ProviderReason.text` (AgentProvider.swift:141-173)
  - `paused(until)` → "Resets 3:45 pm — switch to ChatGPT / on-device?"
  - `softCap(n)` → [Continue] (mints a `capOverride` ticket)
  - `hardCap`
  - `confidential(reasons)` → ack checkbox with the org policy text
  - `blocked(neverAI)`
- **ExplainCoordinator.phase**: `idle → arming(mode, clipboardOffer?, captureAllowed) → capturing → preparing(.ocr|.locating) → needsConfirmation(reason) | blocked(reason) → starting(provider, since) → streaming(partial) → done(record) | failed(kind, partial?)` (LN §7.5). Esc cancels from any state; the next capture replaces an unpinned panel.
- **Ask message.** User message: `composing → estimating → sending`. Assistant message: `streaming → done | failed(kind) | cancelled`. Citations are `valid | invalid (greyed)`. Thread: `active | archived`.
- **Duplicate review.** Review `state`: `open → resolved | expired | dismissed`. Paper card: `normal | held (ribbon "Duplicate?") | possible (inspector chip only)`. Sheet: `loading evidence → ready → judging (AI) → ready → applying → done (toast + Undo 30 s)`.
- **Selection.** 0 → nothing; 1 → the normal inspector; ≥ 2 → selection bar + multi-inspector; the context menu acts on the selection. View change → prune to visible rows.
- **Reader** (C4): `loading → reading(page) → selection(toolbar) | boxMode`. Page memory is restored on open.

---

## 8. Integration with the ongoing portability refactor (PORT)

| Area | PORT change | This plan | Rule / owner |
|---|---|---|---|
| Package.swift | adds the `PaperDeckConfig` target (PORT §2.2) | no change | none |
| Org policy text | `OrganizationProfile.policy` + `OrgStrings` (PORT §3.3, §6.2) | Core returns `AssistPrivacy.Reason` codes only. The App renders the text through **one adapter**, `Assist/AssistPolicyText.swift`: today it uses the existing L10n WashU strings, after PORT P1 it uses `ConfigStore.organization.policy` (`policyNote`, `approvedAITools`). | Contract test: no `WashU` literal in new files. Lead swaps the adapter when P1 lands. |
| Consent floor | `ConsentDefaults`, clamped stricter-only | optional later field `assistConfidential: ask \| never`, so an org pack can forbid sending unpublished manuscripts; never `always` | after PORT P1; Lead |
| Field persona | `CardPromptProfile.reader` via `Engine.Dependencies.loadCardProfile` (PORT §3.4) | explain, Q&A and judge prompts take `reader: String` from an injected closure. Before P2 it returns the legacy comp-bio persona; after P2, `loadCardProfile().reader`. **Do not edit `CardSchema.swift`**: about 20 tests pin it and PORT T2 golden-tests it. | Lead wires the closure in `Engine.swift` |
| Settings tabs | `.profile` added (SettingsWindowController.swift:40-52) | `.assist` added | order: general, profile, plan, ai, assist, mail, library, widget; whoever lands second rebases |
| Settings export / org packs | `SettingsRegistry` allowlist (PORT §6.10) | register the keys in §5; `assist.mode`, `dedupe.ai.auto`, counters, pause keys and `assist.consentVersion` are **never exported**; a pack can never enable AI | Lead adds them after PORT P5 |
| Help center | Help window, topics, `paperdeck://help/<topic>`, contextual "?" (PORT §7.4) | new topics `explain`, `screen-recording`, `ask`, `duplicates`, `multi-select`; "?" in AssistSettingsTab, the Screen Recording explainer and DuplicateSheet | A writes explain/ask/screen-recording, B writes duplicates, C writes multi-select, all after PORT P6; until then the "?" links are hidden |
| Feature tour / Getting Started | tour pre-dismissed for legacy installs | optional tour page "Explain anything (⌃⌥E)" and a checklist item "Try Explain", new installs only; **never** auto-show for this user | after P6 |
| Menus | Help menu in LibraryWindowController.swift:173-205; menu-bar item in StatusBarController.swift:193-229 | our items go in separate helper functions (`appendAssistItems`, `appendDedupeItems`), one call line each | Lead merges; small hunks |
| Build identity | `BuildIdentity`, PD* keys stamped into the **staged** plists; build_app.sh around :73/:85 | `NSServices` stays static in `Resources/Info.plist`; the TCC Screen Recording grant follows bundle id + signing DR (DESIGN.md:207-209), which PORT keeps unchanged for this user; our build_app.sh edit is the `--dev` block only (:147-151) | if PORT ever stamps a display name, stamp the Services menu title too (later) |
| AI accounts | `agent.claudeConfigDir` / `codexHome`, per-account pause (PORT P7) | assist sessions take env from the same `environment(for:)` and read the same pause accessors; A changes only the visibility of those helpers | merge-safe: there is no second copy of the env logic |
| Migrations | starter-pack / library identity (PORT P4, Migrations.swift:209-217 area, `Library/LibraryIdentity.swift`) | `case 3`, `latestVersion`, `level()` (different hunks) | Lead rebases |
| Setup Assistant / Welcome | row 0 "About you"; Welcome for fresh installs | no new row; one sentence in the AI row: "Explain & Ask is a separate, optional switch" | after P6 |

---

## 9. Tests and verification

### 9.1 Automated (Swift Testing via `./test.sh`; mock only; no quota)

- **Slice 0 / contracts.** Gate verdicts:
  - off;
  - wrong provider;
  - missing, reused or expired ticket;
  - pause;
  - burst;
  - soft and hard cap;
  - budget;
  - independence from `agent.mode`;
  - the connection-test allowance is unaffected.

  Also: ticket single use; migration levels 1 → 3 and 2 → 3; an older-build simulation (the `mail` row is read and the `assist` row ignored); `paper_policy` CRUD; the `AssistPrivacy` table; `BlockTags` neutralization for every tag; the grep contracts in §6.1.
- **A.**
  - `ProcessRunnerStreamingTests` (a `/bin/sh` fixture child; chunk order; cancel escalation; `run` unchanged);
  - `LineSplitter` with random chunk splits and oversize lines;
  - `ClaudeStreamParser` fixtures (deltas, `message_start` restart, `assistant` replace, result success / error / 429 / not-logged-in);
  - Codex events (`item.updated` as replace);
  - argv tests (no positional prompt; `--tools ""` followed by a flag; `--image=` form; prompt last; denylist kept; no API-key env);
  - lane with the mock (cancel mid-stream, latest-wins, warm idle kill with an injected clock, stateless fallback after a crash);
  - OCRPostProcess (two-column, de-hyphenation, ligatures, CJK join, `block(at:)`, metrics);
  - RegionClassifier table;
  - PaperLocator (`WindowTitle.normalize` table; containment on the perturbed layout fixtures `Fixtures/pdf/{arxiv,cell,nature}_layout.txt` with a negative control; `FTSQuery.anyOf` injection safety);
  - ExplainPrompt (budgets UTF-8 safe; raw window title never present);
  - CaptureGeometry / PanelPlacement (displays left of / above main, mixed scale);
  - explanation DB (insert / list / prune, `ON DELETE SET NULL`, the notes-append format).
- **B.** DQ §7 in full:
  - TitleNormalization, MinHash, `DupDetectorFixtureTests`. Acceptance: **zero false `certain`**, ≤ 1 false `likely`, recall ≥ 90 % on true version pairs that have metadata.
  - `has-preprint` parsing.
  - `DupIntakeTests`: certain / likely / possible; review in the same transaction (crash seam); tombstone hit.
  - `DupResolutionTests` (4 × 4 matrix, `ux_doi` safe), `DupBatchTests`, `MailMergeDedupeTests`.
  - `DupJudgeTests`: tolerant JSON parse, sanitizer clamps, band transitions, refused when `assist.mode` is off, never automatic for confidential papers.
  - Intake latency: added work < 10 ms per paper on fixtures.
- **C.**
  - SelectionLogic (click / ⌘ / ⇧ across DDL groups; prune), Select-N, BatchOperation (one txn, undo restores, user changes respected), Export (BibTeX keys, escaping, RIS / CSV round trip).
  - `QAContextBuilder`: the prefix is **byte-identical across follow-ups**; page selection keeps the abstract and the order and respects the budget; multi-paper budgets.
  - Citations regex and invalid pages; QA persistence (streaming → done / cancelled; crash recovery); estimator.
- **Render checks** (`--render OUT --root FIXTURE_LIB`, mock, offscreen; PreviewRenderer.swift:4-9), in en/zh × light/dark:
  - explain panel in every phase;
  - overlay frame and lens over a fixture page;
  - consent and confidential sheets;
  - Assist settings tab;
  - duplicate sheet and batch sheet, ribbon and chip;
  - selection bar and multi-inspector;
  - Ask tab while streaming;
  - Ask window;
  - PagePeek;
  - reader.
- **Dry runs:** `--assist-argv explain|qa|judge` prints the argv with content redacted; `--selftest` gains assist and dedupe sections, mock only.

### 9.2 Spike (A0, day 1)

No-quota checks, run freely:

| ID | Check |
|---|---|
| S1 | `claude --help` / `codex exec --help` / `codex exec resume --help` list the needed flags; record the result in `CLIFactStore` |
| S2 | Carbon `RegisterEventHotKey` under `.defaultIsolation(MainActor)`: compiles and fires; `eventHotKeyExistsErr` path |
| S3 | ScreenCaptureKit region capture with own-window exclusion; negative-origin display; Retina scale |
| S4 | Services appear for an `LSUIElement` app (Info.plist:25) after `NSUpdateDynamicServices()` |
| S5 | Vision `RecognizeTextRequest` timing (and `RecognizeDocumentsRequest`) under the CLT SDK |
| S6 | `NLEmbedding.sentenceEmbedding(for: .english)` is non-nil; timing |
| S7 | `import FoundationModels` compiles and reports availability on this Mac |
| S8 | `Translation` session API under the CLT SDK |

Quota checks: **only after an explicit yes from the user in chat**, through `--assist-smoke --yes --max-runs 6`, haiku / luna, with contentless fixtures recorded:

| ID | Check |
|---|---|
| Q1 | Claude stream-json turn with an image block: `text_delta` arrives, the `result` line parses, `--verbose` requirement |
| Q2 | A follow-up on the same process: no cold start, cache read > 0, `--max-turns` semantics |
| Q3 | Idle pre-spawned process for 60 s: no usage movement (checked with ClaudeUsageBar before and after). If usage moves, pre-warm is limited to the auth check. |
| Q4 | Codex `--image=` with `view_image` disabled; event types (is `item.updated` present?) |
| Q5–Q6 | Reserve, for a retry or one Q&A turn |

### 9.3 Manual matrix (Batch 2 and 3 builds; the user's OK required to install)

- **Hosts:** Preview, Acrobat Reader, Skim, Safari PDF, Chrome PDF, PaperDeck reader.
- **Window modes:** windowed and full screen; Stage Manager.
- **Displays:** two displays (one left of main), Retina + non-Retina.
- **Edge cases:** Secure Input active (menu-bar fallback); Screen Recording granted / denied / revoked; zh/en UI.
- **Duplicates:** a bioRxiv preprint dropped after its Nature version; a folder import with 5 duplicates; a mail paper matching a `done` paper.

### 9.4 Non-regression gates (every merge)
- Existing tests unchanged and green, especially ArgvTests, AgentQueue, RegressionImport and the Mail suites.
- `CardSchema.swift` byte-identical.
- The first card still appears in about 1 s after a drop.
- With `assist.mode off` and `dedupe.enabled false`, the app behaves exactly as today. A render diff of the main screens shows only the new Overview | Ask segmented control.

---

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Fuzzy dedupe merges two different papers | Fuzzy layers never act alone; every action needs a click. Number / notice / final-DOI guards. *Keep both* is remembered. The AI only moves bands. Undo for 30 s, plus `.replaced/` and Recently Deleted. Fixture acceptance: zero false `certain`. |
| Quota creep (lens spam, follow-ups) | Ticket = one turn; debounce; latest-wins cancel; soft and hard caps; footer counter; quick models by default; no automatic retries (overloaded → Retry needs a new ticket); 12-turn session cap. |
| An unverified CLI behaviour breaks streaming | Capability parse plus a fallback to `--output-format json` (whole answer) recorded per CLI version; spike fixtures; version-pinned argv tests. |
| Screen Recording UX (scary prompt, Quit & Reopen, periodic re-confirm) | Opt-in; explainer first; three zero-permission paths fully functional; "Test capture" in Settings; the stable self-signed DR keeps the grant (DESIGN.md:207-209). |
| Two parallel agents edit the same file | Single ownership (§6), slot views, Lead-owned shared files, fixed merge order, `./test.sh` after each merge. |
| PORT refactor lands mid-flight | §8 table; adapters (`AssistPolicyText`, persona closure) make each PORT phase a one-file swap; no edits to `CardSchema.swift` or the env logic. |
| Prompt injection from the paper or the screen | No tools (`--tools ""`; Codex read-only sandbox + denylist); BlockTags on every untrusted string, including earlier answers in `<history>`; inert Markdown without links; citations validated; the judge's output only changes a band. |
| Leaking unrelated screen content | Only the drawn box; a mail/chat host forces a confirm; raw window titles never sent; no content in logs (`Log.assist`, CLI §7); job images 0600, deleted in `defer`. |
| Memory and CPU | ≤ 2 CLI children; warm-process idle kill; OCR off-main; no background indexing; the scan is throttled and pauses in Low Power Mode. |
| Swift 6 isolation crashes (Carbon, SCK, Vision, Services selector) | Async APIs only; the C callback uses `MainActor.assumeIsolated`; `nonisolated` helpers (DESIGN.md:282-286); a build-script grep for callback-style APIs (build_app.sh:55-58). |
| Parked "certain" decisions are lost on restart (IntakeActor.swift:130-136) | Only `certain` parks; reviews expire visibly with a toast; making parked items durable is a follow-up. |
| Notes write conflicts with an open NotesEditor | Append through `Engine.setNotes` (Operations.swift:286); the editor reloads on change and flushes unsaved edits first. |

---

## 11. Effort and calendar

| Workstream | Days | Of which v1.1 |
|---|---|---|
| Lead: Slice 0 + 3 integrations | 2.5 | — |
| A: spike + assist core + Explain + reader hookup | 10.5 | — |
| B: dedupe | 11.5 | 3.5 (B4) |
| C: selection + batch + Q&A + Ask window + reader | 11.5 | — |
| **Total** | **≈ 36 dev-days** (≈ 32 feature work + integration) | |

Calendar with three agents in parallel: Batch 1 ≈ 5 working days, Batch 2 ≈ 5, Batch 3 ≈ 4–5. The total is **about 3 weeks** plus the user's try-out after each batch. Each batch ends with:
1. all gates green;
2. `--render` snapshots for the user;
3. one `./build_app.sh` install (not `--dev`) after the user says yes.
