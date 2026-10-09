# PaperDeck portability: merged implementation plan

Inputs:
- Designs: `portability/design-architecture.md` (config layer) and `portability/design-onboarding.md` (onboarding and Help Center).
- Audits: `portability/bindings.md`, `journey.md` and `distribution.md`.

Every `file:line` below is repo-relative to the read-only snapshot `pd-port-snapshot/`. The load-bearing ones were re-checked for this plan, including:
- the launch order: `AppDelegate.swift:44-94`;
- the registered defaults: `SettingsStore.swift:131-144`;
- the prompt literal: `CardSchema.swift:17-45`;
- the WashU strings: `L10n+mailSettings.swift:77-80,116,128-133,145,165-168,181-189,411-414,444-451,565-568`, `L10n+mail.swift:167-170`;
- the institution branches: `MailSettings.swift:153-157`, `MailSettingsSupport.swift:209-212`, `MailAddAccountSheet.swift:545`;
- `MailAccount` decoding: `MailSettings.swift:320-347`;
- the build script: `build_app.sh:19-164`;
- the render tool: `PreviewRenderer.swift:5-120`.

Nothing in the snapshot was modified. No claude/codex was run, and no private folder or the keychain was read.

---

## 0. Decisions where the two designs disagreed

| Topic | Architecture design | Onboarding design | **Decision** |
|---|---|---|---|
| Where institution, field and guide data live | New `PaperDeckConfig` target | Core `Profile/` and `Guide/` folders | **New `PaperDeckConfig` target**, depending on Core and Shared. Core cannot import it, so the compiler stops engine code from branching on an institution. Tests can link it, so the WashU strings become unit-testable; today they are in the app target, which tests cannot link (`SelfTestAppRules.swift:4-5`). The guide model and content also live there (`Config/Guide`). |
| Key names | `org.presetID`, `profile.fieldID`, `config.schemaVersion` | `policy.preset`, `profile.field`, `config.migrationVersion` | `org.preset`, `org.custom`, `profile.field`, `profile.stage`, `profile.readerDescription`, `config.migrationVersion`, `config.origin` |
| How "existing install" is remembered | Pre-dismissed `help.*` keys | `onboarding.version` absent | **`config.origin = legacy`**, written once. The Getting Started card and the automatic tour appear only when the origin is `fresh`, so no extra keys are written for the current user. |
| Pin registered defaults in the migration | No | Yes (language, models) | **No.** No registered default changes in this round. The rule is recorded instead: any future default change first adds a migration step that pins the old value. |
| Setup UI | Extend the Setup Assistant, plus a separate Welcome window | One onboarding window with three modes | **One onboarding window** (preflight, live and revisit modes). The old `SetupAssistantView` stays, reachable through the `onboarding.legacy` rollback flag, for one release. |
| Profile UI | New Settings ▸ Profile tab | Sections in General | **New Settings ▸ Profile tab.** General gains two sections, "Help & Setup" and "Move to another Mac". |
| Field catalog | 11 fields | 9 fields plus career stage | **11 fields × 4 stages.** Life sciences & comp-bio at PhD stage is the byte-identical default. |
| `general` starter categories | 5 neutral categories | None | **5 neutral categories.** This avoids a schema whose category list is only `__new__` (`CardSchema.swift:52-60`). |
| Proving the prompt unchanged | Short-circuit to the literal, plus a whitespace-normalized test | Byte-identical render | **Both.** Production returns the literal for the legacy profile, so it is byte-identical by construction. A normalized-equality test proves the template has not drifted, and a golden fixture pins the literal. |
| Organization packs | Separate `paperdeck.organization/1` format | Settings file | **One format, `paperdeck.settings/1`.** A "lab setup file" is a partial export. Its organization section carries only the name, short name, approved tools, a policy link and the people default; free text is never imported. |
| Reader-description cap | 300 characters | 200 characters | **200 characters**, single line, sanitized. |
| Invalid-pattern example `prof.x@wustl.edu` | Generic for everyone | Generic for everyone | The washu preset keeps today's example word for word, so the current user sees no change. Generic uses `name@university.edu`. |
| Default import folder | `~/Desktop` | `~/Downloads` | `import.lastFolder`, otherwise `~/Downloads`. Legacy installs get `~/Desktop/Paper_reading` (today's value) from the `LegacyInstall` preset. |
| Library "Change…" | Move, open existing or new | Fallback with Restart | **Open existing** and **Start new empty**, both through one Core call (`replaceIndexFromLibraryFolder`), plus the identity guard and Restart Now. An automated cross-volume **Move** is out of scope; the documented route is to move the folder in Finder, then Change… detects it as the same library. |
| `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, a "Signed in as" line, per-account usage pauses | In scope | Tutorial only | **Out of scope this round.** How these interact with the macOS keychain is unverified. Switching accounts is covered by a tutorial (log out and log in in Terminal). |
| "What's new" banner | — | One-time banner | **Dropped.** It would be a visible change for the current user, and the Help menu is enough. |
| Build variable names | `PAPERDECK_*` and `build.local.env` | (distribution design: `PD_*`) | `PAPERDECK_*` and `build.local.env`. The file is parsed against a whitelist, never `source`d. |
| `MailAccount.suggestedPowerAutomateFolder` | Deprecated wrapper | — | **Remove it from Core.** A wrapper would need the WashU literal, and Core cannot import Config. The one test (`MailSettingsUITests.swift:175-176`) and `MailRenders.swift:11` move to `CloudRootLocator`. |
| Org consent defaults | `ConsentDefaults` plus a clamp | `personDefault` limited to ask or never | **`PeopleAIDefault` with only `.ask` and `.never`**, so "always" for people cannot be expressed by construction. The alert default (`.always`, `MailSettings.swift:36`) is unchanged. |

---

## 1. 给你的简要说明（中文）

**会改变什么**
- 代码里和你本人绑定的东西都会改成「预设 + 设置」：WashU 的文字、你 OneDrive 的路径、生物方向的 AI 指令和起始分类、bundle id 和签名证书名。换一个人、一台 Mac 或一个账号时，只要在界面里选：
  - 机构（无特定规定 / WashU / 其他）；
  - 研究领域；
  - 邮件来源。
  不需要改代码。
- OneDrive 不再是写死的路径，只是「云文件夹」里的一种。邮件来源的情况：
  - 任何学校或公司的 Microsoft 365 都能用 Power Automate；
  - 也可以用 Dropbox、Google Drive、iCloud 云盘或本地文件夹；
  - Gmail、iCloud 和 IMAP 保持不变；
  - 新增了 Outlook.com、Google Workspace，以及「IT 禁用 Power Automate」时的替代方案（Apple Mail 规则、拖入 .eml、转发提醒）。
- 新增的引导和帮助：
  - 首次使用引导：8 步，可跳过，可随时从「帮助」菜单重开。
  - 帮助中心（⌘?）：入门清单、1 分钟功能导览、分步教程、故障排查、可复制的诊断信息。每一步都会实时检查你电脑的真实状态并自动打勾。
  - 设置页旁的「?」按钮、「帮助」菜单、菜单栏里的「帮助与设置」。
- 新增的设置：
  - 「个人资料」页：领域、阶段、AI 怎样理解你、机构 AI 规定。
  - 导出/导入设置，用于换电脑，绝不包含任何密码。
  - 「使用已有论文库」。
  - 更安全的「更换论文库」：不会再把两个库混在一起或覆盖别的库的信息。
- 构建脚本可以通过 `build.local.env` 设置 bundle id、证书和安装位置，默认值仍是你现在的。
- 新文档：
  - 英文用户指南；
  - 中文 README；
  - 故障排查；
  - 通用 Power Automate 教程；
  - 换电脑和换账号教程。

**对你不会改变的**
- 升级后第一次启动时，程序会识别出这是「已有安装」，只新增几项设置：机构 = WashU，领域 = 生命科学 / 计算生物学，日期按美式「月/日」。写入之前会自动备份原设置。
- 所有 WashU 提示原文一字不变，AI 解读论文的指令逐字节相同。
- 这些已保存的设置一项都不改：
  - 论文库位置；
  - AI 选择和模型；
  - 邮件账户「WashU (Power Automate)」及其 OneDrive 文件夹；
  - 发件人列表；
  - 英文界面。
- bundle id、签名、钥匙串里的应用专用密码、文稿和通知权限、小组件都不变。
- 你不会看到引导窗口，Today 页也不会出现入门清单。你能看到的变化只有新增的「帮助」菜单、「?」按钮和设置里的「个人资料」页。
- 正式安装用普通的 `./build_app.sh`（不加 `--dev`），并且安装前会先征得你的同意。

**新的人、新的 Mac 会怎样**
1. 打开后先看到欢迎页，可以切换中文。可以选「快速开始」，也可以选「我从另一台 Mac 迁移」，或「用实验室或 IT 给的配置文件」。
2. 「关于你」：选领域、阶段和机构 AI 规定。
3. 「AI」：自动检测 Claude 和 ChatGPT（Codex）是否已安装、已登录，不消耗额度。也可以「暂不使用 AI」。只有手动点「开启」才会开始用额度。
4. 「论文库」：在论文库创建之前先选位置（会先解释，再弹出系统权限）。可以「新建」，也可以「使用已有论文库」，换电脑时直接打开拷过来的库。
5. 之后依次是：每日计划和提醒 → 邮件（可跳过，按「你的邮件在哪」分路线指引）→ 导入 PDF（可跳过）→ 完成 → 功能导览。之后 Today 页会显示入门清单，直到你全部完成或关掉它。

---

## 2. Architecture

### 2.1 Layers and rules

```
PaperDeckShared  (Foundation; app + widget)
  ├─ BuildIdentity            NEW — Info.plist PD* keys; fallbacks = today's literals
  └─ DeepLink                 + .help(topic:), .setup
PaperDeckCore    (engine; knows no institution, field or provider folder names)
  ├─ Agent/CardPrompt.swift   NEW port: CardPromptProfile + template
  ├─ Engine.Dependencies.loadCardProfile (default .legacyCompBio)
  ├─ Mail: MailAccount.source (optional), MailSettings.dateOrder, findDue(dateOrder:)
  ├─ Engine/StarterPack.swift, Library/LibraryIdentity.swift (guard + inspector), Rebuild additions
  └─ Agent/ProviderProbe.swift (zero-quota detection without an engine)
PaperDeckConfig  NEW target (deps: Core, Shared; nonisolated, Sendable values, no UI)
  ├─ Model/ Presets/ Resolve/ Migrate/ Mail/ Strings/ Portability/      (slice S1)
  └─ Guide/ (model, evaluator, checklist, gate, search, markdown, diagnostics: S3)
     Guide/Content/ (bilingual topic data: S4)
PaperDeck app    (MainActor)
  ├─ App/ConfigStore.swift (observable; writes keys; mirrors org/field into LangStore)
  ├─ L10n delegates organization- and field-dependent text to OrgStrings / FieldStrings
  ├─ Views/Onboarding/*, Views/Help/*, Views/Settings/ProfileSettingsTab.swift …
  └─ CLI: --config, --migrate-dry-run, --export-settings, --import-settings --dry-run,
          --guide-export, --selftest strings|settings|onboarding, --render --guide-only|--seed-plist
```

The rules below go into `docs/ARCHITECTURE-CONFIG.md`. Two of them are enforced by permanent lint tests added in W2.

1. **No institution in the engine.** Core never mentions an institution or field id. It receives values: a `CardPromptProfile` and a `SlashDateOrder`.
2. **No UI in Config.** `PaperDeckConfig` holds no UI and starts no actors.
3. **One home for institution literals.** Institution literals appear only in `Sources/PaperDeckConfig/Presets/OrganizationPresets.swift` (lint G1).
4. **One home for cloud-folder names.** Logic that recognizes cloud root names lives only in `Sources/PaperDeckConfig/Mail/CloudRootLocator.swift` (lint G4). It keeps today's privacy rule: it lists only the root names in `~/Library/CloudStorage` and never reads inside them (`MailSettingsSupport.swift:199-201`).
5. **Preset ids are append-only.** An unknown id falls back to `generic` / `general` and is logged; it never crashes.
6. **No resource bundles.** Presets and help content are Swift literals. A SwiftPM resource bundle would make `Bundle.module` point at the build machine's path (`build_app.sh:66-67`).

Package.swift diff (from `Package.swift:11-37`):
```swift
.target(name: "PaperDeckConfig", dependencies: ["PaperDeckCore", "PaperDeckShared"]),
.executableTarget(name: "PaperDeck", dependencies: ["PaperDeckCore", "PaperDeckShared", "PaperDeckConfig"],
                  swiftSettings: [.defaultIsolation(MainActor.self)]),
.testTarget(name: "PaperDeckCoreTests", dependencies: ["PaperDeckCore", "PaperDeckShared", "PaperDeckConfig"],
            resources: [.copy("Fixtures")]),
```
The widget target is unchanged.

### 2.2 Data flow
```
launch ─▶ ConfigMigration.runIfNeeded (before SettingsStore registers defaults)
UserDefaults ─▶ ConfigResolver ─▶ ConfigSnapshot ─▶ ConfigStore (app) ─▶ LangStore.org / .field ─▶ L10n
                                         └─ cardPromptProfile ─▶ Engine.Dependencies.loadCardProfile
                                                                  └─▶ AgentQueue CardRequest(systemPrompt:)
MailSettings.load (Core, + dateOrder) ─▶ MailSyncActor ─▶ MailHeuristics.findDue(dateOrder:)
```
- The engine reads the card profile each time it builds a request, the same way it re-reads `ctx.settings()` (`AgentQueue.swift:402,522`). A profile edit therefore applies to the next card without a restart.
- Today the app calls `Engine.open(paths:)` with the default dependencies (`AppDelegate.swift:66`). It will pass `Engine.Dependencies(loadCardProfile: { ConfigResolver.cardPromptProfile() })`.

### 2.3 Config types (summary; exact signatures in §5.3)
- `LocalizedText {en, zh}`: both required, so a missing translation cannot compile.
- `ConfigOrigin {legacy, fresh}`.
- `CareerStage {masters, phd, postdoc, faculty}`.
- `PeopleAIDefault {ask, never}`.
- `OrganizationProfile`:
  - id, name, shortName, approvedAITools, policyURL (https only) and peopleDefault;
  - `texts` (verbatim overrides, for built-in presets only);
  - `mail: OrgMailHints` (oneDriveRootHint, oneDriveFallbackRootName, knownSenderDomains, powerAutomatePortal).
- `FieldPreset`:
  - readerPattern `"… ({level})"` and difficultyPattern `"… {stage}"`;
  - methodHint, typicalTimes and 4 checklistExamples;
  - starterCategories (at most 7) and senderPresetIDs;
  - 4 example texts.
- `ConfigSnapshot`:
  - origin, field, stage, readerOverride, organization and mailDateOrder;
  - computed `cardPromptProfile`.
- `PersistedDomain`:
  - the persistent domain only (`persistentDomain(forName:)`), never registered values;
  - this matters because `object(forKey:)` sees registered defaults such as `setup.completed` and `library.path` (`SettingsStore.swift:133-144`).

### 2.4 Preset catalogs (all data)

**Organizations** (`Presets/OrganizationPresets.swift`)

| Field | `generic` (new installs) | `washu` (current user; every text moved verbatim) | `custom` |
|---|---|---|---|
| name / shortName | nil / nil | "Washington University in St. Louis" / "WashU" | entered by the user (≤60 / ≤16 chars) |
| approvedAITools | [] | ["Claude Edu", "ChatGPT Edu"] (`L10n+mailSettings.swift:449-450`) | entered by the user (≤5 × 40 chars) |
| texts | none: composed generic wording (§2.7) | all 13 `OrgTextKey`s verbatim, en and zh | none: composed from name, short name and tools |
| peopleDefault | .ask | .ask (today, `MailSettings.swift:36`) | .ask or .never |
| mail.oneDriveRootHint | nil | "WashingtonUniversity" (today's sort key, `MailSettingsSupport.swift:209-212`) | optional |
| mail.oneDriveFallbackRootName | nil (the form shows Choose…) | "OneDrive-WashingtonUniversityinSt.Louis" (`MailSettings.swift:155`) | nil |
| mail.knownSenderDomains | [] | ["wustl.edu"] (migration diagnostics only) | [] |
| mail.powerAutomatePortal | nil → make.powerautomate.com | nil | optional https |

**Fields** (`Presets/FieldPresets.swift`):
- `lifeSciencesCompBio` equals today's prompt exactly: persona, method, times and examples at `CardSchema.swift:19,32,38-42`, the starters `PaperCategory.starters` (`PaperCategory.swift:21-29`), and the 9 sender ids (`MailSettings.swift:51-61`).
- The patterns are `"a computational-biology researcher ({level})"` and `"a comp-bio {stage}"`. With `phd` they give exactly "a computational-biology researcher (PhD level)" and "a comp-bio PhD student".
- New fields: the method, time and example texts come from design-architecture §5.2 and design-onboarding §11.1, at most 7 starters each.

| id | reader pattern | difficulty pattern | starters (≤7) | suggested senders |
|---|---|---|---|---|
| lifeSciencesCompBio | (today) | (today) | today's 7 | today's 9 |
| neuroCognitive | a neuroscience / cognitive-science researcher ({level}) | a neuroscience {stage} | Systems Neuroscience · Cognitive & Behavioral · Computational Neuroscience · Neuroimaging · Neural Development & Disease | Scholar, bioRxiv, Nature, Cell, PubMed |
| medicineHealth | a clinical / biomedical researcher ({level}) | a clinical-research {stage} | Clinical Trials · Epidemiology & Public Health · Diagnostics & Imaging · Health Informatics & AI · Translational Medicine | Scholar, medRxiv, PubMed, NEJM*, JAMA*, Lancet* |
| csML | a computer-science / machine-learning researcher ({level}) | a CS/ML {stage} | LLMs & Foundation Models · Agents & Reasoning · Computer Vision · Language & NLP · ML Theory & Optimization · Systems & Efficiency · Evaluation & Safety | Scholar, arXiv, ACM*, IEEE*, OpenReview*, Semantic Scholar* |
| engineering | an engineering researcher ({level}) | an engineering {stage} | Robotics & Control · Signal Processing · Electronics & Hardware · Mechanical & Civil · Energy Systems · Biomedical Engineering | Scholar, arXiv, IEEE* |
| physicsAstro | a physics or astronomy researcher ({level}) | a physics {stage} | Condensed Matter · Quantum Information · High-Energy & Particle · Astrophysics & Cosmology · Optics & Photonics · Computational Physics | Scholar, arXiv, APS*, IOP* |
| chemistryMaterials | a chemistry / materials-science researcher ({level}) | a chemistry {stage} | Synthesis & Catalysis · Materials & Energy · Computational Chemistry · Analytical & Spectroscopy · Polymers & Soft Matter · Electrochemistry | Scholar, ChemRxiv*, ACS*, RSC* |
| mathStats | a mathematics / statistics researcher ({level}) | a math/stats {stage} | Probability · Statistics & Inference · Optimization · Applied Mathematics · Computational Methods | Scholar, arXiv |
| socialSciences | a social-science researcher ({level}) | a social-science {stage} | Economics · Psychology · Political Science & Policy · Sociology & Demography · Education · Methods & Causal Inference | Scholar, SSRN*, NBER* |
| humanities | a humanities researcher ({level}) | a humanities {stage} | History · Literature · Philosophy · Linguistics · Art & Media · Digital Humanities | Scholar |
| general (fallback for fresh installs) | a researcher ({level}) | a {stage} in the paper's field | Methods & Tools · Reviews & Surveys · Theory · Empirical Studies · Datasets & Benchmarks | Scholar, arXiv |

\* New sender presets, flagged `verified: false` until each pattern has been checked against one real alert. They show in a "More presets" submenu with the hint "Check the sender address in one of your alerts". A wrong domain does no harm: alert rules triage only mailing-list mail (`MailSettings.swift:44-50`).

**Stages:**

| Stage | `{level}` | `{stage}` |
|---|---|---|
| masters | Master's level | Master's student |
| phd (default) | PhD level | PhD student |
| postdoc | postdoc level | postdoc |
| faculty | faculty level | faculty member |

**Mail sources** (`Mail/MailSourceCatalog.swift`). The order is fixed and matches today's chooser (`MailAddAccountSheet.swift:11-13`).
- **Set up an account:**
  - Microsoft 365 via Power Automate (any work or school tenant);
  - Gmail, iCloud, Yahoo, Fastmail and other IMAP;
  - Folder of .eml files (with a cloud-location picker).
- **Other ways to get mail in** (new; guide-only, each opens a Help topic and, where possible, ends in a pre-filled sheet):
  - Outlook.com / Hotmail;
  - Google Workspace without app passwords (Beta);
  - Microsoft 365 that blocks Power Automate;
  - Apple Mail rule → folder (Beta);
  - Gmail → Google Drive with Apps Script (Beta);
  - Just drag emails in.

**Cloud roots** (`Mail/CloudRootLocator.swift`) are classified by name only:
- `OneDrive-<Tenant>` is OneDrive for business. `OneDrive-Personal` and `OneDrive-SharedLibraries-*` are excluded for the Power Automate route.
- Also recognized: `Dropbox*`, `GoogleDrive-<account>/My Drive`, `Box-Box`, iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`), the legacy `~/OneDrive - <Org>`, and local folders.
- Ranking for Power Automate: an existing `<root>/PaperDeck Mail` wins; then business roots; then the root matching `org.mail.oneDriveRootHint`; then the last choice (`mail.cloudRoot`); then alphabetical.
- This removes all three WashU code branches (bindings B1–B3). It also fixes the Personal-before-business sort (journey A-19).

**Legacy install** (`Presets/LegacyInstall.swift`) is today's behavior as data:
```swift
package enum LegacyInstall {
    package static let organizationID = OrganizationPresets.washu.id      // "washu" (literal lives in the preset)
    package static let fieldID = FieldPresets.lifeSciencesCompBio.id
    package static let dateOrder: SlashDateOrder = .mdy                    // MailHeuristics.swift:516-521 today
    package static let importFolder = "~/Desktop/Paper_reading"            // SetupAssistantView.swift:499 today
}
```

### 2.5 Settings keys

None of the new keys is ever passed to `register(defaults:)`. Every existing key and default stays as it is.

| Key | Type | Written by | Absent means |
|---|---|---|---|
| `config.migrationVersion` | Int (1) | ConfigMigration | not migrated |
| `config.origin` | legacy / fresh | ConfigMigration | `LegacyInstallDetector` result (§2.6) |
| `config.migratedAt` / `config.migrationNote` | Double / String (markers) | ConfigMigration | — |
| `org.preset` | generic / washu / custom | migration, onboarding, Settings ▸ Profile, import | origin fresh → `generic`; otherwise → `washu` |
| `org.custom` | JSON `OrganizationProfile` (no `texts`) | Profile, import | used only for `custom` |
| `profile.field` | FieldPreset id | migration (legacy), onboarding, Profile, import | fresh → `general`; otherwise → `lifeSciencesCompBio` |
| `profile.stage` | CareerStage | onboarding, Profile | `phd` |
| `profile.readerDescription` | String (≤200, sanitized) | Profile, onboarding (only when edited), import (confirmed) | composed from field and stage |
| `mail.dateOrder` | mdy / dmy / auto | migration (legacy mdy, fresh auto), Mail ▸ Reading criteria | **`mdy`** (Core default, today) |
| `mail.cloudRoot` | String (root directory name) | folder / Power Automate sheet | no last choice |
| `MailAccount.source` (inside the `mail.accounts` JSON) | `MailSourceID` raw value | add/edit sheet | legacy inference = today's `looksLikeOneDrive` (`MailSettingsSupport.swift:394-397`) |
| `import.lastFolder` | `~/…` | import panels, migration (legacy) | `~/Downloads` |
| `library.pendingAction` | JSON `LibraryPendingAction` | Settings ▸ Library ▸ Change… | none |
| `library.previousPath` | String | Change…, mismatch alert | none |
| `onboarding.version` / `.completedAt` | Int / Double | Finish | (informational) |
| `onboarding.aiDecision` | claude / codex / none | AI page | inferred from `agent.mode` |
| `onboarding.mailDecision` | configured / dragOnly / skipped | Mail page | the mail row is shown |
| `onboarding.legacy` | Bool | developer only (rollback) | false |
| `guide.checklist.dismissed`, `guide.skipped` ([String]), `guide.manualDone` ([String]), `guide.activity` ([String: Double]) | — | Help Center | false / [] / {} |
| `transfer.lastExportedAt` / `transfer.importedAt` | Double | Export / Import | — |

### 2.6 Migration: detecting an existing install and mapping it to WashU and comp-bio

**When it runs:** `ConfigMigration.runIfNeeded` runs as the first statement of `applicationDidFinishLaunching`, before `SettingsStore()` registers defaults (`AppDelegate.swift:45-46`).
- It runs once, gated by `config.migrationVersion ≥ 1`.
- The CLI, `--selftest` and `--render` never run it. They only resolve values on read.

**Inputs:**
- `PersistedDomain.app()`, which is `UserDefaults.standard.persistentDomain(forName: BuildIdentity.current.bundleID)`.
- `databaseExists`, an existence check only on `AppPaths.production().database` (`EngineConfig.swift:41`). The file is never opened.

```
isLegacy(p, db) := db
   || p.has("setup.completed") || p.has("library.path") || p.has("mail.accounts")
   || p.has("mail.senders") || p.has("agent.provider")
   || (p.string("agent.mode") ∉ {nil, "off"})          // a --dev build writes only agent.mode=off (build_app.sh:149) → not legacy
markers := [folderPath contains org.mail.oneDriveRootHint, displayName contains shortName,
            sender pattern ends with a knownSenderDomain]   // values read from OrganizationPresets.washu; diagnostics only

if p["config.migrationVersion"] >= 1: return p origin            // no-op
if isLegacy:
   backup p → <support>/Backups/settings-before-config-v1-<stamp>.plist   (Maintenance prunes only "<prefix>*.sqlite", Maintenance.swift:403-414)
   writeIfAbsent org.preset = LegacyInstall.organizationID         // "washu"
                 profile.field = LegacyInstall.fieldID             // "lifeSciencesCompBio"
                 mail.dateOrder = "mdy", import.lastFolder = LegacyInstall.importFolder
   write config.origin = "legacy", config.migrationNote = markers, config.migratedAt, config.migrationVersion = 1
else:
   write config.origin = "fresh", mail.dateOrder = "auto", config.migratedAt, config.migrationVersion = 1
```

Why every legacy install becomes `washu`, not only installs with markers:
- Before this build, every install showed the WashU texts, so `washu` is the faithful mapping even if a marker test misfires (for example, a renamed account).
- The markers only produce the note in Settings ▸ Profile.

The migration never rewrites an existing key: not `agent.*`, `library.path`, `mail.*` JSON, `language`, `setup.completed` or `reminder.*`. Downgrading is safe because only new keys and one optional JSON field are added. An older build ignores `MailAccount.source`, and a rewrite by an older build drops it, after which inference takes over.

**Current user, item by item:**

| Item | Today | After the change | Why identical |
|---|---|---|---|
| Defaults domain, keychain service, TCC, notifications, widget id, login item, URL handler | derived from `com.yijiang.paperdeck` | `BuildIdentity` resolves the same strings | the build default is unchanged (§2.11) |
| Signing | "PaperDeck Local Signing" | default `PAPERDECK_SIGN_IDENTITY` | `build_app.sh:33` default kept |
| Library | `library.path` (or the registered default) | not rewritten; the identity guard sees matching ids | §2.9 |
| AI | persisted `agent.mode` / `agent.provider`; models may be registered-only | untouched; registered defaults unchanged | `SettingsStore.swift:138-140` |
| Card prompt | comp-bio literal | `systemPrompt(for: .legacyCompBio)` returns the literal | §2.6b, T2 |
| Categories | in their DB | never replaced (the DB has papers, so it is not pristine) | §2.9 |
| Mail account | "WashU (Power Automate)", absolute OneDrive-WashU path, no `source` | read as is; inferred as Power Automate | `MailSourceResolver` legacy branch |
| WashU sentences | always shown | `org = washu` renders them word for word | golden test T3 and `--selftest strings` |
| Dates `a/b` | month/day | `mail.dateOrder = mdy` (absent also means mdy) | T13 |
| Setup, Getting Started, tour | done / none | `setup.completed` untouched; `origin = legacy` hides the card and the automatic tour | §3.4 |
| Menu-bar position | autosave `com.yijiang.paperdeck.status` | `"\(bundleID).status"`, the same string | `StatusBarController.swift:32` |
| UI language | `en` (registered) | unchanged | — |

**Visible additions:**
- a Help menu;
- a "Help & Setup" submenu in the menu bar;
- the Settings ▸ Profile tab;
- in Settings ▸ General, the "Help & Setup" and "Move to another Mac" sections;
- "?" buttons;
- a "More presets" submenu;
- an "Other ways to get mail in" section;
- Library ▸ "Re-index full text";
- Widget ▸ "Repair registration";
- the Mail inbox list's compact 「让 AI 分析」 / "Analyze with AI": on every card but the selected one
  it is one small button plus ⓘ (the question and the privacy note — the institution's guidance,
  WashU's wording for `washu` via `OrgStrings` — in its tooltip and popover). The selected card and
  the inspector still show the whole explanation box with the full note. Requested by the user
  (verifier finding F1, kept).

### 2.6b Card prompt port
- `CardSchema.systemPrompt` (`CardSchema.swift:17-45`) stays exactly as it is. About 20 tests pin it (bindings D1).
- New `CardPromptTemplate.render(_:)`: the same text with five slots (reader, difficulty reference, method hint, typical times, checklist examples). The SECURITY, FACTUALITY, STYLE, CATEGORY, TAGS and READING PLAN paragraphs are shared text.
- `CardSchema.systemPrompt(for p:)` returns `p == .legacyCompBio ? systemPrompt : CardPromptTemplate.render(p)`.
- **Reader override:** a user-written reader replaces `reader`, and `difficultyReference` becomes "the reader described above". It is sanitized:
  - one line;
  - control characters, `<` and `>` stripped;
  - at most 200 characters;
  - the same idea as `MailTriageSchema.trusted` (`MailTriageSchema.swift:185-190`).
  It enters the system prompt, so a value from an imported file needs explicit confirmation.
- **Request sites:**
  - `AgentQueue.swift:1015` uses `CardRequest(systemPrompt: CardSchema.systemPrompt(for: deps.loadCardProfile()), …)`.
  - The connection test (`AgentQueue.swift:1078-1084`) keeps the default.
  - The mail-triage prompt is unaffected.

### 2.7 Organization- and field-dependent strings

**The 13 golden keys (`OrgTextKey`):**

| Key | Today's source |
|---|---|
| accountsIntro | `L10n+mailSettings.swift:77-80` |
| paTemplateName | `:116` |
| paTemplateBlurb | `:128-130` |
| gmailBlurb | `:131-133` |
| paDefaultAccountName | `:145` |
| oneDriveMissing | `:165-168` |
| paBlockedNote | `:181-184` |
| paIntro | `:186-189` |
| patternInvalid | `:411-414` |
| personSenderWarning (was `washuAlwaysWarning`) | `:444-447` |
| policyNote (was `washuPolicyNote`) | `:448-451` |
| triagePrivacy | `:565-568` |
| consentNote(provider) | `L10n+mail.swift:167-170` |

**Field keys (golden for `lifeSciencesCompBio`):**

| Key | Source |
|---|---|
| describeHint | `L10n+settings.swift:406-408` |
| categoryDescriptionPlaceholder | `L10n+shell.swift:40` |
| customInstructionsHint (example part) | `L10n+mailSettings.swift:506-509` |
| alertsTip | `:339-342` |

**Rendering:**
- `washu` renders every key verbatim in en and zh. Wave 0 produces the fixture mechanically from today's binary.
- `generic` renders the texts below (en; zh added by the implementer).
- `custom` composes the generic text with `{short}`, `{name}` and `{tools}`.

| Key | generic (en) |
|---|---|
| accountsIntro | Add the mailbox or folder PaperDeck should check. Work or school Microsoft 365: use Power Automate. Otherwise Gmail, iCloud or another IMAP account — or drag .eml files in. |
| paTemplateName | Microsoft 365 (work or school) via Power Automate · custom: "Microsoft 365 via Power Automate ({short})" |
| paTemplateBlurb | Your own Power Automate flow saves allowlisted emails as .eml files to OneDrive; PaperDeck watches the synced folder. No app registration needed — works if your organization allows Power Automate. |
| gmailBlurb | Good if your organization blocks Power Automate: subscribe or forward your alerts to a Gmail address. Needs 2-Step Verification. |
| paDefaultAccountName | Microsoft 365 (Power Automate) · custom: "{short} (Power Automate)". It always contains "Power Automate", which the legacy inference relies on. |
| oneDriveMissing | No OneDrive for work or school was found on this Mac. Install OneDrive and sign in with your work or school account, or choose another folder. The UI appends "Found: …" with the detected roots. |
| paBlockedNote | If your organization blocks Power Automate or the OneDrive connector: drag emails from Outlook into PaperDeck, save them into a folder with an Apple Mail rule, or forward alerts to Gmail or iCloud (IMAP). Buttons: [Set Up Gmail Instead] (existing) and [Other Ways…] (topic `mail-m365-blocked`). |
| paIntro | Set this up once at make.powerautomate.com with your work or school account (about 5 minutes). The flow copies new emails from your sender list into OneDrive as .eml files; OneDrive syncs them to this Mac. Already built it? Check it against the steps below. |
| patternInvalid | Not an address or a domain. Examples: name@university.edu, @biorxiv.org, @*.nature.com |
| personSenderWarning | People may send unpublished work; your institution may restrict which AI tools may receive it — check its policy. · custom: "People may send unpublished work; {name} asks not to put it into AI tools that aren't approved." |
| policyNote | Check your institution's AI guidance before sending unpublished work or institutional data to an AI tool. "Ask each time" keeps this sender's mail on your Mac until you decide per email. · custom with tools: "{short} AI guidance: don't put unpublished work into AI platforms that aren't approved ({tools} are). …" |
| triagePrivacy | Today's common part, without the final WashU sentence. Custom with tools appends "{short}: prefer {tools} logins for people's mail." |
| consentNote | Sends this one email's text to {provider} once (links become markers; the signature and other addresses are removed). Check your institution's guidance before sending unpublished work to an AI. |

Two new strings come from the same data:
- `OrgStrings.aiPolicyLine`, used on the onboarding AI page. For organizations with approved tools it reads "{short} guidance: use an approved AI login ({tools}) for unpublished work." Otherwise it reads "Check your institution's guidance before sending unpublished work to an AI."
- The zh test-notification text (`L10n+settings.swift:84`) interpolates the configured reminder time. At 11:00 it is identical to today's.

### 2.8 Mail: OneDrive becomes one provider among several
- **Remove the institution code.** `MailAccount.suggestedPowerAutomateFolder` (`MailSettings.swift:153-157`) is deleted. The suggestion comes from `CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, …)`. With no root detected, `washu` still returns today's path through `oneDriveFallbackRootName`, and `generic` returns nil, so the form shows "Choose…".
- **`MailSettingsSupport.oneDriveFolders`** (`:192-220`) becomes `cloudRoots(home:)`, which wraps `CloudRootLocator.classify`. It is still one `contentsOfDirectory` of `~/Library/CloudStorage` plus existence checks. The `"WashingtonUniversity"` sort is deleted.
- **`MailAddAccountSheet.detectOneDrive`** (`:531-550`) uses one rule for every tenant. The `:545` branch is deleted.
- **Account kind:** `MailAccountTemplate.init(account)` (`MailAddAccountSheet.swift:16-21`) uses `MailSourceResolver.source(of:)`. New accounts store `source`. `looksLikeOneDrive` (`MailSettingsSupport.swift:394-397`) becomes the resolver's legacy branch.
- **Paths are still stored absolute**, as today (`MailAddAccountSheet.swift:465`). `PortablePath` is used only for export and import, so storage readers don't change. The sheet records `mail.cloudRoot`.
- **`MailPowerAutomateGuide.oneDrivePath`** (`:33-40`) uses `CloudRootLocator.split`, which also handles the legacy `~/OneDrive - <Org>`. The portal comes from `org.mail.powerAutomatePortal ?? make.powerautomate.com` (`:31`).
- **Provider-aware text:** the folder errors and the delete hint name the detected provider (`FolderMailSource.swift:49-51`, `L10n+mailSettings.swift:157-159`). Power Automate and OneDrive accounts keep today's text.
- **IMAP sign-in failure** (`IMAPClient.swift:70-74`) is host-aware. For `outlook.office365.com` and `imap-mail.outlook.com` it says "Microsoft doesn't accept app passwords for this mailbox — see Help ▸ Outlook.com". Other hosts keep today's text.
- **Sender presets** (`MailSenderRulesEditor.swift:25-33`): a "Suggested for {field}" section from `SenderPresetCatalog.suggested(for:)` (for the current user, today's 9 in today's order), then "More presets ▸".
- **New person or advisor rules** take `org.peopleDefault` (ask or never), so a preset can only be stricter. `SenderRule.init`'s kind default (`MailSettings.swift:36`) is unchanged.
- **Triage model pickers** (`MailTriageSection.swift:12-13`) use `CodexModelCatalog.choices` (`SettingsProbes.swift:132`), like `AISettingsTab.swift:151`. The default `gpt-5.6-luna` stays (`MailSettings.swift:184,223`).
- **Codex connection-test model:** the app passes it into `testConnection(provider:model:)` (`AISettingsTab.swift:265`). It is `gpt-5.6-luna` when the plan's cache lists it (current user: unchanged), otherwise the first cached model.
- **Script generators** (pure, `Mail/MailRuleScripts.swift`):
  - an Apple Mail rule AppleScript that writes `source of msg` to `<folder>/<id>.eml`, with `Save Script…` to `~/Library/Application Scripts/com.apple.mail/` through an NSSavePanel the user confirms;
  - a Google Apps Script that saves `getRawContent()` matching the sender list into a Drive folder.
  Both are labeled Beta until V3 and V4 (§7) are verified.

### 2.9 Library safety and "new Mac" flows
- **Identity guard (Core, S1):** `Engine.start()` (`Engine.swift:197-199`) first runs `checkLibraryIdentity()`.
  - On `.mismatch` (the manifest id differs from the DB id and the DB has papers), it returns `MaintenanceReport.libraryMismatch` **before** `maintenance.onLaunch()`, `writeManifest()` (`EngineContext.swift:231-244`), the agents and mail. It may be called again after the user resolves the mismatch.
  - This fixes the overwrite hazard in distribution.md §5.2.1.
  - For the current user the ids match, so it is a no-op.
- **`replaceIndexFromLibraryFolder(starterPackIfEmpty:)`** = `maintenance.backupNow()` followed by `rebuildFromSidecars(replacingExisting: true)` (`Rebuild.swift:27-54`). Mail tables are untouched. When the folder has no manifest and no cards, it seeds the given starter pack. It serves both "Open existing" and "Start new empty".
- **`LibraryInspector.inspect`** gives missing, unreadable, empty, otherContent, existingLibrary(id, cards) or parentOfLibrary(child, cards). The scan is bounded and runs off the main actor.
- **`applyStarterPackIfPristine`** runs before `start()`, so the first manifest already holds the chosen field's categories. It applies only when the DB has zero papers (live or deleted), every category is `origin = starter` and equals `PaperCategory.starters`, and no manifest exists on disk. **`addMissingStarterCategories`** inserts only missing names, never deletes, and caps the total at `Taxonomy.autoCreateLimit` (`Taxonomy.swift:8`).
- **`reindexMissingFullText()`** re-extracts text with PDFKit for papers without full-text rows. It costs no quota. It fixes "search finds titles only on a new Mac" (`Rebuild.swift:280-295`).
- **`library.pendingAction`** is executed in `bootstrap()` before `engine.start()` (§3.1). "Restart Now" uses `Relaunch.now()`, a detached `/bin/sh` that waits for our PID to exit and then runs `open "$APP"`. That works with the single-instance lock (`AppDelegate.swift:187-196`).
- **An unplugged external disk** no longer offers "Use ~/Papers" as the default (`LibraryOpenFailure.swift:128`). A new `volumeMissing` case offers Retry, Choose… and Quit. The Documents-denied case is unchanged.

### 2.10 Settings export/import (`paperdeck.settings/1`)

An **allowlist** registry (`Portability/SettingsRegistry.swift`). Unknown keys are never exported, the same philosophy as `ChildEnvironment.swift:3-13`.

| Class | Keys |
|---|---|
| export | `language`, `menubar.showCount`, `pdf.opener`, `plan.*`, `reminder.enabled/hour/minute/whenEmpty`, `agent.provider/model/codexModel/effort/textBudget/allowNewCategories/autoRead/notifyDone`, `library.importMode`, `metadata.lookup`, `mail.senders/criteria/syncMinutes/aiMode/triageProvider/triageModelClaude/triageModelCodex/triageDailyMax/triageBodyCap/maxAttachmentMB/prefillNotes/notifyNewRequests/includeInDailyReminder/retentionDays/dateOrder`, `panel.visible/edge/edgeYFraction/idleOpacity/expandOnDrag/showTodayOnHover` (`DropPanelController.swift:15-18`), `profile.*`, `org.preset`, `org.custom` |
| hint (shown and confirmed on import) | `library.path` (PortablePath), `agent.cliPath` / `agent.codexPath` (dropped if missing on the target), `metadata.mailto` (personal; off by default), `mail.accounts` (no secrets; `folderPath` as PortablePath; `username` flagged personal), `import.lastFolder`, `mail.cloudRoot` |
| never | everything else, including `agent.mode`, `setup.completed`, `general.launchAtLogin`, `reminder.lastDeliveredDay/scheduledFires`, `mail.enabled`, `mail.notify.*`, `config.*`, `onboarding.*`, `guide.*`, `transfer.*`, `library.pendingAction/previousPath`, `panel.screenID`, window frames, keychain items and all DB key-value state |

Import rules (pure `SettingsImporter.plan`; the app applies the result through the `SettingsStore` / `ConfigStore` setters so the `didSet` engine notifications fire, `SettingsStore.swift:68-102`):
1. Never write `agent.mode`, `mail.enabled` or `setup.completed`. AI and mail stay as they are, which means off on a new Mac.
2. New person and advisor rules with `.always` arrive as `.ask`. The opt-out checkbox "Keep 'Always' for people I set myself" is off by default.
2a. Never looser (portability fixes 2): every privacy- or quota-sensitive key carries `SettingsKeyEntry.sensitivity` (`mail.aiMode`, `mail.triageDailyMax`, `mail.triageBodyCap`, the triage models, `mail.maxAttachmentMB`, `mail.syncMinutes`, `mail.notifyNewRequests`, `mail.retentionDays`, `agent.autoRead`, `agent.textBudget`, `agent.effort`, `agent.model`, `agent.codexModel`, `metadata.lookup`; per entry this Mac has: each sender's AI policy and its `enabled` / `autoMerge` / `autoDownload` switches in `mail.senders`, each account's `enabled` and `lookbackDays` in `mail.accounts`, the institution's people default in `org.preset` / `org.custom`). A file value looser than this Mac's (its default when absent) keeps this Mac's value and is listed in `ImportPlan.loosenings` — the sheet's "Kept stricter" items, each with its own checkbox (off); the CLI dry run with `--accept-looser` takes them all. `SettingsRegistryLintTests` fails for an unclassified key, or an unclassified field of a sender rule or a mail account.
2b. Senders and accounts are merged by id (a sender also by its normalized pattern, an account by its mailbox or watched folder); this Mac's ids and its own entries are kept (`ImportPlan.merges`: added / replaced / kept).
3. IMAP accounts arrive as "needs app password". On the same Mac, account ids are kept, so the keychain item `<id>.imap` (`MailSettings.swift:151`) is found again.
4. Folder accounts are re-resolved against this Mac's roots: the same root name, else the only root of the same provider, else "choose later".
5. `profile.readerDescription` is shown verbatim and imported only if confirmed.
6. The organization section imports only name, short name, approved tools, an https link, peopleDefault and the OneDrive hint. It never imports texts, senders or AI enablement.
7. An unknown `format` is refused; unknown keys are ignored and counted.

A "lab setup file" is an export with only the Profile & institution and Mail senders sections.

### 2.11 Build identity

Precedence: script defaults (today's literals) < `build.local.env` (git-ignored, `KEY=VALUE`, whitelisted keys only, parsed and never `source`d) < environment `PAPERDECK_*` < flags.

| Key / flag | Default (unchanged) |
|---|---|
| `PAPERDECK_BUNDLE_ID` / `--bundle-id` (validated `^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$`) | `com.yijiang.paperdeck` |
| Widget id | derived `$BUNDLE_ID.widget` (pkd requires the prefix) |
| `PAPERDECK_SIGN_IDENTITY` / `--sign NAME\|SHA1\|-` (`--allow-adhoc` kept with today's meaning) | `PaperDeck Local Signing` |
| `PAPERDECK_INSTALL_DIR` / `--install-dir` (e.g. `~/Applications`), `--no-install` | `/Applications` |
| `PAPERDECK_KEYCHAIN_SERVICE` | `$BUNDLE_ID.mail` |
| `PAPERDECK_CHANNEL` (local \| distribution; `--package` sets distribution) | `local` |
| `--print-config`, `--package` (`ditto -c -k --sequesterRsrc --keepParent`, `.sha256`, `dist/INSTALL.md`) | — |
| `PAPERDECK_DEV_DIR` (test.sh; fallback `$(xcode-select -p)`-relative, clear error) | `/Library/Developer/CommandLineTools/Library/Developer` (`test.sh:8`) |
| `PAPERDECK_FIXTURE_LIST` / arguments (`tools/make_fixtures.sh`; the personal paths at `:8-9` are removed) | — |

**Stamping** happens after `build_app.sh:73` and `:85`, in the staged plists only. `Resources/*.plist` keep today's literals.
- `CFBundleIdentifier` and `CFBundleURLTypes.0.CFBundleURLName` are stamped with the same values as today.
- `PDHostBundleIdentifier` is stamped into both plists.
- `PDKeychainService`, `PDSigningIdentity` (name or `adhoc`) and `PDBuildChannel` are stamped into the app plist.

Other script changes:
- **Stop the running app by path:** `pgrep -f "^$APP/Contents/MacOS/PaperDeck"`, replacing `:136-139`.
- **Build number:** `max(.build_number, installed CFBundleVersion) + 1` (`:50`).
- **Certificate expiry warning** below 60 days. The current certificate expires 2027-09-30 (distribution §0.4).
- **Missing identity:** print the certificate steps with the configured name and "Validity: 3650 days".

Runtime:
- `BuildIdentity.current` resolves `PDHostBundleIdentifier`, then the main bundle id with `.widget` stripped, then the default.
- It feeds `SharedPaths.bundleID` and `widgetBundleID` (`SharedPaths.swift:9-10`, which become computed), `Log.subsystem` (`Log.swift:7`), the keychain service (`MailSecretStores.swift:25`), the render suite (`PreviewRenderer.swift:11`) and the status-item autosave name (`StatusBarController.swift:32`). With no configuration, every one of these is the same string as today.
- The 8 queue labels (bindings I21) become `"\(Log.subsystem).<name>"`, which is also the same string.
- The signing row and widget footer show build instructions only for `channel == .local`. That covers `SetupAssistantView.swift:191-243` and `L10n+settings.swift:435-438,491-503`, with the certificate name interpolated.
- The app location check (`/AppTranslocation/` in the path, or outside `/Applications` and `~/Applications`) shows in onboarding and Diagnostics.

### 2.12 Safety floors (the same for every organization)
- These are code, not data, and cannot be configured:
  - AI off until an explicit Turn On (`SettingsStore.swift:138`);
  - mail off until an account passes Test & Save (`MailSettings.swift:215`);
  - people's mail defaults to `ask`;
  - unidentified person PDFs are held (`Intake.swift:66-70,87-88`);
  - the confidentiality guard (`MailConfidentiality.swift`);
  - the triage cap of 30 (`MailSettings.swift:184`).
- A preset or import can only choose stricter defaults for new senders.
- Neither the migration nor the CLI ever spawns claude or codex.
- Onboarding detects providers with zero quota only (`Doctor.swift:20-24` pattern, `spawnGate: { _ in false }`).
- Quick Start picks "no AI", and alert presets start unchecked.
- Organization policy texts are display-only and never reach an AI.
- Diagnostics are redacted: home becomes `~`, email local parts are masked, and paper titles, subjects and secrets are never included.
- Deep links `help/*` and `setup` only navigate.

---

## 3. Onboarding and Help Center

### 3.1 Launch sequence (the diff against `AppDelegate.swift:44-94`)

```swift
func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.setActivationPolicy(.accessory)
    ConfigMigration.runIfNeeded()                       // W0 call site; S1 body. Before SettingsStore registers.
    settings = SettingsStore()                          // creates settings.config (ConfigStore) too
    onboarding = OnboardingWindowController(settings: settings)
    HelpCenter.install(...)                             // routes for HelpButton before any window exists
    Task { await bootstrap() }
}
private func bootstrap() async {
    var preflight: PreflightResult?
    if rootOverride == nil, !settings.config.legacyOnboardingFlag,
       OnboardingGate.needsPreflight(.app(), databaseExists: fileExists(AppPaths.production().database), rootOverride: false) {
        guard let r = await onboarding.runPreflight() else { terminate(); return }   // Quit chosen
        preflight = r                                  // commit wrote library.path, agent.*, profile.*, org.*, language
    }
    let pending = LibraryPendingAction.load(.standard)  // Settings ▸ Library ▸ Change… (applies library.path first)
    let opened = await LaunchAlert.open(...)            // unchanged (+ volumeMissing buttons)
    guard let engine = opened else { ... }
    if let pending { try? await engine.replaceIndexFromLibraryFolder(starterPackIfEmpty: pending.kind == .startNew
                         ? settings.config.snapshot.field.starterCategories : nil); LibraryPendingAction.clear(.standard) }
    if let pack = preflight?.starterPack { _ = try? await engine.applyStarterPackIfPristine(pack) }   // before start()
    let state = AppState(engine: engine, settings: settings); self.state = state
    buildUI(state); onboarding.attach(state); state.start()
    let report = await engine.start()
    if let mismatch = report.libraryMismatch { await resolveMismatch(mismatch, engine) }   // alert, §3.3 P4
    refresher?.start(); flush pendingOpens (AppDelegate.swift:90-92)
    if !settings.setupCompleted { onboarding.show(resume: preflight == nil ? .welcome : .plan) }
}
```

**Gate:** `needsPreflight` holds when all of the following are true:
- `config.origin == fresh`;
- `setup.completed`, `library.path` and the DB are all absent;
- there is no `--gui-root`;
- `onboarding.legacy` is not set.

For the current user the gate is false, so the launch path is unchanged.

Edge cases:
- **Quit during preflight:** only harmless keys remain (`language` and `profile.*`, written at each Continue). `library.path` and `agent.*` are written only by the final commit, so the next launch restarts the preflight.
- **Cold Open With:** a PDF opened before the engine exists waits in `pendingOpens` (`AppDelegate.swift:149-150`). Welcome says "1 PDF is waiting — it will be imported when setup finishes."
- **Menus:** `LibraryMainMenu.build` (`LibraryWindowController.swift:157-208`) is refactored to build App, Edit, Window and Help menus without an `AppState`, so copy and paste work in the preflight text fields.
- **Activation policy:** `ActivationPolicy.update()` sets `.regular` while any library, onboarding or Help window is visible, and `.accessory` otherwise (today's pattern, `LibraryWindowController.swift:32,118-120`).

### 3.2 Window shell and modes

- **Window:** 820×600 (minimum 760×560), titled with a transparent title bar (`SetupWindowController.swift:38-46`). The left step rail shows ✓ done (a live check), ● current, ○ to do, – skipped and ⚠ problem.
- **Title:** "PaperDeck Setup". In revisit mode: "PaperDeck Setup Assistant".
- **Rail labels:** Welcome · About you · AI reading · Library · Daily plan · Mail (optional) · Import (optional) · Finish.
- **Footer:** (?) Help (opens the page's topic) · Back (⌘[) · Skip (only on Mail and Import) · Continue (Return) or Finish.
- **Language switch:** "English | 中文" writes `language` immediately. If the system language is Chinese, a chip "切换到中文？" appears; English stays the default.
- **Closing the window:**
  - In preflight it asks "Quit PaperDeck?" / "You can finish setup the next time you open PaperDeck." [Quit] [Keep Setting Up].
  - In live mode closing means "Finish later"; the window reopens at the next launch, as today (`SetupWindowController.swift:17-32`).

| Mode | When | Engine | Pages |
|---|---|---|---|
| preflight | gate true | none yet | P1–P4; the commit opens the engine |
| live | right after preflight, or `setup.completed == false` with a DB | open | P5–P8 (P1–P3 only if they were not done) |
| revisit | Help ▸ Setup Assistant…, menu bar, Settings ▸ General, `paperdeck://setup` | open | every page shows current values; nothing destructive; the rail is clickable |

### 3.3 Pages: content (en), live checks and writes

**P1 Welcome**
- **Content:**
  - "Welcome to PaperDeck"
  - • "Drop a PDF anywhere — get a reading card, a checklist and a deadline."
  - • "A daily reading plan with one reminder (default 11:00, change any time)."
  - • "Optional: AI summaries through your own Claude or ChatGPT subscription — no API keys."
  - • "Optional: reading requests from your email."
  - Box "Where PaperDeck lives": "PaperDeck lives in your menu bar and on a thin strip at the edge of your screen — there's no Dock icon. Help is always under Help ▸ PaperDeck Help." The illustration is drawn in SwiftUI (no assets).
  - Buttons: [Get Started] · [I'm moving from another Mac…] (preselects "Use an existing library" and offers "Import settings file…") · [Use a setup file from my lab or IT…] (opens `SettingsImportSheet`).
  - Link "Quick start with recommended defaults", with the footnote: "Creates your library in Documents/PaperDeck (macOS will ask for access), no AI for now, mail off. You can change everything later."
- **Live:** the count of `pendingOpens`.
- **Writes:** `language`. Quick Start commits field `general`, org `generic`, the Documents library and `aiDecision = none`, then jumps to Finish.

**P2 About you** (embeds S2's `ProfileEditor(context: .onboarding)`)
- **Content:**
  - "About you" / "This tunes reading cards and suggestions. Only the reader description is sent to your AI, with each paper."
  - "Research field": a grid of 11 cards (§2.4).
  - "Career stage": Master's · PhD · Postdoc · Faculty.
  - "How the AI should picture you" (≤200, single line) with [Reset to Default]; footer "Sent to your AI as part of the instructions for each paper."
  - "Research interests (optional)", with the field's placeholder; footer "Also used to pick relevant papers from email alerts."
  - "Institution AI policy":
    - "No specific policy — remind me to check my institution's guidance";
    - each built-in preset by name (e.g. "Washington University in St. Louis (WashU)");
    - "Other…" (name, short name, approved AI tools, policy link, "People's emails: Ask each time / Never send to AI").
  - Preview: "When a person (not a newsletter) emails you a paper, PaperDeck will say:" followed by the `personSenderWarning` sentence.
  - Notes: "Your field sets a new library's starter categories, the reading-card persona, example hints and suggested alert senders." / "The policy changes wording only — PaperDeck's safety defaults are the same for everyone."
  - Revisit mode with papers: [Add {field} Starter Categories] → "Added N categories. Nothing was renamed or removed."
- **Checks:** none on this page (`profileSet` when the keys are persisted).
- **Writes at Continue:** `profile.field`, `profile.stage`, `profile.readerDescription` (only if edited), `mail.criteria.researchInterests` (single source, `MailSettings.swift:71`), `org.preset`, `org.custom`.

**P3 AI reading**
- **Content:**
  - "AI reading (optional)" / "PaperDeck can summarize papers with your own Claude or ChatGPT subscription. It never uses API keys and spends no quota until you turn reading on."
  - Three cards: "Claude" · "ChatGPT (Codex)" · "Not now — use PaperDeck without AI".
  - Status lines per card:
    - "✓ Signed in · {plan} · {path}"
    - "Not installed"
    - "Installed — not signed in"
    - "Signed in with an API key — PaperDeck needs a subscription login"
    - "Checking…"
  - Not installed: "Install it in Terminal:" with the existing command box (`ClaudeAccountSection.installCommand`, `L.Pref.codexBrewCommand`) and [Open Terminal]. For Codex, also: "…or install the ChatGPT desktop app — PaperDeck finds the codex inside it."
  - Not signed in: "Sign in in Terminal:" with `CodexBinaryProbe.loginCommand` (`SettingsProbes.swift:120-126`) or the Claude `/login` hint, and [Open Terminal] [I've Signed In].
  - "Advanced ▸ Custom path…" writes `agent.cliPath` / `agent.codexPath`.
  - "Not now" body: "You still get a reading checklist, title/DOI/arXiv lookup, deadlines, the daily reminder and mail sorted by local rules. You won't get TL;DRs, summaries, AI categories or AI mail triage. Turn AI on any time in Settings ▸ AI."
  - [Turn On Claude Reading] / [Turn On ChatGPT Reading]: "Turning reading on lets PaperDeck read new papers automatically with your subscription."
  - Continuing with a provider selected but not turned on asks "Continue without AI for now?" [Continue Without AI] [Turn On…].
  - Policy line: `OrgStrings.aiPolicyLine`.
- **Live:** in preflight, `ProviderProbe.status` for both providers in parallel (zero quota). In live and revisit modes, the selected provider comes from `state.agentStatus` (`AgentQueue.swift:1307-1327`) and only the other one is probed. It re-checks on `didBecomeActiveNotification`, on [I've Signed In], and otherwise at most every 20 s.
- **Preselection** (fresh only; no writes): if both are ready, Claude (today's default, `SettingsStore.swift:140`); if exactly one is ready, that one; if none is ready but one is installed, that one; otherwise "Not now".
- **Writes:**
  - Selecting a card sets `agent.provider`. In revisit mode it goes through `AppState.selectProvider`, which has the same semantics as Settings ▸ AI.
  - Turn On sets `agent.mode`.
  - Every path records `onboarding.aiDecision`.

**P4 Library** (preflight; the library is chosen before it exists)
- **Content:**
  - "Your library" / "PaperDeck keeps every paper in a normal folder with its PDF and a card.json file, so you can move it or open it on another Mac later."
  - Options: "New library in Documents" (`~/Documents/PaperDeck`) · "New library in another folder…" · "Use an existing PaperDeck library…".
  - Before the system prompt: "macOS will ask to let PaperDeck use your Documents folder. Click Allow."
  - When `FileOps.isUbiquitous(~/Documents)` (`FileOps.swift:298`): "Your Documents folder syncs with iCloud, so files can be moved off this Mac. That's fine on one Mac; for a local copy use ~/PaperDeck instead." [Use ~/PaperDeck]
  - Classification lines:
    - cloud: "This folder is synced by a cloud service. Use PaperDeck on one Mac at a time and keep the folder downloaded."
    - removable or network: "PaperDeck works while this disk is connected."
    - other content: "PaperDeck will create a Papers folder inside."
  - Existing library:
    - found: "Found a PaperDeck library · about N papers. It will be indexed when you continue."
    - parent folder picked: "Did you mean …/PaperDeck?" [Use It]
    - nothing found: "No PaperDeck library here." [Choose Another] [Create a New Library Here]
  - Commit errors are shown inline, not as modal alerts:
    - denied: "PaperDeck can't use this folder. Allow access in System Settings ▸ Privacy & Security ▸ Files and Folders, or choose another folder." [Open Privacy & Security] [Choose Another Folder] [Retry]
    - missing parent or read-only: choose again.
  - After the commit: "Opening your library…"
- **Live:** `LibraryProbe.status` (`SettingsProbes.swift:82-85`) at the moment of the commit, which is when macOS shows the prompt; `LibraryInspector.inspect`.
- **Writes:** `library.path`, plus everything held back from earlier pages, in one commit. `starterPack` is the field's starters only for a new library.
- **Revisit mode:** the current path, status and paper count; [Change Location…] → S2's flow (§3.6); [Restart PaperDeck Now] when a change is pending.
- **Mismatch alert** (from §3.1, also reachable from revisit):
  - Message: "This folder contains a different PaperDeck library" / "PaperDeck's index belongs to another library (N papers). Nothing was changed, to avoid mixing them."
  - Buttons: [Open This Library] (`replaceIndexFromLibraryFolder(nil)` then `start()`) · [Go Back to {previous}] (when `library.previousPath` exists; relaunch) · [Choose Another Folder…] · [Quit].

**P5 Daily plan & reminder** (live)
- **Content:**
  - The existing `BudgetPicker`, `WeekdayPicker` and `ReminderTimePicker` (`SettingsComponents.swift:108-170`), and the notification row of `SetupNotificationStep` (`SetupAssistantView.swift:349-394`, made internal) with `L.Pref.notificationsWhy`.
  - "Open PaperDeck at login (recommended — it lives in the menu bar)" toggle, bound to `LaunchAtLogin.set` (`SettingsProbes.swift:211-214`). Hint: "macOS will show 'Background item added' — that's PaperDeck." When approval is required: [Open Login Items].
  - App location ⚠: "Move PaperDeck to your Applications folder — the widget and Open at Login need it." [Show in Finder] [Quit]
- **Checks:** `notificationsAllowed`, `launchAtLogin`, `loginItemNeedsApproval`, `appInApplications`, `notTranslocated`.

**P6 Mail (optional)**
- **A.** "Do you want PaperDeck to look at your email?" / "PaperDeck reads only emails from senders you list, keeps them on this Mac and never sends mail." [Set Up Now] [Only When I Drag Emails In] (→ `dragOnly` and the drag tip) [Not Now].
- **B.** "Where does your mail live?":
  - "Work or school Microsoft 365 (Outlook)" → C
  - "Gmail (personal)"
  - "Google Workspace (work or school Gmail)"
  - "iCloud Mail"
  - "Personal Outlook.com / Hotmail"
  - "Another provider (Yahoo, Fastmail, university IMAP…)"
  - "A folder that already receives .eml files"
- **C.** "Can you use Power Automate at your organization?" [Yes] [Not Sure — Try It] → the Power Automate form and tutorial; [No, It's Blocked] → tutorial `mail-m365-blocked`.
- **Panel:** the embedded `TutorialView` for the route's topic (§3.4), with live steps. Its primary buttons open `MailAddAccountSheet(state:editing:nil, initialTemplate: MailAccountTemplate(source:))` (`MailAddAccountSheet.swift:39-41`). The sheet's Test & Save and "Turn On Mail & Close" (`:130-136`) remain the only way an account becomes active.
- **D.** "Who sends you papers?":
  - An address field for an advisor or colleague. The kind is advisor or person; the AI policy is `org.peopleDefault`; the policy sentence shows beside it.
  - "Suggested alert senders for {field}", all **unchecked**: "Alert senders are read by AI automatically (they're public newsletters). People's emails always ask first."
- **E.** [Turn On Mail] is enabled only when at least one account is not `needsSetup`. Live line: "Synced 2 min ago · 3 emails captured" (`MailSyncActor.swift:5-25`).
- **Checks:** `oneDriveBusinessPresent`, `cloudRootPresent`, `mailFolderExists`, `mailAccountExists/Ready/AuthFailed`, `mailFirstCapture`, `mailEnabled`, `mailNoNotEmailFiles`, `sendersAdded`.
- **Writes:** `onboarding.mailDecision`. Everything else is saved by the existing sheet and editors.

**P7 Import (optional)**
- **Content:**
  - "Bring in papers you already have"
  - The existing `SetupImportStep` (`SetupAssistantView.swift:415-523`, made internal), with the default folder `import.lastFolder ?? ~/Downloads` (replacing `:499`).
  - Hint: "e.g. your Downloads folder or the folder where you keep PDFs. Zotero users: ~/Zotero/storage (PDFs only, not your notes)."
- **Checks:** the existing `L.Pref.importDone` result line.

**P8 Finish**
- **Content:**
  - "You're set"
  - A live summary, each line with a [Change] link:
    - "✓ Library ~/Documents/PaperDeck · 12 papers"
    - "✓ AI: Claude (Max)" or "– AI: not now"
    - "✓ Reminder 11:00 · notifications allowed"
    - "– Mail: not set up"
    - "✓ Imported 12"
    - for `channel == .local` only: "Signing: certificate '{name}'" or the developer hint
  - "Find PaperDeck here": the menu-bar icon, the edge strip, and Help ▸ PaperDeck Help.
  - [Take the 1-Minute Tour] (primary) · [Open Library] · checkbox "Show Getting Started on Today" (on).
- **Finish gating:** the library is usable and the AI page has a decision. This is the same minimum as today (`SetupAssistantView.swift:15-16`).
- **Writes:** `setup.completed = true`, `onboarding.version = 1`, `onboarding.completedAt`, `guide.checklist.dismissed = !checkbox`.

### 3.4 Help Center (Help ▸ PaperDeck Help, ⌘?)

**Window:**
- `HelpWindowController`: 880×620 (minimum 720×520), a `NavigationSplitView`, and `.searchable` (`GuideSearch`: en and zh tokens over titles, keywords and steps).
- Every page has:
  - a "Status now" header (✓, in progress, or ⚠ with the reason);
  - Related links;
  - "Still stuck? Troubleshooting · Copy Diagnostics".
  - Each topic also shows its `lastReviewed` date.

**Getting Started checklist (live).**
- It is always available in the Help Center.
- A compact `GettingStartedCard` appears above `TodayHeader` (`TodayView.swift:47-50`) and in the empty-library drop target (`EmptyStateView.swift:141`), and a menu-bar item "Getting Started (n of m)…" appears, when all of these hold:
  - `config.origin == fresh`;
  - `guide.checklist.dismissed` is false;
  - a required item is still open.

| id | Title | Check | Required | Actions |
|---|---|---|---|---|
| library | Your library folder is ready | `libraryUsable` (cloud → ✓ plus the note "one Mac at a time") | yes | Settings ▸ Library · `library-location` |
| first-paper | Add your first paper | `hasPapers(1)` | yes | Add PDF… · Show the drop strip |
| drop-strip | Drop a PDF on the edge strip or the menu-bar icon | `activity(panelDrop ∨ menuBarDrop)` | no | Show Me |
| open-card | Open a paper's reading card | `openedPaper` (`Paper.openedAt`, `Operations.swift:60,194-196`) ∨ `activity(openedDetail)` | no | Open Today |
| ai | Choose AI reading — or go without | `aiDecided` (⚠ if on but not ready, with the reason) | yes | Settings ▸ AI · `ai-setup` |
| reminder | Allow the daily reminder | `notificationsAllowed` (n/a when the reminder is off) | no | Allow / Open Notification Settings |
| login | Open PaperDeck at login | `launchAtLogin` | no | toggle |
| widget | Add the desktop widget | `widgetPlaced`, falling back to `widgetRegistered` plus one manual tick | no | Settings ▸ Widget · `fix-widget-missing` |
| mail | Connect your mail | `mailAccountReady(any)`; hidden when `mailDecision ∈ {skipped, dragOnly}` (a "Not using mail · Set up" row instead) | no | `connect-mail` |
| senders | Tell PaperDeck who sends you papers | `sendersAdded` (shown once an account exists) | no | Settings ▸ Mail ▸ Senders |
| backup | Keep a settings backup | `settingsExported` (shown at ≥10 papers) | no | Export Settings… |

**Feature tour** (7 pages; SwiftUI illustrations; [Show Me] drives the real UI; a "Try it" line ticks live).
1. Drop papers anywhere → `armDropPanel(10)`
2. Today, the plan and Skip Today → `showToday`
3. Reading card and checklist (⌘I) → open the first paper
4. AI reading: quota safety and what is sent → Settings ▸ AI
5. Mail: requests become cards, then merge → `showMail`
6. Reminder and widget → Settings ▸ Widget
7. Your data: a plain folder, card.json, moving Macs → reveal the library

The tour opens automatically once, after Finish on a fresh install. It writes `guide.activity.tourCompleted`. The menu-bar Show Me uses `statusItem.button?.performClick(nil)`.

**Tutorials** (each step is verified by `check`, `impliedBy` (a later step confirms an external step) or `manual(reason)`; at most one manual step per topic, enforced by a lint):

| Topic | Steps → verification |
|---|---|
| `mail-m365-power-automate` (any tenant) | 1. Install OneDrive and sign in with your work/school account → `oneDriveBusinessPresent` (the org hint is a preference only). 2. Create "PaperDeck Mail" → `mailFolderExists`. 3. Build the flow at {portal}, or import the ready-made package (the existing `MailPowerAutomateGuide` embedded) → `impliedBy(6)`. 4. Add the folder as an account → `mailAccountExists(.m365PowerAutomate)`. 5. Turn on Mail → `mailEnabled`. 6. First email file arrives → `mailFirstCapture(.m365PowerAutomate)`. 7. Files are complete emails → `mailNoNotEmailFiles` (existing fix, `MailInboxView.swift:225-253`). Notes: the trigger folder is Inbox, so change it if Outlook rules file alerts elsewhere; government or China tenants use another portal (ask IT). |
| `mail-m365-blocked` | Drag emails from Outlook (`manual("no local signal until you drag")`; auto-✓ on `emlImportedManually`) → Apple Mail rule → `mail-folder-sources` → forward alerts to Gmail or iCloud (alerts only, not people's mail) |
| `mail-outlook-com` | "Microsoft no longer lets other apps sign in to Outlook.com mail with an app password, so PaperDeck can't connect directly." Routes: Apple Mail rule → folder / forward alerts to Gmail or iCloud / drag .eml. Check: `mailAccountReady(.folder ∨ IMAP)`. |
| `mail-gmail` | 2-Step Verification → `impliedBy(3)`; app password (myaccount.google.com/apppasswords) → `impliedBy(3)`; Test & Save → `mailAccountReady(.imapGmail)`; optional label and filter → `manual("the label lives in Gmail")`; first sync → `mailFirstCapture` |
| `mail-google-workspace` (Beta) | Try `mail-gmail`. On `mailAccountAuthFailed`: "Your organization may have turned off app passwords." Then Apps Script → Drive folder (`cloudRootPresent(.googleDrive)`, `mailFolderExists`, `mailFirstCapture(.folder)`) with `copyGenerated(.googleAppsScript)`, forwarding alerts, or dragging. |
| `mail-icloud`, `mail-other-imap`, `mail-drag-only` | app password → Test & Save → first sync; drag tip |
| `mail-folder-sources` | Apple Mail rule (Beta; Save Script…), Apps Script, Dropbox or iCloud Drive folders → `mailFolderExists`, `mailAccountExists(.folder)`, `mailFirstCapture` |
| `mail-senders-and-ai` | kinds, AI policy, the policy sentence, alert presets |
| `connect-mail` | the router (the same as P6 B) |
| `ai-setup`, `ai-without`, `ai-switch-account` | install / sign in / turn on (`providerInstalled`, `providerSignedIn`, `aiDecided`). Switching accounts: `claude` then `/logout` and `/login`; `codex logout` and `codex login` (V6); then [I've Signed In]. Notes: a usage-limit pause from the previous account clears when its time passes; API-key logins are refused by design. |
| `library-location`, `library-two-macs` | location, cloud and external-disk notes; "One Mac at a time: quit on the other Mac first; after switching use Settings ▸ Library ▸ Rebuild index." |
| `move-to-new-mac` | Old Mac (`manual("happens on the other Mac")`): quit, Export Settings, copy the library folder or keep it in a cloud folder. This Mac: 1. Put PaperDeck in Applications and open it → `appInApplications ∧ notTranslocated`. 2. "Use an existing library" → `libraryHasManifest ∧ hasPapers(1)`. 3. Import settings → `settingsImported`. 4. Sign in to Claude or ChatGPT and turn AI on → `aiDecided`. 5. Re-enter IMAP app passwords → `imapPasswordsPresent` (attributes only, `Doctor.swift:113-124`). 6. Notifications, widget, Open at Login. 7. Re-index full text → `fullTextIncomplete == false`. |
| `profile-field-institution` | Settings ▸ Profile → `profileSet` |
| `install-for-labmate` | Sender: `./build_app.sh --package` (never share the certificate). Recipient: move to Applications before the first launch → `appInApplications`; Privacy & Security ▸ Open Anyway → `notQuarantined`; then setup. |
| `build-from-source` | Command Line Tools, a self-signed certificate (10-year validity), `build.local.env`, `./build_app.sh` (not `--dev` for a daily install) → `stableSigning` |

**Troubleshooting** (symptom → what PaperDeck sees now → fix; entries whose check is in the problem state are badged "Applies now"):
- `fix-documents-access`
- `fix-library-missing` ("don't switch to ~/Papers")
- `fix-library-mismatch`
- `fix-cloud-evicted`
- `fix-cli-not-found` (custom path; non-zsh shells)
- `fix-cli-not-signed-in`
- `fix-cli-api-key`
- `fix-usage-limit`
- `fix-notifications`
- `fix-widget-missing` (move to Applications, launch once, Repair Registration)
- `fix-login-item`
- `fix-app-blocked`
- `fix-mail-auth-failed` (Outlook.com and Workspace notes)
- `fix-mail-not-email-files`
- `fix-mail-onedrive-missing`
- `fix-search-after-move`
- `fix-two-macs-diverged`

**Diagnostics:**
- The facts come from `SetupFacts` plus today's `--doctor` facts (`Doctor.swift:13-50`): version and build, bundle id, location, signing, channel, library path and status, paper count, both providers' status (zero quota), notifications, login item, widget, mail accounts (kind, status, last sync, password present yes/no), and the config summary (org, field, origin, dateOrder).
- [Copy Diagnostics…] shows a preview of `DiagnosticsReport.render(redact: true)`.

### 3.5 Live-state model
- **`SetupFacts`** (Config/Guide) is filled by the app's `SetupFactsCollector` (`@Observable @MainActor`) through `FactSources`:
  - `LiveFactSources` wraps the existing nonisolated probes (`SettingsProbes.swift:12-234`, `ProviderProbe`, `ReminderService.shared?.authorization`, `CloudRootLocator`, `MailSettingsIO.folderState`, keychain attribute checks).
  - `FakeFactSources(scenario:)` serves renders and selftests: fresh, legacy, codexOnly, noAI, allReady, mailError, m365Contoso.
- **Refresh cadence:** facts are probed only while a guide view is visible (`activate(needs:)` / `deactivate`):
  - file-system facts every 5 s;
  - the widget every 30 s;
  - the unselected provider on demand, with a 20 s throttle;
  - also on `didBecomeActiveNotification`.
  The Today card uses only cheap facts with no I/O (the snapshot, `agentStatus`, settings, `mailSnapshot`).
- **Isolation:** `WidgetCenter.getCurrentConfigurations` is wrapped in a `nonisolated` continuation, because a MainActor-inferred callback would run off-main (`build_app.sh:55-58`). The build script's warning grep gains `getCurrentConfigurations`.
- **Activity:** `GuideActivity.record(_:)` stores first-use dates in `guide.activity`. The call sites are:
  - `DropPanelController.swift:687` (panelDrop);
  - `StatusBarController.swift:108` (menuBarDrop);
  - `AppDelegate.swift:156` (openWith);
  - `PaperDetailView` onAppear (openedDetail);
  - `AppState+Mail.swift` manual import (emlImported).
- **Evaluation:** `GuideEvaluator` is pure. `unknown` is never shown as done, and a `problem` always carries a reason and a fix.

### 3.6 Settings additions (S2)
- **Settings ▸ Profile** (new `SettingsTab.profile`, `SettingsWindowController.swift:40-41`):
  - **You:** field, stage, reader description with [Reset] and a counter "n/200", a disclosure "Show the instructions sent with each paper" (read-only `systemPrompt(for:)`), and research interests.
  - **Starter categories:** "{field}'s suggested categories: …" and [Add Missing Categories…] (confirmation: "Adds N categories. Nothing is renamed or removed.").
  - **Institution:** a picker, the custom editor, and a read-only preview of `personSenderWarning` and `policyNote`.
    - Legacy note: "Set to WashU because this Mac used PaperDeck before institutions were configurable. Change it any time." This text lives in the washu preset's texts, keyed by note.
    - Footer: "This changes wording only. Safety defaults (AI off until you turn it on, people's emails ask first) are the same for everyone." Plus `HelpButton(.profileFieldInstitution)`.
- **Settings ▸ General** (`SettingsView.swift:71-77`; the height grows from 380 to about 560, `SettingsWindowController.swift:68`):
  - "Help & Setup": [PaperDeck Help] [Setup Assistant…] (the same action as today's button) [Feature Tour].
  - "Move to another Mac": [Export Settings…] [Import Settings…], with the note "Exports preferences, the sender list, reading criteria and mail accounts — never passwords or app passwords. After an import, AI reading and Mail stay off until you turn them on." and `HelpButton(.moveToNewMac)`.
- **Export sheet:**
  - Section checkboxes: Profile & institution · General · Plan & reminder · AI preferences · Library preferences · Mail senders & criteria · Mail accounts (no passwords) · Drop strip.
  - Personal data: "Mail accounts include your mailbox addresses"; "Crossref contact email" is off by default.
  - Default name: "PaperDeck Settings {date}.json".
- **Import sheet:**
  - Header: "From PaperDeck {app}, exported {date}".
  - Per-section checkboxes and per-key diffs ("Reminder: 11:00 → 09:30").
  - Warnings: needs app password; folder remapped or unresolved; CLI path dropped.
  - Clamps: "Prof. Smith: 'Always send to AI' imported as 'Ask each time'", with the opt-out checkbox.
  - The reader description shown verbatim, with "Use this description".
  - Footer: "AI reading and Mail stay off. Turn them on when you're ready." [Cancel] [Import].
  - Writes `transfer.importedAt`.
- **Settings ▸ Library** (`LibrarySettingsTab.swift:37-84`). [Change…] → `LibraryFolderPicker` → inspect:
  - the same library id: "This is your current library (moved?). PaperDeck will use it from now on." [Use This Folder];
  - a different library: "Found another PaperDeck library (about N papers). Your current library stays where it is and you can switch back later. PaperDeck backs up its index first." [Open This Library];
  - empty or other content: [Start a New Empty Library Here], plus "To move your current library: quit PaperDeck, move the folder in Finder, then choose it here."
  Then the pending action and `library.previousPath` are written and [Restart Now] runs `Relaunch.now()`. Also new: [Re-index Full Text] (`reindexMissingFullText`, a result line) and HelpButtons.
- **Settings ▸ Widget:** a channel-aware footer and [Repair Registration], which runs `lsregister -f -R -trusted <bundle>` and `/usr/bin/pluginkit -a <appex>`, then re-probes. Both binaries are system paths (distribution §3.4).
- **Settings ▸ Mail:**
  - the two-section chooser;
  - organization- and field-aware strings;
  - the date-order picker in Reading criteria: "Dates like 3/10 mean: March 10 (month first) · 3 October (day first) · Follow my Mac's region";
  - the triage model catalog;
  - the Apple Mail rule disclosure in the Folder form.
- **Settings ▸ AI:** HelpButtons, and the connection-test model from the catalog.

### 3.7 Entry points and "?" placements

| Entry | Where |
|---|---|
| Main menu **Help**: PaperDeck Help ⌘? · Getting Started · Feature Tour · Setup Assistant… · — · Troubleshooting · Diagnostics…; `NSApp.helpMenu = help` | `LibraryWindowController.swift:139-208` |
| Menu-bar "Help & Setup ▸" (PaperDeck Help, Getting Started (n of m) for fresh installs, Setup Assistant…, Troubleshooting) before Settings… | `StatusBarController.swift:193-230` |
| Settings ▸ General "Help & Setup" | §3.6 |
| Deep links `paperdeck://help`, `paperdeck://help/<topic>` (`^[a-z0-9-]{1,48}$`), `paperdeck://setup` | `DeepLink.swift:5-58`, `URLRouter.swift` |
| Today card, empty library ("New here? Take the tour") | `TodayView.swift:47-50`, `EmptyStateView.swift:141` |
| AI banners: extra action "How to Fix" → `fix-cli-*` | `Banners.swift:77-110` |
| Launch alert: `showsHelp` → `fix-documents-access` / `fix-library-missing` | `AppDelegate.swift:120-136` |
| Mail set-up notice | `MailInboxView.swift:195-219` |

`HelpButton(topic)` wraps SwiftUI's `HelpLink` and is placed at:
- Settings ▸ AI account header (`ai-setup`) and master section (`ai-without`);
- Library location (`library-location`) and Rebuild (`move-to-new-mac`);
- Widget status (`fix-widget-missing`);
- Mail accounts (`connect-mail`);
- each chooser row (its route topic);
- the sender rule AI policy and the Triage section (`mail-senders-and-ai`);
- Profile ▸ Institution (`profile-field-institution`).

### 3.8 Topic id catalog (the contract between S2, S3 and S4; the docs anchors equal these ids)

- **Getting started:** `getting-started`, `tour`, `diagnostics`.
- **Mail:** `connect-mail`, `mail-m365-power-automate`, `mail-m365-blocked`, `mail-outlook-com`, `mail-gmail`, `mail-google-workspace`, `mail-icloud`, `mail-other-imap`, `mail-folder-sources`, `mail-drag-only`, `mail-senders-and-ai`.
- **AI:** `ai-setup`, `ai-without`, `ai-switch-account`.
- **Library:** `library-location`, `move-to-new-mac`, `library-two-macs`.
- **Profile:** `profile-field-institution`.
- **Distribution:** `install-for-labmate`, `build-from-source`.
- **Troubleshooting:** `fix-documents-access`, `fix-library-missing`, `fix-library-mismatch`, `fix-cloud-evicted`, `fix-cli-not-found`, `fix-cli-not-signed-in`, `fix-cli-api-key`, `fix-usage-limit`, `fix-notifications`, `fix-widget-missing`, `fix-login-item`, `fix-app-blocked`, `fix-mail-auth-failed`, `fix-mail-not-email-files`, `fix-mail-onedrive-missing`, `fix-search-after-move`, `fix-two-macs-diverged`.

Organization notes: if `org.approvedAITools` or `org.policyURL` is set, the `profile-field-institution` page shows an "{name} notes" box built from the preset data.

---

## 4. Tutorials and docs (S4)

All docs are institution-neutral. WashU appears only in `docs/institutions/washu.md`. The anchors equal the §3.8 topic ids.

1. **`docs/USER_GUIDE.md`** (English, new):
   - What PaperDeck is and where it lives (menu bar, edge strip, window, widget, Finder Open With, Services).
   - Install:
     - (a) received the app: move it to Applications, then Open Anyway;
     - (b) build from source → `docs/BUILDING.md`.
   - First run, page by page; Quick Start; re-running it from Help ▸ Setup Assistant.
   - Everyday use: drop, Today, cards and checklist, deadlines, Skip Today, reminder, widget, search.
   - AI reading: Claude, ChatGPT (Codex), or none; quota safety; what is sent; switching accounts (`ai-switch-account`).
   - Your field and institution (presets, custom, what the policy changes).
   - Library: location, cloud folders, external disks, existing library, moving, two Macs (one at a time), rebuild, re-index.
   - Mail: overview and safety; the routes (Microsoft 365 with Power Automate, Microsoft 365 blocked, Outlook.com, Gmail, Google Workspace, iCloud, other IMAP, folder sources, drag only); senders and AI policy; merging.
   - Moving to another Mac; giving PaperDeck to a labmate.
   - Privacy and safety summary.
   - Troubleshooting → `TROUBLESHOOTING.md`.
   - Appendix: the user-facing settings keys, `--doctor --mail-only`, `--config`; institution notes → `docs/institutions/`.
2. **`README.md`** (Chinese, refreshed):
   - An introduction that names no institution.
   - 快速开始: 获取应用（他人发送 / 自行构建）→ 首次启动向导 → 拖入论文.
   - 入口: "默认 11:00，可修改" (README `:3,12,96`).
   - 帮助中心 (⌘?).
   - AI 解读（Claude / ChatGPT / 不使用 AI）.
   - 论文库与多台 Mac.
   - 邮件: the generic route table, plus "机构示例见 docs/institutions/ 目录".
   - 隐私与机构 AI 规定.
   - 构建（`build.local.env` 变量）.
   - 命令行 (unchanged, plus `--config`).
   - 常见问题 → TROUBLESHOOTING.
   - 文档索引.
   - Remove the WashU lines at `README.md:104-121,145`, and turn `~/Desktop/Paper_reading` (`:33`) into a neutral example.
3. **`docs/TROUBLESHOOTING.md`** (bilingual):
   - A short hand-written introduction: "open Help ▸ Troubleshooting in the app; it checks your Mac live".
   - `<!-- BEGIN GENERATED: troubleshooting en -->…<!-- END … -->` and the same for zh. Produced by `PaperDeck --guide-export DIR --lang en|zh` from `GuideCatalog`, and kept in sync by a test in W2.
   - Hand-written "Developer issues": certificate expiry, ad-hoc resets, the CLT path, `PAPERDECK_DEV_DIR`.
4. **`docs/guides/POWER_AUTOMATE.md`** (en, generic, any work or school tenant):
   - What the flow does and its privacy (only allowlisted senders, files on your own OneDrive).
   - Requirements: Power Automate allowed, OneDrive for work/school installed and signed in on this Mac.
   - Step 1, OneDrive check: the business root, not Personal.
   - Step 2, the "PaperDeck Mail" folder.
   - Step 3a, import the package (Settings ▸ Mail ▸ Add Account ▸ Microsoft 365 ▸ Save Package…, or `--mail-flow-package OUT.zip --from-settings`).
   - Step 3b, build it by hand: trigger "When a new email arrives (V3)" with the From filter, "Export email (V2)", OneDrive "Create file" `.eml` with File Content (`PowerAutomatePackage.swift:54-55,286`; `L10n+mailSettings.swift:205-216`).
   - Step 4, add the folder account. Step 5, turn on Mail. Step 6, test from an allowlisted address.
   - Troubleshooting: not complete emails; flow failures; DLP blocks; Inbox versus rule-filed folders; Personal versus business OneDrive; delete processed files; government or China portals.
   - If it's blocked → the alternatives.
5. **`docs/guides/MOVE_TO_ANOTHER_MAC.md`**:
   - On the old Mac: quit, Export Settings, copy the library with `ditto`, or keep it in a cloud folder (one Mac active at a time).
   - On the new Mac: install, choose "Use existing library", import settings, sign in to AI and turn it on, re-enter app passwords, check that the OneDrive or cloud folder is detected again, grant permissions, add the widget, Re-index Full Text.
   - What does not travel: the keychain, mail cards and AI run history (DB-only), pauses.
   - A different macOS username: paths are re-resolved on import.
6. **`docs/guides/DIFFERENT_ACCOUNT.md`**:
   - Another Claude or ChatGPT account on the same Mac (log out and log in; API keys are refused; pauses).
   - Another mailbox (add or remove accounts; app passwords live in this Mac's keychain).
   - Another Microsoft 365 tenant (a new flow in that tenant; the OneDrive root is detected automatically).
   - Another institution (Settings ▸ Profile).
   - Another person on the same Mac (each macOS user has separate settings, keychain and library).
7. **`docs/institutions/washu.md`** (en and zh) and `docs/institutions/_template.md`:
   - The WashU OneDrive root name, Power Automate as experienced, Gmail as the fallback for alerts, Claude Edu and ChatGPT Edu (moved from `README.md:104-121,145`), and how to pick the preset.
   - A pointer to the `docs/MAIL_DESIGN.md` tenant research, which stays as history (bindings R5–R7).
8. **`docs/BUILDING.md`**:
   - Prerequisites (macOS 26, CLT).
   - `build.local.env.example`, every `PAPERDECK_*` variable and flag, `--print-config`.
   - The certificate (Keychain Access ▸ Certificate Assistant, Code Signing, **3650 days**), the ad-hoc trade-offs.
   - `--package` and what recipients need, `--no-install`, `~/Applications`.
   - "Changing the bundle id starts a fresh settings domain, keychain service, permissions and widget — settings don't carry over".
9. **`docs/INSTALL_RECIPIENT.md`** (en and zh; `--package` copies it to `dist/INSTALL.md`): distribution §3.3 steps 1–5.
10. **`docs/ARCHITECTURE-CONFIG.md`**: the §2.1 rules, the key table (§2.5), the migration and how to add a preset. **`docs/DESIGN.md`** gets a short new "Onboarding & Help" section; the historical sections stay.

---

## 5. Implementation slices

### 5.1 Order

```
W0 Contracts & guardrails (1 agent, serial, behavior-neutral)  ──▶  merge
        │
        ├── S1 Config engine + Core ports      ┐
        ├── S2 App settings, mail & strings    │  4 agents in parallel, disjoint files,
        ├── S3 Onboarding & Help Center        │  compile against W0 signatures
        └── S4 Identity, CLI tools, content & docs ┘
        │
merge order: S1 → S4 → S2 → S3 (each rebased; only Package.swift is shared and S1 owns it)
        │
W2 Integration & verification (1 agent): lint tests, docs sync, §6 plan, fix-ups via owners
```

Rules for every agent:
- Edit only the files you own.
- If you need a change in someone else's file, append a request to `portability/requests.md` (owner, file, change, reason). The owner or W2 applies it.
- Never run claude or codex. That excludes `--agent-smoke`, `--selftest … --agent claude|codex`, `--doctor` without `--mail-only`, `--render` without `--mail-only` or `--guide-only`, and `--agent-argv`.
- Never run `./build_app.sh` in a way that installs over `/Applications/PaperDeck.app`. Use `swift build` and `./build_app.sh --no-install`.
- Never use `--dev` on the user's account, and never change the user's defaults domain.

### 5.2 W0: contracts and guardrails (must land first; no user-visible change)
1. **Golden fixtures produced mechanically on today's code** (before any L10n edit):
   - Add `CLI/SelfTestStrings.swift`: `--selftest strings --write FILE | --check FILE [--lang en|zh]`. It evaluates the L10n accessors for the 13 organization keys, the 4 field keys (§2.7) and consentNote for "Claude" and "ChatGPT", with `LangStore.lang` set per language. It also records the sha256 of `CardSchema.systemPrompt`. It runs on the bare `.build/debug/PaperDeck` binary; nothing is spawned.
   - Commit `Tests/PaperDeckCoreTests/Fixtures/config/org-strings-v1.json` and `card-system-prompt-v1.txt`.
   - Commit synthetic `legacy-washu-domain.plist`, shaped like the current user's domain:
     - `setup.completed` true, `agent.mode`/`agent.provider` claude, `library.path` `/Users/example/Documents/PaperDeck`;
     - `mail.enabled` true;
     - an account with id `washu-pa`, kind folder, displayName "WashU (Power Automate)", folderPath `/Users/example/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail`;
     - senders: an advisor `jsmith@wustl.edu` with `ask`, plus `preset-google-scholar` and `preset-biorxiv`;
     - criteria with interests;
     - no `language` key (registered `en`).
   - Commit `fresh-domain.plist` (empty).
   - Add `Tests/PaperDeckCoreTests/Config/GoldenBaselineTests.swift`: the literal equals the fixture; `SenderRule.presets` ids are frozen in order.
2. **`--seed-plist FILE` for `--render`** (`PreviewRenderer.swift:48-51`): after wiping the render suite, load the plist into it instead of `MailRenders.seedDemo`. Then capture baseline renders into a scratch folder (not committed) with today's code:
   `--render $BASE/{en,zh} --root $SCR --mail-only --seed-plist legacy-washu-domain.plist --lang en|zh --appearance light`.
   Keep the W0 binary as `$SCR/PaperDeck-W0`.
3. **Package.swift:** add the `PaperDeckConfig` target and its dependencies (§2.1).
4. **Skeletons with real signatures** (§5.3) and **legacy-only bodies**:
   - `ConfigResolver` always returns washu, lifeSci and mdy.
   - `ConfigMigration.runIfNeeded` is a no-op returning `.legacy`.
   - `OrgStrings` returns the washu texts, **copied verbatim** into `OrganizationPresets.washu` now; L10n still holds its own copy.
   - `FieldPresets.lifeSciencesCompBio` is complete; `general` is a copy for now.
   - `CloudRootLocator` and the portability types are stubs.
   - The Guide model types are complete; `GuideCatalog.topics` is `[]`; the `GuideContent` files are empty.
5. **Core ports** (complete and behavior-neutral):
   - `CardPromptProfile` with `.legacyCompBio` and `systemPrompt(for:)` (literal short-circuit; render returns the literal for now);
   - `Engine.Dependencies.loadCardProfile` (the last defaulted init parameter), used at `AgentQueue.swift:1015`;
   - `MailAccount.source`, with CodingKeys and lenient decoding;
   - `SlashDateOrder` and `MailSettings.dateOrder`/`Keys.dateOrder` (load: absent → mdy; not used by the heuristics yet);
   - `AgentQueue.testConnection(provider:model:)` (`model ?? kind.connectionTestModel`);
   - stubs for StarterPack, LibraryIdentity, LibraryInspector, replaceIndex, reindexMissingFullText and ProviderProbe.
6. **Shared:** `BuildIdentity` with fallback-only resolution (today's constants, channel `.local`). `SharedPaths.bundleID` and `widgetBundleID` are computed from it and return the same values.
7. **App stubs:**
   - `App/ConfigStore.swift` (reads the snapshot; setters write keys);
   - `SettingsStore.config`;
   - `LangStore.org` and `LangStore.field`;
   - `Views/Help/HelpButton.swift`, with `HelpCenter` hooks as no-ops;
   - `Views/Onboarding/OnboardingPage.swift`, `App/Relaunch.swift` (no-op);
   - `Views/Settings/ProfileEditor.swift`, `SettingsImportSheet.swift` and `LibraryFolderPicker.swift` (empty views or functions);
   - `CLI/SelfTestSettings.swift`, `SelfTestOnboarding.swift`, `GuideExport.swift` and `ConfigCLI.swift`, returning "not implemented";
   - dispatch in `SelfTest.swift:64-67` and `CLIRunner.swift:50-77`.
   - AppDelegate: the `ConfigMigration.runIfNeeded()` call before `SettingsStore()`, and `Engine.open(paths:deps: .init(loadCardProfile: { ConfigResolver.cardPromptProfile() }))` at `:66`.
8. **Exit criteria:**
   - `swift build` and `./test.sh` are green.
   - `--selftest strings --check` passes in en and zh.
   - Renders seeded with `--seed-plist` on the W0 build are byte-identical to the baseline.
   - The diff contains no user-visible change.

### 5.3 Cross-slice contracts (exact signatures; W0 creates them; owners implement)

```swift
// ===== PaperDeckShared (S4) =====
public struct BuildIdentity: Sendable, Equatable {
    public enum Channel: String, Sendable { case local, distribution }
    public static let defaultBundleID: String                 // "com.yijiang.paperdeck"
    public static let defaultSigningIdentityName: String      // "PaperDeck Local Signing"
    public var bundleID: String, widgetBundleID: String, keychainService: String, logSubsystem: String
    public var signingIdentityName: String?                   // PDSigningIdentity; "adhoc"; nil = unknown
    public var channel: Channel                               // PDBuildChannel ?? .local
    public static let current: BuildIdentity
    public static func resolve(info: [String: Any]?, mainBundleID: String?) -> BuildIdentity
}
// SharedPaths: public static var bundleID: String { BuildIdentity.current.bundleID }  (+ widgetBundleID)

// ===== DeepLink (S3) =====
case help(topic: String?)        // paperdeck://help[/<topic>], topic ^[a-z0-9-]{1,48}$
case setup                       // paperdeck://setup

// ===== PaperDeckCore (S1) =====
package struct CardPromptProfile: Sendable, Equatable {
    package var reader: String, difficultyReference: String, methodHint: String, typicalTimes: String
    package var checklistExamples: [String]                   // exactly 4
    package init(reader: String, difficultyReference: String, methodHint: String, typicalTimes: String, checklistExamples: [String])
    package static let legacyCompBio: CardPromptProfile
    package static let maxReaderLength = 200
    package static func sanitize(_ text: String) -> String?   // one line, no control chars / < >, trimmed, ≤200; nil if empty
}
package enum CardPromptTemplate { package static func render(_ p: CardPromptProfile) -> String }
extension CardSchema { package static func systemPrompt(for p: CardPromptProfile) -> String }
// Engine.Dependencies: package var loadCardProfile: @Sendable () -> CardPromptProfile   (init param, default { .legacyCompBio })
package enum SlashDateOrder: String, Codable, Sendable, CaseIterable {
    case mdy, dmy, auto
    package func resolved(locale: Locale = .current) -> SlashDateOrder
}
// MailSettings: package var dateOrder: SlashDateOrder (init default .mdy); Keys.dateOrder = "mail.dateOrder"
// MailHeuristics.findDue(in:received:now:calendar:dateOrder: SlashDateOrder = .mdy)
// MailAccount: package var source: String?   (init(..., source: String? = nil))
// MailAccount.suggestedPowerAutomateFolder(home:) — REMOVED
package struct StarterCategory: Sendable, Equatable, Codable { package var name: String; package var description: String }
package enum LibraryIdentityCheck: Sendable, Equatable {
    case match, noManifest, unreadableManifest, emptyIndex
    case mismatch(manifestID: String, indexID: String?, indexedPapers: Int)
}
package enum LibraryFolderKind: Sendable, Equatable {
    case missing, unreadable, empty, otherContent(items: Int)
    case existingLibrary(libraryID: String?, cardCount: Int)
    case parentOfLibrary(child: URL, cardCount: Int)
}
package enum LibraryInspector { package static func inspect(_ folder: URL, limit: Int = 5_000) async -> LibraryFolderKind }
extension Engine {
    package func applyStarterPackIfPristine(_ pack: [StarterCategory]) async throws -> Bool
    package func addMissingStarterCategories(_ pack: [StarterCategory]) async throws -> Int
    package func checkLibraryIdentity() async -> LibraryIdentityCheck
    package func replaceIndexFromLibraryFolder(starterPackIfEmpty: [StarterCategory]?) async throws -> RebuildReport
    package func reindexMissingFullText() async -> Int
}
// MaintenanceReport: package var libraryMismatch: LibraryIdentityCheck?   (start() returns early; may be called again)
// AgentQueue: package func testConnection(provider: AIProviderKind? = nil, model: String? = nil) async -> AgentOutcome
package enum ProviderProbe { package static func status(_ kind: AIProviderKind, overridePath: String?, agentCwd: URL) async -> ProviderStatus }

// ===== PaperDeckConfig (S1 unless marked) =====
package struct LocalizedText: Codable, Sendable, Equatable, Hashable {
    package var en: String, zh: String
    package init(en: String, zh: String); package init(_ both: String)
    package func callAsFunction(_ lang: UILang) -> String
}
package enum ConfigOrigin: String, Codable, Sendable { case legacy, fresh }
package enum CareerStage: String, Codable, Sendable, CaseIterable {
    case masters, phd, postdoc, faculty
    package var levelPhrase: String { get }; package var stageNoun: String { get }; package var title: LocalizedText { get }
}
package enum PeopleAIDefault: String, Codable, Sendable, CaseIterable { case ask, never; package var policy: MailAIPolicy { get } }
package enum OrgTextKey: String, Codable, Sendable, CaseIterable {
    case accountsIntro, paTemplateName, paTemplateBlurb, gmailBlurb, paDefaultAccountName, oneDriveMissing,
         paBlockedNote, paIntro, patternInvalid, personSenderWarning, policyNote, triagePrivacy, consentNote
}
package struct OrgMailHints: Codable, Sendable, Equatable {
    package var oneDriveRootHint: String?, oneDriveFallbackRootName: String?
    package var knownSenderDomains: [String]; package var powerAutomatePortal: URL?
}
package struct OrganizationProfile: Codable, Sendable, Equatable, Identifiable {
    package var id: String; package var name: LocalizedText?; package var shortName: String?
    package var approvedAITools: [String]; package var policyURL: URL?; package var peopleDefault: PeopleAIDefault
    package var texts: [String: LocalizedText]                // OrgTextKey.rawValue (+ "legacyNote"); built-in only
    package var mail: OrgMailHints
}
package enum OrganizationPresets {
    package static let generic: OrganizationProfile, washu: OrganizationProfile
    package static let builtIn: [OrganizationProfile]
    package static func custom(name: String, shortName: String?, approvedAITools: [String], policyURL: URL?,
                               peopleDefault: PeopleAIDefault, oneDriveRootHint: String?) -> OrganizationProfile
}
package struct FieldPreset: Sendable, Equatable, Identifiable {
    package var id: String; package var name: LocalizedText; package var symbol: String
    package var readerPattern: String, difficultyPattern: String, methodHint: String, typicalTimes: String
    package var checklistExamples: [String]; package var starterCategories: [StarterCategory]; package var senderPresetIDs: [String]
    package var interestsPlaceholder: LocalizedText, categoryDescriptionExample: LocalizedText
    package var customInstructionsExample: LocalizedText, alertsTip: LocalizedText
    package func cardProfile(stage: CareerStage, readerOverride: String?) -> CardPromptProfile
}
package enum FieldPresets {
    package static let all: [FieldPreset]; package static let lifeSciencesCompBio: FieldPreset; package static let general: FieldPreset
    package static func preset(id: String?) -> FieldPreset?
}
package struct SenderPresetEntry: Sendable, Equatable { package var rule: SenderRule; package var verified: Bool }
package enum SenderPresetCatalog {
    package static let all: [SenderPresetEntry]
    package static func suggested(for f: FieldPreset) -> [SenderRule]; package static func others(for f: FieldPreset) -> [SenderRule]
}
package enum LegacyInstall { /* §2.4 */ }
package struct PersistedDomain {
    package init(_ values: [String: Any])
    package static func app(bundleID: String = BuildIdentity.current.bundleID) -> PersistedDomain
    package static func suite(_ name: String) -> PersistedDomain
    package func has(_ key: String) -> Bool; package func string(_ key: String) -> String?; package func int(_ key: String) -> Int?
    package var values: [String: Any] { get }
}
package enum ConfigKeys { /* every key in §2.5 */ }
package struct ConfigSnapshot: Sendable, Equatable {
    package var migrationVersion: Int?; package var origin: ConfigOrigin; package var field: FieldPreset
    package var stage: CareerStage; package var readerOverride: String?; package var organization: OrganizationProfile
    package var mailDateOrder: SlashDateOrder
    package var cardPromptProfile: CardPromptProfile { get }
}
package enum LegacyInstallDetector {
    package static func isLegacy(_ p: PersistedDomain, databaseExists: Bool) -> Bool
    package static func markers(_ p: PersistedDomain) -> [String]
}
package enum ConfigResolver {
    package static func resolve(_ p: PersistedDomain, databaseExists: Bool) -> ConfigSnapshot
    package static func load(_ d: UserDefaults, legacyFallback: Bool) -> ConfigSnapshot   // new keys via object(forKey:) (never registered)
    package static func cardPromptProfile(_ d: UserDefaults = .standard) -> CardPromptProfile
}
package enum PlistScalar: Sendable, Equatable { case string(String), int(Int), double(Double), bool(Bool) }
package struct MigrationPlan: Sendable, Equatable {
    package var fromVersion: Int?, toVersion: Int; package var origin: ConfigOrigin
    package var writes: [String: PlistScalar]; package var backup: Bool; package var markers: [String]
}
package enum ConfigMigration {
    package static let currentVersion = 1
    package static func plan(_ p: PersistedDomain, databaseExists: Bool, now: Date) -> MigrationPlan?   // nil = done
    @discardableResult package static func runIfNeeded(defaults: UserDefaults = .standard,
        domain: String = BuildIdentity.current.bundleID, databaseURL: URL = AppPaths.production().database,
        backupsDirectory: URL = AppPaths.production().backups, now: Date = Date()) -> ConfigOrigin
}
package enum MailSourceID: String, Codable, Sendable, CaseIterable {
    case m365PowerAutomate = "m365.powerAutomate", folder = "folder"
    case imapGmail = "imap.gmail", imapICloud = "imap.icloud", imapYahoo = "imap.yahoo", imapFastmail = "imap.fastmail", imapCustom = "imap.custom"
    case guideOutlookCom = "guide.outlookCom", guideWorkspace = "guide.workspace", guideM365Blocked = "guide.m365Blocked"
    case guideAppleMailRule = "guide.appleMailRule", guideAppsScript = "guide.appsScript", guideDragOnly = "guide.dragOnly"
    package var createsAccount: Bool { get }; package var imapPreset: MailAccount.IMAPPreset? { get }
}
package struct MailSourceEntry: Sendable, Equatable, Identifiable {
    package enum Section: Sendable { case setUp, otherWays }
    package var id: MailSourceID; package var section: Section; package var symbol: String
    package var title: LocalizedText; package var blurb: LocalizedText; package var helpTopic: GuideTopicID; package var beta: Bool
}
package enum MailSourceCatalog { package static func entries(org: OrganizationProfile) -> [MailSourceEntry] }
package enum MailSourceResolver { package static func source(of a: MailAccount) -> MailSourceID }
package enum CloudProvider: String, Codable, Sendable, CaseIterable { case oneDriveBusiness, oneDrivePersonal, oneDriveShared, dropbox, googleDrive, box, iCloudDrive, other }
package struct CloudRoot: Sendable, Equatable { package var provider: CloudProvider; package var name: String; package var url: URL; package var displayName: String }
package enum CloudRootLocator {
    package static func classify(names: [String], cloudStorage: URL) -> [CloudRoot]
    package static func iCloudDrive(home: URL) -> CloudRoot
    package static func ranked(_ roots: [CloudRoot], for s: MailSourceID, org: OrganizationProfile, lastChoice: String?) -> [CloudRoot]
    package static func suggestedFolder(for s: MailSourceID, roots: [CloudRoot], existingMailFolders: [URL],
        org: OrganizationProfile, lastChoice: String?, home: URL, folderName: String = "PaperDeck Mail") -> URL?
    package static func split(_ path: String, home: URL) -> (root: CloudRoot, relative: String)?
}
package enum MailRuleScripts {
    package static func appleMailRule(folder: URL) -> String
    package static func googleAppsScript(driveFolderName: String, senders: [String], label: String?) -> String
}
package enum OrgStrings {
    package static func text(_ k: OrgTextKey, org: OrganizationProfile, lang: UILang) -> String
    package static func consentNote(provider: String, org: OrganizationProfile, lang: UILang) -> String
    package static func paDefaultAccountName(org: OrganizationProfile, lang: UILang) -> String
    package static func aiPolicyLine(org: OrganizationProfile, lang: UILang) -> String
    package static func legacyNote(org: OrganizationProfile, origin: ConfigOrigin, lang: UILang) -> String?
}
package enum FieldStrings {
    package static func describeHint(_ f: FieldPreset, _ l: UILang) -> String
    package static func categoryDescriptionPlaceholder(_ f: FieldPreset, _ l: UILang) -> String
    package static func customInstructionsHint(_ f: FieldPreset, _ l: UILang) -> String
    package static func alertsTip(_ f: FieldPreset, _ l: UILang) -> String
}
package enum SettingsSection: String, Codable, Sendable, CaseIterable { case profile, organization, general, plan, ai, library, mailSenders, mailAccounts, panel }
package enum SettingsKeyClass: Sendable { case export, hint, never }
package struct SettingsKeyEntry: Sendable { package var key: String; package var section: SettingsSection; package var keyClass: SettingsKeyClass; package var personal: Bool }
package enum SettingsRegistry { package static let entries: [SettingsKeyEntry]; package static func entry(_ key: String) -> SettingsKeyEntry? }
package enum PortablePath: Codable, Sendable, Equatable {
    case home(String), cloud(provider: CloudProvider, root: String, relative: String), absolute(String)
    package enum Resolution: Sendable, Equatable { case exact(URL), sameProvider(URL), unresolved }
    package static func encode(_ absolutePath: String, home: URL, roots: [CloudRoot]) -> PortablePath
    package func resolve(home: URL, roots: [CloudRoot]) -> Resolution
}
package struct SettingsBundle: Codable, Sendable, Equatable {
    package static let formatID = "paperdeck.settings/1"
    package var format: String; package var exportedAt: Date; package var app: String; package var sections: [String: JSONValue]
}
package enum SettingsExporter {
    package static func export(_ p: PersistedDomain, sections: Set<SettingsSection>, includePersonal: Bool,
                               home: URL, roots: [CloudRoot], app: String, now: Date) -> SettingsBundle
}
package struct ImportChange: Sendable, Equatable { package var key: String; package var section: SettingsSection; package var old: String?; package var new: String; package var needsConfirmation: Bool }
package enum ImportWarning: Sendable, Equatable {
    case needsAppPassword(account: String), folderRemapped(account: String, to: String), folderUnresolved(account: String, root: String)
    case cliPathDropped(String), peopleAlwaysClamped(sender: String), readerDescriptionNeedsConfirm, unknownKeysIgnored(Int)
}
package struct ImportPlan: Sendable, Equatable { package var changes: [ImportChange]; package var warnings: [ImportWarning]; package var writes: [String: JSONValue] }
package enum SettingsImporter {
    package enum Failure: Error, Equatable { case unknownFormat(String), malformed }
    package static func decode(_ data: Data) throws -> SettingsBundle
    package static func plan(_ b: SettingsBundle, current: PersistedDomain, sections: Set<SettingsSection>,
        keepPeopleAlways: Bool, acceptReaderDescription: Bool, home: URL, roots: [CloudRoot]) -> ImportPlan
    // invariant: writes never contains agent.mode, mail.enabled, setup.completed, or any "never" key
}
package struct LibraryPendingAction: Codable, Sendable, Equatable {
    package enum Kind: String, Codable, Sendable { case openExisting, startNew }
    package var kind: Kind; package var path: String; package var previousPath: String?
    package static let key = "library.pendingAction"
    package static func load(_ d: UserDefaults) -> LibraryPendingAction?
    package func save(_ d: UserDefaults); package static func clear(_ d: UserDefaults)
}

