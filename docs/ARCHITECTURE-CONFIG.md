# Configuration architecture

How PaperDeck keeps institution-, field- and person-specific values out of the code, so a new user,
Mac or account needs choices in the UI rather than code changes.

## Layers

```
PaperDeckShared  (Foundation; app + widget)
  ├─ BuildIdentity            bundle id, widget id, keychain service, log subsystem, signing, channel
  └─ DeepLink                 paperdeck://help[/<topic>], paperdeck://setup, …
PaperDeckCore    (engine; knows no institution, field or provider folder names)
  ├─ Agent/CardPrompt.swift   CardPromptProfile + the card prompt template
  ├─ Mail: MailAccount.source, MailSettings.dateOrder, SlashDateOrder
  ├─ StarterPack, LibraryIdentity (guard + inspector), full-text re-index
  └─ ProviderProbe            zero-quota CLI detection without an engine
PaperDeckConfig  (deps: Core, Shared; values only — no UI, no actors)
  ├─ Model/ Presets/ Resolve/ Migrate/ Mail/ Strings/ Portability/
  └─ Guide/ (model, evaluator, checklist, search, markdown, diagnostics)
     Guide/Content/ (the bilingual Help Center topics)
PaperDeck app    (MainActor)
  ├─ App/ConfigStore.swift    observable; writes keys; mirrors institution / field into LangStore
  ├─ L10n delegates institution- and field-dependent text to OrgStrings / FieldStrings
  └─ Views/Onboarding, Views/Help, Settings ▸ Profile, the CLI (--config, --migrate-dry-run, …)
```

Data flow:

```
launch ─▶ ConfigMigration.runIfNeeded (before SettingsStore registers defaults)
UserDefaults ─▶ ConfigResolver ─▶ ConfigSnapshot ─▶ ConfigStore (app) ─▶ LangStore.org / .field ─▶ L10n
                                        └─ cardPromptProfile ─▶ Engine.Dependencies.loadCardProfile
                                                                 └─▶ AgentQueue CardRequest(systemPrompt:)
MailSettings.load (+ dateOrder) ─▶ MailSyncActor ─▶ MailHeuristics.findDue(dateOrder:)
```

The engine reads the card profile each time it builds a request, so a Profile edit applies to the
next card without a restart.

## Rules

1. **No institution in the engine.** Core never mentions an institution or a field id. It receives
   values: a `CardPromptProfile` and a `SlashDateOrder`. (Core can't import PaperDeckConfig, so the
   compiler enforces it.)
2. **No UI in Config.** PaperDeckConfig holds values and pure functions; it starts no actors.
3. **One home for institution literals:** `Sources/PaperDeckConfig/Presets/OrganizationPresets.swift`.
   Code elsewhere names the preset that every pre-existing install maps to as
   `OrganizationPresets.legacyInstallPreset`. A lint test checks `Sources/` (G1).
4. **One home for cloud-folder names:** logic that recognizes cloud root names
   (`OneDrive-<Tenant>`, `Dropbox`, `GoogleDrive-<account>`, …) lives only in
   `Sources/PaperDeckConfig/Mail/CloudRootLocator.swift`. It lists only the root names in
   `~/Library/CloudStorage` and never reads inside them (G4).
5. **Preset ids are append-only.** An unknown id falls back to `generic` / `general` and is logged; it
   never crashes.