// ===== PaperDeckConfig/Guide (model: S3; Content/: S4) =====
package struct GuideTopicID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral { package var rawValue: String }
// + static constants for every id in §3.8 (e.g. .connectMail = "connect-mail")
package enum GuideKind: String, Sendable { case checklist, tour, tutorial, troubleshoot, reference }
package enum GuideFeature: String, Sendable { case settingsTransfer, libraryFlows, widgetRepair }
package enum GuideActivityKind: String, Codable, Sendable, CaseIterable { case panelDrop, menuBarDrop, openWith, openedDetail, tourCompleted, emlImported }
package enum GuideCheck: Sendable, Hashable {
    case libraryUsable, libraryLocal, libraryHasManifest, libraryUbiquitous, libraryOnRemovableVolume, documentsDenied
    case libraryMismatchNow, papersMissing, fullTextIncomplete, hasPapers(Int), openedPaper, activity(Set<GuideActivityKind>)
    case aiDecided, aiReady, usageLimitPaused, providerInstalled(AIProviderKind), providerSignedIn(AIProviderKind), providerSubscription(AIProviderKind)
    case notificationsAllowed, reminderEnabled, launchAtLogin, loginItemNeedsApproval, widgetRegistered, widgetPlaced
    case appInApplications, notTranslocated, notQuarantined, stableSigning
    case cloudRootPresent(CloudProvider), oneDriveBusinessPresent
    case mailEnabled, mailAccountExists(MailSourceID?), mailAccountReady(MailSourceID?), mailAccountAuthFailed
    case mailFirstCapture(MailSourceID?), mailFolderExists, mailNoNotEmailFiles, sendersAdded(SenderKind?)
    case imapPasswordsPresent, emlImportedManually, settingsExported, settingsImported, profileSet
}   // additive cases allowed (S3); never rename
package enum CheckState: Sendable, Equatable { case done, todo, problem(LocalizedText), unknown, notApplicable }
package enum GuideVerification: Sendable, Equatable { case check(GuideCheck), impliedBy(step: Int), manual(reason: LocalizedText), info }
package enum GuideRouterAction: String, Sendable { case pickAndImportFiles, armDropPanel, showToday, showMail, openFirstPaper, showMenuBarMenu, revealLibrary, exportSettings, importSettings, openSetup, openTour, reindexFullText, repairWidget }
package enum SystemPane: String, Sendable { case notifications, loginItems, filesAndFolders, privacySecurity }
package enum GeneratedArtifact: String, Sendable { case appleMailRuleScript, googleAppsScript, powerAutomatePackage }
package enum GuideAction: Sendable, Equatable {
    case openTopic(GuideTopicID), openSettings(tab: String), deepLink(DeepLink), openURL(URL)   // URL host allowlisted
    case router(GuideRouterAction), systemSettings(SystemPane), openMailSheet(MailSourceID), copyGenerated(GeneratedArtifact)
}
package struct GuideStep: Sendable, Equatable { package var id: String; package var text: LocalizedText; package var verification: GuideVerification; package var actions: [GuideAction]; package var commands: [String] }
package struct GuideTopic: Sendable, Equatable, Identifiable {
    package var id: GuideTopicID; package var kind: GuideKind; package var title: LocalizedText; package var summary: LocalizedText
    package var keywords: [LocalizedText]; package var steps: [GuideStep]; package var related: [GuideTopicID]
    package var requires: Set<GuideFeature>; package var diagnosis: GuideCheck?; package var lastReviewed: String
}
package enum GuideContent { package static var tour: [GuideTopic]; package static var tutorials: [GuideTopic]; package static var mail: [GuideTopic]; package static var troubleshooting: [GuideTopic] }  // S4
package struct SetupFacts: Sendable, Equatable { /* library, papers, activity, ai, notifications, loginItem, widget, app,
    signing, mail, cloud, transfer, profile, features — each probe fact as ProbeState<T> */ package static let unknown: SetupFacts }