6. **No resource bundles.** Presets and help content are Swift literals (a SwiftPM resource bundle
   would point `Bundle.module` at the build machine's path).
7. **Identity has defaults, never literals elsewhere.** The default bundle id appears once in
   `BuildIdentity.swift`, once in `build_app.sh`, and in `Resources/*.plist`; everything else derives
   from `BuildIdentity.current` (G2). Personal folders appear only as the legacy import folder in
   `Presets/LegacyInstall.swift` (G3).
8. **Safety floors are code, not data:** AI off until turned on, mail off until an account passes
   Test & Save, people's emails ask first, unidentified person PDFs held, the confidentiality guard,
   the triage cap. A preset or an import can only choose stricter defaults for new senders.

The grep allowlist (G1–G6) runs with `tools/verify_portability.sh --greps-only`.

## Settings keys

None of these keys is passed to `register(defaults:)`; every older key and default is unchanged.

| Key | Type | Written by | Absent means |
|---|---|---|---|
| `config.migrationVersion` | Int (1) | ConfigMigration | not migrated |
| `config.origin` | `legacy` / `fresh` | ConfigMigration | `LegacyInstallDetector` result |
| `config.migratedAt`, `config.migrationNote` | Double / String | ConfigMigration | — |
| `org.preset` | `generic` / a built-in id / `custom` | migration, onboarding, Profile, import | fresh → `generic`; legacy → the legacy preset |
| `org.custom` | JSON `OrganizationProfile` (no texts) | Profile, import | used only for `custom` |
| `profile.field` | FieldPreset id | migration (legacy), onboarding, Profile, import | fresh → `general`; legacy → `lifeSciencesCompBio` |
| `profile.stage` | `masters` / `phd` / `postdoc` / `faculty` | onboarding, Profile | `phd` |
| `profile.readerDescription` | String (≤ 200, sanitized) | Profile, onboarding (only when edited), import (confirmed) | composed from field and stage |
| `mail.dateOrder` | `mdy` / `dmy` / `auto` | migration (legacy `mdy`, fresh `auto`), Mail settings | `mdy` |
| `mail.cloudRoot` | root directory name | folder / Power Automate form | no last choice |
| `MailAccount.source` (inside `mail.accounts`) | `MailSourceID` raw value | add / edit sheet | inferred from the account (legacy rule) |
| `import.lastFolder` | `~/…` | import panels, migration (legacy) | `~/Downloads` |
| `library.pendingAction` | JSON `LibraryPendingAction` | Settings ▸ Library ▸ Change… | none |
| `library.previousPath` | String | Change…, the mismatch alert | none |
| `onboarding.version`, `.completedAt`, `.aiDecision`, `.mailDecision`, `.legacy` | — | the setup window | informational / rollback flag |
| `guide.checklist.dismissed`, `guide.skipped`, `guide.manualDone`, `guide.activity` | — | Help Center | false / [] / {} |
| `transfer.lastExportedAt`, `transfer.importedAt` | Double | Export / Import | — |

Settings files (`paperdeck.settings/1`) export an **allowlist** (`Portability/SettingsRegistry.swift`);
`agent.mode`, `mail.enabled`, `setup.completed`, `config.*`, `onboarding.*`, `guide.*`,
`transfer.*`, window frames, keychain items and the database are never exported or imported.

## The migration

`ConfigMigration.runIfNeeded` runs once (gated by `config.migrationVersion ≥ 1`) as the first
statement of `applicationDidFinishLaunching`, before `SettingsStore` registers defaults. The CLI,
`--selftest` and `--render` never run it; they resolve values on read.

Inputs: the **persisted** domain only (`persistentDomain(forName:)`, never registered defaults — those
include `setup.completed` and `library.path`) and whether the index database file exists (checked,
never opened).

```
isLegacy := databaseExists
   || has(setup.completed) || has(library.path) || has(mail.accounts) || has(mail.senders) || has(agent.provider)
   || agent.mode ∉ {absent, "off"}            # a --dev build writes only agent.mode=off, assist.mode=off and
                                              #   dedupe.ai.auto=false → fresh
legacy → back up the domain to <support>/Backups/settings-before-config-v1-<stamp>.plist
         (no writes if the backup fails), then add only absent keys:
         org.preset = the legacy preset, profile.field = lifeSciencesCompBio, mail.dateOrder = mdy,
         import.lastFolder = the legacy import folder, config.migrationNote = <markers>
fresh  → mail.dateOrder = auto
both   → config.origin, config.migratedAt, config.migrationVersion = 1 (last)
```

It never rewrites an existing key — not `agent.*`, `library.path`, the `mail.*` JSON, `language`,
`setup.completed` or `reminder.*`. Every install from before the configuration layer maps to the
legacy preset, because every such install showed that wording; the markers only feed the note in
Settings ▸ Profile. Downgrading is safe: only new keys and one optional JSON field are added.

Check it without touching any domain:

```bash
PD=/Applications/PaperDeck.app/Contents/MacOS/PaperDeck
defaults export <bundle id> /tmp/settings.plist          # a copy; quit PaperDeck first
$PD --migrate-dry-run --plist /tmp/settings.plist --db-exists yes --out /tmp/migrated.plist
$PD --config --plist /tmp/migrated.plist --db-exists yes
$PD --config --plist /tmp/migrated.plist --card-prompt-sha256
```

**Rule for future default changes:** any change of a registered default first adds a migration step
that pins the old value for existing installs.

## The card prompt

`CardSchema.systemPrompt` is the original literal. `CardSchema.systemPrompt(for:)` returns that
literal for `CardPromptProfile.legacyCompBio` (byte-identical by construction) and otherwise renders
`CardPromptTemplate` with five slots: reader, difficulty reference, method hint, typical times and
four checklist examples. The SECURITY, FACTUALITY, STYLE, CATEGORY, TAGS and READING PLAN paragraphs
are shared. A user-written reader line replaces the reader; it is sanitized (one line, no control
characters or angle brackets, ≤ 200 characters) and, from an imported file, needs confirmation.

## Adding a preset

**An institution** (`Presets/OrganizationPresets.swift`):

1. Add a `static let <id>: OrganizationProfile` with a new, never-reused `id`, `name` (en and zh),
   `shortName`, `approvedAITools`, `policyURL` (https), `peopleDefault` (`.ask` or `.never` — there is
   no "always" for people), and `mail` hints (`oneDriveRootHint`, `oneDriveFallbackRootName`,
   `knownSenderDomains`, `powerAutomatePortal`).
2. Leave `texts` empty to use the composed wording (`OrgStrings` builds it from the name, short name
   and tools); fill it only for verbatim wording.
3. Append it to `builtIn`. Add a page under `docs/institutions/` from `_template.md`.
4. Tests: the organization-strings suites check that composed wording contains no other institution's
   name; add a case for the new preset.

**A field** (`Presets/FieldPresets.swift`): a new id, `name` (en and zh), SF Symbol, `readerPattern`
(`"… ({level})"`), `difficultyPattern` (`"… {stage}"`), method hint, typical times, exactly four
checklist examples, at most seven starter categories (names ≤ 40 characters), sender preset ids, and
the four example texts. Append it to `all`. `FieldPresetTests` checks the shape.

**A sender preset** (`Presets/SenderPresets.swift`): append an entry with `verified: false` until its
pattern was checked against a real alert; unverified presets appear under "More presets" with a hint.

**A mail route or a Help topic:** mail routes are `MailSourceID` cases with a `MailSourceCatalog`
entry; Help topics are `GuideTopicID` constants (the catalog in `Guide/GuideModel.swift`) with content
in `Guide/Content/`. Topic ids are also the anchors of `docs/USER_GUIDE.md` and the
`paperdeck://help/<id>` links.