package enum GuideCatalog { package static var topics: [GuideTopic] { get }; package static func topic(_ id: GuideTopicID) -> GuideTopic? }
package enum GuideEvaluator {
    package static func evaluate(_ c: GuideCheck, _ f: SetupFacts) -> CheckState
    package static func evaluate(step: Int, in t: GuideTopic, _ f: SetupFacts, manualDone: Set<String>) -> CheckState
}
package enum GettingStarted {
    package struct Item: Sendable, Equatable { package var id: String; package var required: Bool; package var state: CheckState; package var visible: Bool }
    package static func items(_ f: SetupFacts, skipped: Set<String>, mailDecision: String?) -> [Item]
    package static func showOnToday(origin: ConfigOrigin, dismissed: Bool, items: [Item]) -> Bool
}
package enum OnboardingGate { package static func needsPreflight(_ p: PersistedDomain, databaseExists: Bool, rootOverride: Bool) -> Bool }
package enum GuideSearch { package static func search(_ q: String, lang: UILang) -> [GuideTopicID] }
package enum GuideMarkdown { package static func render(_ topics: [GuideTopic], lang: UILang) -> String }
package enum DiagnosticsReport {
    package static func render(_ f: SetupFacts, identity: BuildIdentity, config: ConfigSnapshot, appVersion: String, home: String, redact: Bool) -> String
}

// ===== App (MainActor) =====
@Observable final class ConfigStore {                               // S2 (App/ConfigStore.swift)
    init(defaults: UserDefaults, legacyFallback: Bool = true)
    private(set) var snapshot: ConfigSnapshot
    var fieldID: String; var stage: CareerStage; var readerOverride: String?
    var organizationID: String; var customOrganization: OrganizationProfile?
    var dateOrder: SlashDateOrder; var importLastFolder: String?; var legacyOnboardingFlag: Bool { get }
    func reload()                                                   // also mirrors LangStore.shared.org / .field
}
// SettingsStore.config: ConfigStore (same defaults); LangStore.org: OrganizationProfile; LangStore.field: FieldPreset  (S2)
struct ProfileEditor: View { init(settings: SettingsStore, context: ProfileEditorContext) }            // S2
enum ProfileEditorContext { case settings, onboarding }
struct SettingsImportSheet: View { init(settings: SettingsStore, fileURL: URL?, onClose: @escaping (Bool) -> Void) }  // S2
@MainActor enum LibraryFolderPicker { static func pick(startingAt: URL?, prompt: String) async -> (url: URL, kind: LibraryFolderKind)? }  // S2
extension MailAccountTemplate { init?(source: MailSourceID) }                                          // S2
struct HelpButton: View { init(_ topic: GuideTopicID) }                                                // S3
@MainActor enum HelpCenter {                                                                           // S3
    static var openTopic: (GuideTopicID?) -> Void; static var openSetup: (OnboardingPage?) -> Void; static var openTour: () -> Void
}
enum OnboardingPage: String, CaseIterable { case welcome, about, ai, library, plan, mail, importPapers, finish }  // S3
@MainActor enum Relaunch { static func now() }                                                         // S3
enum SelfTestStrings { static func run(_ a: CLIArgs) -> Int32 }            // W0 → S2
enum SelfTestSettings { static func run(_ a: CLIArgs) async -> Int32 }     // S2
enum SelfTestOnboarding { static func run(_ a: CLIArgs) async -> Int32 }   // S3
enum GuideExport { static func run(_ a: CLIArgs) -> Int32 }                // S3
enum ConfigCLI {                                                           // S4
    static func config(_ a: CLIArgs) -> Int32; static func migrateDryRun(_ a: CLIArgs) -> Int32
    static func exportSettings(_ a: CLIArgs) -> Int32; static func importSettings(_ a: CLIArgs) -> Int32
}
```

### 5.4 S1: Config engine and Core ports
**Owns:**
- `Package.swift`;
- `Sources/PaperDeckConfig/{Model,Presets,Resolve,Migrate,Mail,Strings,Portability}/**`;
- `Sources/PaperDeckCore/**` **except** `Support/Log.swift` and `Mail/Sources/MailSecretStores.swift`;
- `Tests/PaperDeckCoreTests/Config/**`, `Tests/PaperDeckCoreTests/CorePorts/**`, `Tests/PaperDeckCoreTests/Fixtures/config/**` (additions only);
- the single edit `Tests/PaperDeckCoreTests/MailSettingsUI/MailSettingsUITests.swift:175-176` (use `CloudRootLocator` with `OrganizationPresets.washu` and expect today's path).

**Tasks:**
1. Real resolver, legacy detector and migration (§2.6), including the backup plist.
2. All presets (§2.4): the generic and custom composition (§2.7), 11 fields, the stages, the sender catalog (new entries `verified: false`).
3. `CardPromptTemplate.render` with five slots; reader sanitization.
4. `CloudRootLocator`, `MailSourceResolver`, `MailSourceCatalog`, `MailRuleScripts`.
5. The portability codec, registry, `PortablePath`, importer plan and pending action.
6. Core:
   - remove `suggestedPowerAutomateFolder`;
   - `dateOrder` threaded through `MailHeuristics` (`:57,423,516-521`) and the sync caller;
   - host-aware IMAP authentication text (`IMAPClient.swift:70-74`);
   - provider-neutral folder hints (`FolderMailSource.swift:49-51`);
   - StarterPack, LibraryIdentity guard in `Engine.start()`, LibraryInspector, `replaceIndexFromLibraryFolder`, `reindexMissingFullText`, `ProviderProbe` (Doctor's construction, `Doctor.swift:20-24`).
7. Queue labels → `"\(Log.subsystem).<name>"` in the 7 Core files (bindings I21).
8. Make the comments institution-neutral: `MailModels.swift:117`, `MailSettings.swift:14,127,153`, `SenderMatcher.swift:7-8,42`, `Intake.swift:68`, `OperationsMail.swift:579`, `MailConfidentiality.swift:3`, `CLIFactStore.swift:20`.

**Tests** (Swift Testing; scratch suites through `ScratchDefaults`, `Tests/.../Support/ScratchDefaults.swift`):

| # | Suite | Proves |
|---|---|---|
| T1 | ConfigMigrationTests | (a) `legacy-washu-domain.plist`: plan writes exactly {config.migrationVersion, config.origin=legacy, config.migratedAt, config.migrationNote, org.preset=washu, profile.field=lifeSciencesCompBio, mail.dateOrder=mdy, import.lastFolder}; after `runIfNeeded` on a scratch suite the persistent-domain diff contains only those keys and every pre-existing key is byte-identical; the backup file exists. (b) An empty domain with a DB file → legacy. (c) An empty domain without a DB → fresh {migrationVersion, origin, migratedAt, mail.dateOrder=auto}. (d) Idempotent. (e) A registered-only domain (`register(defaults:)` with setup.completed=false, library.path) counts as fresh. (f) `agent.mode=off` alone (`--dev`) → fresh. (g) An existing explicit `org.preset=generic` is never overwritten. (h) Markers are listed for the WashU fixture. |
| T2 | CardPromptTests | `systemPrompt(for: .legacyCompBio) == systemPrompt` (byte); the literal equals `card-system-prompt-v1.txt`; `normalizeWS(render(.legacyCompBio)) == normalizeWS(systemPrompt)`; `FieldPresets.lifeSciencesCompBio.cardProfile(stage: .phd, readerOverride: nil) == .legacyCompBio`; every field and stage render keeps the SECURITY/FACTUALITY/STYLE/CATEGORY/TAGS paragraphs verbatim; no "comp-bio" or "Nature/Cell" outside lifeSci; length within ±400 chars; sanitization (newlines, `<>`, the 200 cap, control characters); the existing pins pass unchanged (`ArgvTests.swift:39,163`, `CodexProviderTests.swift:257,313`, `QueueProviderTests.swift:263`, `MailTriageSchemaTests.swift:350-351`, `RegressionInjectionTests.swift:83-84`). |
| T3 | OrgStringsGoldenTests | The washu texts for 13 keys plus consentNote("Claude"/"ChatGPT") and the 4 field keys, en and zh, equal `org-strings-v1.json`; generic and custom contain none of `WashU`, `wustl` or `Washington`; paDefaultAccountName always contains "Power Automate"; custom uses `{short}`. |
| T4 | FieldPresetTests | 11 unique ids; starters ≤7 with names ≤40 chars and unique; exactly 4 examples; en and zh placeholders non-empty; `lifeSci.starterCategories` equals `PaperCategory.starters`; unknown id → general (fresh) or lifeSci (legacy). |
| T5 | CloudRootLocatorTests | Names [OneDrive-Personal, OneDrive-SharedLibraries-Contoso, OneDrive-Contoso University, Dropbox, GoogleDrive-a@b.com, Box-Box] classify correctly; for Power Automate, business roots come first and Personal/Shared are excluded; the washu hint ranks the WashU root first; no roots → generic nil and washu today's path; an existing PaperDeck Mail wins; `split` handles CloudStorage and legacy `~/OneDrive - Org`. |
| T6 | MailSourceResolverTests | nil source with a WashU path or a name containing "Power Automate" → m365; explicit source wins; JSON with source round-trips; today's JSON without it decodes; `MailSettings.list` tolerates source. |
| T7 | SenderPresetCatalogTests | The 9 legacy ids and patterns, in order, equal `SenderRule.presets`; ids unique; every pattern parses (`SenderMatcher.Pattern`); every field's ids exist. |
| T8 | StarterPackTests (scratch DB) | Pristine → replaced and the first manifest holds the pack; one paper → untouched; a renamed starter → untouched; manifest present → untouched; `addMissing` respects the cap of 20 and never deletes. |
| T9 | LibraryIdentityTests | Scratch libraries A and B with different ids: an engine with A's DB opened on B → `.mismatch`, start returns early, **B's manifest byte-identical**, no paper flagged missing; same id → `.match` as today; no manifest → as today; `replaceIndexFromLibraryFolder` rebuilds B and keeps the mail tables. |
| T10 | LibraryInspectorTests | empty / other / existing (count) / parent-of-library / missing; the scan limit is honored. |
| T11 | SettingsBundleTests | The export holds only allowlisted keys and no `agent.mode`, `setup.completed`, `launchAtLogin`, `mail.enabled`, `config.*`; no value matches `password|secret|token|apppassword`; `InMemoryMailSecretStore` never read; paths encoded as `.home`/`.cloud`; round-trip into a fresh domain is equal except for the never-keys; the people `.always` clamp and its opt-out; reader confirmation; unknown format refused; unknown keys counted; the organization section never carries texts. |
| T12 | ConfigResolverTests | Absent-key rules by origin; the custom organization decodes; an unknown preset → generic with a log. |
| T13 | DateOrderTests | "10/3" → Oct 3 for mdy (default) and Mar 10 for dmy; auto follows the locale (en_US / en_GB); a missing key loads as mdy. |
| T14 | MailRuleScriptsTests | Senders and folder embedded and escaped; no secrets; the AppleScript uses `source of`. |
| T15 | ConsentFloorTests | `PeopleAIDefault` has no `.always`; `custom(...)` from imported data cannot loosen; alert defaults unchanged. |
| T16 | IMAPMessageTests | Microsoft hosts give the Outlook text; other hosts give today's text. |
| — | Existing suite | All 31 folders green; the only test edit is `MailSettingsUITests.swift:175-176`. |

### 5.5 S2: App settings, mail and strings integration
**Owns:**
- every existing `Sources/PaperDeck/App/L10n*.swift` file;
- `App/SettingsStore.swift`, `App/ConfigStore.swift`;
- `Sources/PaperDeck/Views/Settings/**` **except** `SetupAssistantView.swift`; includes new `ProfileSettingsTab.swift`, `ProfileEditor.swift`, `TransferSection.swift`, `SettingsExportSheet.swift`, `SettingsImportSheet.swift`, `LibraryFolderPicker.swift`;
- `Windows/SettingsWindowController.swift`;
- `CLI/MailRenders.swift`, `CLI/MailAppRenders.swift`, `CLI/MailInboxRenders.swift`, `CLI/SelfTestStrings.swift`, `CLI/SelfTestSettings.swift`.

**Tasks:**
1. L10n delegation. `LangStore.org` and `.field` are set by `ConfigStore`. The 13 organization keys and 4 field keys call `OrgStrings`/`FieldStrings`. Rename `washuAlwaysWarning`/`washuPolicyNote` to `personSenderWarning`/`policyNote` and update `MailSenderRuleSheet.swift:111-117`. Delete every institution literal from L10n.
2. zh reminder time (`L10n+settings.swift:84`); neutral import hint (`:529-532`); signing texts from `BuildIdentity` (`:491-503`); channel-aware widget footer (`:435-438`).
3. Mail:
   - the two-section chooser from `MailSourceCatalog`;
   - `MailAccountTemplate(account)` via the resolver, and `init?(source:)`;
   - `start(.powerAutomate)` and `detectOneDrive` via `CloudRootLocator` (delete `:545`), storing `source` and `mail.cloudRoot`;
   - `MailSettingsSupport.cloudRoots`;
   - the Power Automate guide `split` and portal;
   - the sender preset menu by field;
   - new person rules use `org.peopleDefault`;
   - the triage model catalog;
   - the date-order picker;
   - the Apple Mail rule disclosure (Beta);
   - Outlook.com / Workspace / blocked rows → `HelpCenter.openTopic`.
4. Settings ▸ Profile tab, `ProfileEditor`, General sections, the export and import sheets (§3.6).
5. Library Change… flow, Re-index Full Text, Widget Repair Registration, AI connection-test model, HelpButtons (§3.7).
6. `MailRenders` demo data: scrub to `example.edu` and "Work (Power Automate)" (bindings M20). Keep `--seed-plist` renders unaffected.

**Tests:**
1. `--selftest strings --check Tests/PaperDeckCoreTests/Fixtures/config/org-strings-v1.json --lang en` and `--lang zh` → PASS with the default (washu) configuration. The key names are stable; the accessor mapping inside the selftest is updated.
2. `--selftest settings [--lang en|zh]`, offline on a scratch suite:
   - with `org=generic`, no L10n organization string matches `/washu|wustl|washington/i`;
   - ConfigStore setters write exactly their keys and mirror LangStore;
   - applying an `ImportPlan` through SettingsStore never writes `agent.mode`, `mail.enabled` or `setup.completed`, and fires one debounced mail notice;
   - `MailAccountTemplate` for the legacy WashU account is `.powerAutomate`, and the `source` mapping table holds;
   - the setUp chooser order equals today's 7 (`MailAddAccountSheet.swift:11-13`);
   - the washu Power Automate default name is "WashU (Power Automate)";
   - the lifeSci preset menu equals `SenderRule.presets`;
   - the Change… decision table (kind × same or different id → offered actions) and the pending-action write.
3. Renders:
   - `--render $OUT --root $SCR --mail-only --seed-plist legacy-washu-domain.plist` (en and zh) byte-identical to the W0 baseline;
   - `--render $OUT --root $SCR --guide-only --scenario legacy|fresh|m365Contoso`: `settings-profile-*`, the chooser, the Power Automate form under generic with scratch roots `OneDrive-Contoso University` and `OneDrive-Personal` → the Contoso suggestion.

### 5.6 S3: Onboarding and Help Center
**Owns:**
- Config: `Sources/PaperDeckConfig/Guide/**` **except** `Guide/Content/**`.
- Shared: `Sources/PaperDeckShared/DeepLink.swift`.
- App:
  - `App/AppDelegate.swift`, `App/AppState.swift`, `App/AppState+Mail.swift`, `App/URLRouter.swift`, `App/LibraryOpenFailure.swift`;
  - new `App/GuideActivity.swift`, `App/Relaunch.swift`, `App/ActivationPolicy.swift`, `App/L10n+onboarding.swift`, `App/L10n+help.swift`.
- Windows: `Windows/LibraryWindowController.swift`, `StatusBarController.swift`, `DropPanelController.swift`, `SetupWindowController.swift`; new `OnboardingWindowController.swift`, `HelpWindowController.swift`.
- Views: `Views/Onboarding/**`, `Views/Help/**`, `Views/Settings/SetupAssistantView.swift`, `Views/Library/**`, `Views/Mail/MailInboxView.swift`, `Views/Detail/PaperDetailView.swift`.
- CLI: `CLI/PreviewRenderer.swift`, new `CLI/GuideRenders.swift`, `CLI/SelfTestOnboarding.swift`, `CLI/GuideExport.swift`.
- Tests: `Tests/PaperDeckCoreTests/Guide/**`.

**Tasks:**
1. The launch sequence and gate (§3.1): pending-action execution, the mismatch alert, `volumeMissing`, Relaunch, ActivationPolicy, the menu refactor and Help menu, the menu-bar "Help & Setup".
2. The onboarding window and pages P1–P8 (§3.2–3.3). Steps from SetupAssistant are made internal; the import folder (`:499`) changes; the signing row shows only for `.local`; the `onboarding.legacy` rollback flag.
3. The Help Center (§3.4): `SetupFactsCollector`, `LiveFactSources`/`FakeFactSources`, `GuideEvaluator`, `GettingStarted` card and menu item, the tour, `TutorialView` (with `copyGenerated` using `MailRuleScripts` and the sender list), Troubleshooting, Diagnostics, `HelpButton`, `HelpCenter` routes, activity recording, "How to Fix" banners, the empty-state link, the MailInbox help button.
4. Deep links `help` and `setup`. Status-item autosave name → `"\(BuildIdentity.current.bundleID).status"` (the same string). URLRouter debug comment → neutral. Render suite → `"\(BuildIdentity.current.bundleID).render"`.
5. `--render --guide-only --scenario …`: every onboarding page in each mode, the Help Center pages, the Getting Started card, the profile tab. It uses `FakeFactSources` and never builds Settings ▸ AI's live probes.
6. `--guide-export DIR --lang` (GuideMarkdown).

**Tests:**
- Core:
  - GuideCatalogTests:
    - every §3.8 id has exactly one topic, and ids are unique;
    - en and zh texts are non-empty;
    - every related id exists;
    - every deep link round-trips through `DeepLink(url:)`;
    - every URL host is on the allowlist (make.powerautomate.com, myaccount.google.com, script.google.com, account.apple.com, support.apple.com, support.google.com, support.microsoft.com, claude.ai, chatgpt.com, openai.com, login.yahoo.com, app.fastmail.com);
    - at most one manual step per topic, with a reason;
    - `impliedBy` points forward;
    - commands contain no `/Users/`, institution literals or real-looking emails.
  - GuideEvaluatorTests (table-driven; unknown is never done; legacy Power Automate inference).
  - GettingStartedTests (visibility, progress, legacy origin → hidden).
  - OnboardingGateTests (truth table).
  - DeepLinkHelpTests (`help`, `help/connect-mail`, `setup`; `help/../x`, upper case and a 49-character id → nil).
  - DiagnosticsRedactionTests.
  - GuideSearchTests ("onedrive", "邮件", "widget").
  - GuideMarkdownTests.
- `--selftest onboarding [--lang]`, offline with a scratch suite and fake facts:
  - Quick Start writes exactly the expected keys;
  - the normal path writes `library.path` only at commit;
  - quitting before commit leaves the gate true;
  - the AI preselection matrix, where selecting never writes `agent.mode` and Turn On does;
  - the mail router maps every route to a template or topic, nothing sets `mail.enabled` without a saved account, alert presets start unchecked, and people keep `ask`;
  - every `HelpButton` topic used in views exists;
  - the Finish gating table;
  - revisit mode never writes `library.path` without a confirmed change.
- Renders: §6.3.

### 5.7 S4: Build identity, CLI tools, guide content and docs
**Owns:**
- Build and dev: `build_app.sh`, `test.sh`, `tools/**` (`make_fixtures.sh`; new `check_build_config.sh`, `verify_portability.sh`), `.gitignore` (`build.local.env`), `build.local.env.example`.
- Resources: `Resources/Info.plist`, `Resources/PaperDeckWidget-Info.plist` (purpose strings only).
- Shared and Core: `Sources/PaperDeckShared/BuildIdentity.swift`, `SharedPaths.swift`, `Sources/PaperDeckCore/Support/Log.swift`, `Sources/PaperDeckCore/Mail/Sources/MailSecretStores.swift`.
- Guide content: `Sources/PaperDeckConfig/Guide/Content/**`.
- App: `Sources/PaperDeck/CLI/{CLIRunner,Doctor,SelfTest,SelfTestMail,SelfTestMailNotify,SelfTestAppRules,SelfTestAppRules3,AgentCLI,MailCLI,ConfigCLI}.swift`, `Sources/PaperDeck/Services/**`, `Sources/PaperDeck/Drop/PromiseReceiving.swift`.
- Docs: `README.md`, `docs/**`.
- Tests: `Tests/PaperDeckCoreTests/Identity/**`.

**Tasks:**
1. Build layering, stamping, flags, build number, certificate warning, pkill by path (§2.11). Add `getCurrentConfigurations` to the warning grep (`build_app.sh:56`).
2. `test.sh` `PAPERDECK_DEV_DIR` with the `xcode-select` fallback. `make_fixtures.sh` takes a list file or arguments, with no personal paths.
3. `BuildIdentity.resolve`; `Log.subsystem`; the keychain default service; `Doctor` prints the bundle id, widget id, keychain service, channel and the config summary (`Doctor.swift:13-14`); `AgentCLI` uses `systemPrompt(for: ConfigResolver.cardPromptProfile())`.
4. `ConfigCLI`:
   - `--config [--plist FILE | --suite NAME] [--db-exists yes|no] [--json] [--card-prompt | --card-prompt-sha256]` reads only and never spawns;
   - `--migrate-dry-run --plist FILE --db-exists yes|no [--json]`;
   - `--export-settings OUT.json [--plist FILE] [--sections …]`;
   - `--import-settings IN.json --dry-run [--plist FILE]` (a real import is GUI-only);
   - usage text in `CLIRunner.usage` (`:92-131`).
5. The selftests scrub personal data: `yi@wustl.edu`, `jsmith@wustl.edu` and "WashU (Power Automate)" become `example.edu` and "Work (Power Automate)" (`SelfTestMailNotify.swift:23-45,119`, `SelfTestAppRules3.swift:102,157-158`). The assertions keep the "Power Automate" substring.
6. Info.plist:
   - `NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription` (bilingual, like `:31-36`);
   - neutral Documents text: "PaperDeck keeps your paper library in the folder you choose (default Documents/PaperDeck)".
   Editing purpose strings doesn't reset grants.
7. **Guide content** for every §3.8 topic (en and zh), using the S3 model; the tutorial steps in §3.4 are normative.
8. **Docs** (§4). The TROUBLESHOOTING generated blocks are filled from `--guide-export` in W2.

**Tests:**
- `BuildIdentityTests`:
  - nil Info and nil id → today's constants (`com.yijiang.paperdeck`, `.widget`, `.mail`, channel local);
  - `PDHostBundleIdentifier` overrides;
  - a widget main id strips `.widget`;
  - `PDKeychainService` and `PDBuildChannel` are read.
- `tools/check_build_config.sh`:
  - `env -i PATH=$PATH ./build_app.sh --print-config` prints exactly bundle `com.yijiang.paperdeck`, widget `com.yijiang.paperdeck.widget`, identity `PaperDeck Local Signing`, install `/Applications`, keychain `com.yijiang.paperdeck.mail`, channel `local`;
  - `build.local.env` overrides and rejected keys;
  - a widget id that is not prefixed fails;
  - `--no-install`: `plutil -convert json` of the staged plists minus `PD*`, `CFBundleVersion` and `DT*` equals `Resources/*.plist`; `codesign -dv` `Identifier=com.yijiang.paperdeck`; the DR is certificate-based; nothing is copied to `/Applications` and nothing is killed.
- `--selftest mail-notify` and `--selftest app-rules` still PASS after the scrub.

---

## 6. Verification plan (W2; everything is zero-quota)

### 6.1 Automated gates (`tools/verify_portability.sh`)
1. `swift build -c release`; `./test.sh`, all green, existing plus T1–T16 plus the S3 suites plus BuildIdentity plus the lint tests below.
2. W2 adds permanent lint tests in `Tests/PaperDeckCoreTests/Lint/`:
   - `InstitutionLintTests` (G1 over `Sources/**/*.swift` via a `#filePath`-relative root);
   - `IdentityLintTests` (G2 and G3 over Sources);
   - `GuideDocsSyncTests` (`GuideMarkdown.render` equals the generated blocks in `docs/TROUBLESHOOTING.md`; every topic id has an anchor in `docs/USER_GUIDE.md`; skips when the docs are absent).
3. `.build/release/PaperDeck --selftest strings --check Tests/PaperDeckCoreTests/Fixtures/config/org-strings-v1.json --lang en` and `--lang zh`.
4. `.build/release/PaperDeck --selftest settings`, `--selftest onboarding`, `--selftest mail-notify`, `--selftest app-rules` (`--lang en` and `zh`).
5. `tools/check_build_config.sh` (§5.7).
6. The grep allowlist (§6.4).

### 6.2 The current user's install: migrates with no visible change
1. **Scratch-suite migration (T1)** on `legacy-washu-domain.plist`, which has the user's shape. The persistent-domain diff contains only the allowed keys; old keys are byte-identical; the backup exists.
2. **CLI simulation:**
   ```
   PaperDeck --migrate-dry-run --plist Fixtures/config/legacy-washu-domain.plist --db-exists yes --json
     → origin=legacy; writes ⊆ {config.migrationVersion, config.origin, config.migratedAt, config.migrationNote,
        org.preset=washu, profile.field=lifeSciencesCompBio, mail.dateOrder=mdy, import.lastFolder}; markers ≥ 2
   PaperDeck --config --plist <migrated.plist> --db-exists yes --json
     → org=washu field=lifeSciencesCompBio stage=phd origin=legacy dateOrder=mdy bundle=com.yijiang.paperdeck
       keychain=com.yijiang.paperdeck.mail channel=local
   PaperDeck --config --plist <migrated.plist> --card-prompt-sha256  ==  shasum -a 256 Fixtures/config/card-system-prompt-v1.txt
   ```
3. **Strings:** `--selftest strings --check` passes in en and zh (step 6.1.3), and Core T3 passes.
4. **Render diff:** `--render $AFTER --root $SCR --mail-only --seed-plist legacy-washu-domain.plist --lang en|zh --appearance light` must be byte-identical (`cmp`) to the W0 baseline for every PNG present in both sets. This covers the Settings ▸ Mail accounts, senders, triage and Power Automate form, the sender sheet, the pill, toasts and launch alerts. New PNGs (for example `settings-profile-*`) are reviewed separately. Any `cmp` difference is inspected and either explained (non-deterministic time text) or fixed.
5. **Optional real-domain dry run, only with the user's explicit OK and with the app quit:**
   - `defaults export com.yijiang.paperdeck "$SCR/real.plist"`, then `--migrate-dry-run --plist "$SCR/real.plist" --db-exists yes` → only allowed keys.
   - Repeat step 4 with `--seed-plist "$SCR/real.plist"` using `$SCR/PaperDeck-W0` (before) and the new binary (after).
   - Delete `$SCR/real.plist` afterwards. Never commit it.
6. **Final install on the real account (only with the user's explicit OK):**
   1. Quit PaperDeck, then run `defaults export com.yijiang.paperdeck "$SCR/before.plist"`.
   2. Run `./build_app.sh` (**no `--dev`**) and launch once.
   3. Expect: no setup window; Today looks the same, with no Getting Started card; the new Help menu; Settings ▸ Profile shows WashU and comp-bio with the legacy note.
   4. Quit, export `after.plist`, and diff with `plutil -convert xml1`. Allowed: only the §6.2.2 keys, plus
      keys that only the user's own actions in this check can write:
      - `guide.activity` — first uses (a drop, Open With, an opened card, a finished tour, an `.eml`
        import). A legacy install records them **only while a guide view is open** (Help Center,
        tour, Setup Assistant: `GuideActivity.wanted`), so dropping papers or opening cards with no
        guide open writes nothing;
      - `onboarding.version`, `onboarding.completedAt`, `guide.checklist.dismissed` — only after
        Help ▸ Setup Assistant… ▸ Finish (a revisit);
      - `guide.skipped`, `guide.manualDone` — only after Skip / a manual tick in a guide;
      - `transfer.lastExportedAt` / `transfer.importedAt` — only after Export / Import Settings….
      Launching, Today and the menu-bar menu write none of PaperDeck's keys (the `ConfigStore` /
      `GuideStore` inits make no write call: `--selftest settings` "init writes"); opening the Help
      window once adds AppKit's own frame key `NSWindow Frame PaperDeckHelp`.
   5. Run `PaperDeck --config` → as in step 2, and `--doctor --mail-only` → the account is still Power Automate.
   6. Manual checks: Mail ▸ Sync Now on the WashU account succeeds; the sender sheet shows both WashU sentences; the widget is still listed; there is no Documents prompt; the backup plist exists in `Backups/`.

### 6.3 A fresh scratch profile goes through onboarding
1. `--migrate-dry-run --plist fresh-domain.plist --db-exists no` → fresh: {migrationVersion, origin=fresh, migratedAt, mail.dateOrder=auto}. Then `--config` → generic, general, phd, auto.
2. `--selftest onboarding` (§5.6).
3. Renders. For each `scenario ∈ {fresh, codexOnly, noAI, allReady, mailError, m365Contoso, legacy}` × `--lang en|zh` × `--appearance light|dark`:
   `--render $OUT --root $SCR --guide-only --scenario <s>`.
   Expected PNGs:
   - `onboarding-{welcome,about,ai,library,library-existing,plan,mail-router,mail-m365,mail-senders,import,finish}-<s>-<lang>-<appearance>.png`
   - `help-{getting-started,tour-drop,tutorial-m365,tutorial-move-mac,troubleshooting,diagnostics}-…png`
   - `today-getting-started-…png`, `settings-profile-…png`, `mail-chooser-…png`
   Review checklist:
   - zh truncation at 760×560;
   - the dark-mode status icons;
   - HelpLink placement in grouped forms;
   - generic renders contain no institution name (also asserted by the selftest);
   - the legacy scenario shows no Getting Started card.
4. Manual matrix in a **second macOS user account**. That account is the "new Mac": a fresh home, defaults, TCC, keychain and LaunchServices. Never run it in the current user's account, because the single-instance lock and `UserDefaults.standard` would touch their data. Deliver the app with `./build_app.sh --no-install --package`, via AirDrop or Safari, so it carries quarantine.

| # | Scenario | Expect |
|---|---|---|
| M1 | No CLIs, Quick Start | No TCC prompt before the Library explanation; the Documents prompt right after Continue; Getting Started shows; AI shows "Not using AI" ✓ |
| M2 | ChatGPT.app signed in | Codex preselected; Turn On writes codex |
| M3 | "Desktop & Documents in iCloud" on | The warning and [Use ~/PaperDeck] work, with no Documents prompt |
| M4 | Use existing library (a `ditto` copy) | The rebuild count matches; categories come from the manifest; no starter pack; Re-index fills search |
| M5 | Field CS | 7 CS categories; Profile ▸ "Show instructions" shows the CS reader |
| M6 | Microsoft 365 generic | Without OneDrive: the generic missing text; with OneDrive-Personal only: not suggested for Power Automate; no WashU text anywhere |
| M7 | Gmail with a wrong app password | authFailed → the tutorial step shows ⚠ with the fix; Turn On Mail disabled |
| M8 | zh throughout | Every page in zh |
| M9 | Cold launch by double-clicking a PDF | "1 PDF waiting"; imported after the commit |
| M10 | Live update | Sign in to a CLI in Terminal → the AI step ticks on return; create a folder in Finder → it ticks within 5 s |
| M11 | Import a settings file exported from a synthetic profile | AI and Mail stay off; IMAP "needs app password"; people's `.always` clamped; the reader text needs confirmation |
| M12 | Change… to a second library | The "Found another library" flow; B's manifest unchanged until confirmed; Restart Now relaunches |
| M13 | Quarantined zip, launched from Downloads | Open Anyway; the move-to-Applications prompt; the widget appears after a launch from Applications |

### 6.4 Grep allowlist (exact; run from the repo root; no output except the listed lines)
```bash
USER_DOCS="README.md docs/USER_GUIDE.md docs/TROUBLESHOOTING.md docs/guides docs/BUILDING.md docs/INSTALL_RECIPIENT.md docs/ARCHITECTURE-CONFIG.md"
CODE="Sources Resources Package.swift build_app.sh test.sh tools"

# G1 institution literals — allowed only in the WashU preset
grep -rnIiE 'washu|wustl|washington ?university' $CODE $USER_DOCS \
  | grep -v '^Sources/PaperDeckConfig/Presets/OrganizationPresets\.swift:'
#   → no output

# G2 author identity — exactly these 5 default-value lines
grep -rnI 'yijiang' $CODE $USER_DOCS
#   → Sources/PaperDeckShared/BuildIdentity.swift:<n>   (defaultBundleID = "com.yijiang.paperdeck")
#     build_app.sh:<n>                                  (default bundle id in the PAPERDECK_BUNDLE_ID fallback)
#     Resources/Info.plist:10  Resources/Info.plist:56  Resources/PaperDeckWidget-Info.plist:8

# G3 personal folders / home paths — exactly 1 line
grep -rnIE 'Paper_reading|/Users/[A-Za-z]' $CODE $USER_DOCS
#   → Sources/PaperDeckConfig/Presets/LegacyInstall.swift:<n>   (importFolder = "~/Desktop/Paper_reading")

# G4 cloud-root logic lives in one place
grep -rnE 'CloudStorage/OneDrive|hasPrefix\("OneDrive|contains\("OneDrive|OneDrive-Personal|OneDrive-SharedLibraries' Sources --include='*.swift' \
  | grep -vE '^Sources/PaperDeckConfig/(Mail/CloudRootLocator|Presets/OrganizationPresets)\.swift:'
#   → no output

# G5 machine paths in scripts only as overridable defaults
grep -n 'CommandLineTools' test.sh          # → only inside ${PAPERDECK_DEV_DIR:-…}
grep -nE '/Applications' build_app.sh      # → only inside ${PAPERDECK_INSTALL_DIR:-/Applications} and comments

# G6 signing-name default (informational) — allowed: BuildIdentity.swift, build_app.sh, docs/BUILDING.md, README.md (build section)
grep -rnI 'PaperDeck Local Signing' $CODE $USER_DOCS
```
- Allowed outside these checks:
  - `Tests/**`: fixtures and golden copies, the existing `wustl` mail fixtures, and the synthetic legacy domain.
  - `docs/institutions/**`.
  - The historical design records `docs/DESIGN.md`, `docs/MAIL_DESIGN.md` and `docs/RESEARCH.md` (bindings R5–R7).
- G1–G3 for `Sources/` are also enforced permanently by the lint tests (§6.1.2).

### 6.5 Commands that must not run during verification
These would run claude or codex, or touch the user's data:
- `--agent-smoke`, `--selftest … --agent claude|codex`;
- `--doctor` without `--mail-only`, `--agent-argv`;
- `--render` without `--mail-only` or `--guide-only`;
- `./build_app.sh --dev` on the user's account;
- any install into `/Applications` or `defaults write` on `com.yijiang.paperdeck` without the user's explicit OK.

---

## 7. Risks and deliberate scope

### 7.1 Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| The preflight before `Engine.open` regresses launch (Open With, the single instance, LaunchAlert) | high | Strict fresh-only gate; the legacy path code is unchanged; the `onboarding.legacy` rollback flag; the second-account matrix M1, M9 and M13 before shipping |
| Registered-vs-persisted confusion misclassifies the current user | high | `PersistedDomain` for detection; migration before `SettingsStore()`; T1(e)(f)(g); the defaults diff in §6.2.6 |
| Prompt drift changes the current user's cards | high | Literal short-circuit; golden fixture; normalized template test; sha check through `--config` |
| WashU wording drift | high | A fixture generated mechanically from today's binary; `--selftest strings` before and after; Core T3; seeded render diff |
| Parallel merge conflicts or contract drift | medium | Disjoint ownership; W0 signatures compile first; the requests file; fixed merge order; additive-only changes to Guide types |
| The identity guard blocks a legitimate launch | medium | Fires only when both ids are present and differ and papers > 0; the alert always offers Open, Go Back, Choose or Quit; logged without paths |
| Data loss in `replaceIndexFromLibraryFolder` or the starter pack | medium | `backupNow()` first; only DB rows are dropped and files stay; the mail tables are kept; starter packs only on a pristine DB |
| Build-script changes break the user's signing or widget | medium | Defaults are identical; `--print-config` and the staged-plist diff; the same `--identifier`; the certificate-based DR check is kept; `--no-install` for every agent build |
| Swift 6 MainActor default with callback APIs (WidgetCenter) crashes | medium | nonisolated continuation wrappers; the build grep; fake facts in renders; live path M10 |
| Probe spam drains the battery or triggers CLI update checks | medium | Probes only while guide views are visible, with throttles; the selected provider from `agentStatus`; the Today card uses cheap facts only; `DISABLE_AUTOUPDATER` already set (`ChildEnvironment.swift:34`) |
| Settings import as an attack vector | medium | Allowlist; clamps; text caps; reader confirmation; organization section without free text; never enables AI or mail |
| Third-party UIs change (Power Automate, Google, Apple Mail) | medium | Short steps plus official links; `lastReviewed`; "drag .eml always works" in every route; Beta labels |
| About 400 new zh/en strings become inconsistent | low | `LocalizedText` requires both languages; catalog lint; renders in both languages |
| `washu` for every legacy install shows WashU text to a hypothetical other pre-existing user | low | Wording only (stricter or equal); one-click change in Profile; documented |
| A hypothetical second legacy install gets `import.lastFolder = ~/Desktop/Paper_reading` | low | Cosmetic; NSOpenPanel falls back when the folder is missing |

### 7.2 Deliberately out of scope (this round)
- OAuth or Graph mail sign-in (Outlook.com, Workspace). Guides are provided instead, because OAuth would need an app registration and break the "no IT approval, no API keys" principle.
- Live sync of one library across two Macs, and the lease file. Documented as "one Mac at a time", plus Rebuild index.
- Automated library move across volumes. Documented: move it in Finder, then Change….
- Opt-in bundle-id migration (distribution §4). Defaults are unchanged, so it isn't needed for the current user.
- `CLAUDE_CONFIG_DIR` / `CODEX_HOME` multi-account selection, a "Signed in as <email>" line, per-account usage pauses, and the bash/fish login-shell lookup. The custom path field and tutorials cover these.
- The Gmail per-account web link (`MailSettings.swift:117-121` keeps `/u/0/`).
- The Power Automate Outlook.com (personal) variant, and `mail.extraPaperHosts`.
- Notarization, universal or Intel builds, and auto-update. Documented as optional in BUILDING.
- A third UI language; AI cards or local checklists in Chinese (`CardSchema.swift:30`, `ChecklistHeuristics.swift:20-75`). Stated in the guide.
- The "What's new" banner; `profile.displayName`; `profile.cardLanguage`.
- Changing any registered default. The rule stands: any future default change pins the old value in a migration step first.

### 7.3 Facts to verify before stating them in the UI or docs (owner: W2 or S4)
- **V1.** `ProviderProbe` with no engine needs only `support/agent-cwd` (create it first) and refuses spawns (`Doctor.swift:20-24`).
- **V2.** On macOS 26, `WidgetCenter.getCurrentConfigurations` returns placed desktop widgets for a non-sandboxed host. Fallback: registered plus one manual tick.
- **V3.** An Apple Mail rule's "Run AppleScript" can write `.eml` files into a folder outside Mail's container on macOS 26 (TCC, whether Mail must be running). Beta until verified.
- **V4.** An Apps Script `getRawContent()` saved to Drive, then synced by Google Drive for desktop, is a valid `.eml` for `FolderMailSource` (line endings). Beta until verified.
- **V5.** `volumeIsRemovableKey` and `volumeIsLocalKey` classify external, network and cloud locations without triggering TCC.
- **V6.** `codex logout` exists; Claude `/logout` and `/login` work in the current CLI.
- **V7.** `HelpLink` renders in `.formStyle(.grouped)` headers and is captured by `--render`.
- **V8.** `NSAlert.showsHelp` with `alertShowHelp(_:)` works for the launch alert before the main menu exists.
- **V9.** A rebuild while `agent.mode` is on doesn't queue AI runs for papers that already have card.json (`Rebuild.swift:270-277` recreates only waiting jobs). Otherwise the Library page warns "N papers will be read".
- **V10.** Outlook.com app-password IMAP is still unavailable as of 2026-10 (MAIL_DESIGN Part B §3).
- **V11.** Widget discovery from `~/Applications`, and whether pkd loads an appex from a quarantined but approved host.
- **V12.** Each new sender-preset domain matches a real alert (the `verified` flag).
- **V13.** Government and China tenants' Power Automate portals. The UI only says "ask your IT" and links nothing.
- **V14.** `persistentDomain(forName:)` works for `ScratchDefaults` path suites (`ScratchDefaults.swift:15-40`). Fallback: `CFPreferencesCopyKeyList`.
