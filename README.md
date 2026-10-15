# PaperDeck

**English** · [简体中文](README.zh-CN.md)

PaperDeck is a macOS app for managing the papers you need to read. Drop a PDF on it and it files the paper into a tidy library, writes a reading checklist, schedules a reading deadline that fits your daily reading budget, and reminds you once a day what is left. Optionally it reads papers for you with **your own Claude or ChatGPT subscription** — through the official Claude Code CLI or Codex CLI, never an API key — and turns them into cards (TL;DR, summary, contributions, methods, results, limitations, key terms, category, tags, checklist). It can also collect reading requests from your email, answer questions about a paper with page citations, and explain any passage, figure or equation you point at, in any app.

The full user guide is in [docs/USER_GUIDE.md](docs/USER_GUIDE.md). The same content is available in the app (**Help ▸ PaperDeck Help**, ⌘?), where every step checks your Mac's real state.

## Features

- **Drop anywhere** — a slim panel at the screen edge expands when you start dragging a PDF, folder or PDF link; also the menu-bar icon, Finder *Open With*, the main window and the Dock.
- **Library cards** — Today / To Read / Reading / Read / categories / Recently Deleted, with a card grid and a detail inspector (⌘I). Papers are stored as readable folders (`2025_Author_Title/…pdf`, `card.json`, `notes.md`); the database can always be rebuilt from those files.
- **Checklist, deadlines and a daily reminder** — deadlines are placed against your daily reading budget; one notification per day (11:00 by default) lists what to read, with *Skip today* and *Remind me in 1 hour*.
- **AI reading cards** (optional) — Claude Code CLI or Codex CLI, using your subscription login only. Off until you turn it on.
- **Duplicate check** — SHA-256, DOI/arXiv (incl. both bioRxiv prefixes), preprint ↔ published links, and title/text similarity; a decision sheet offers *Keep the new one / Re-read the earlier one / Keep both / Skip*. Nothing is replaced, merged or deleted without your click.
- **Multi-select and batch actions** — status, priority, category, tags, deadline, delete (with undo), export (BibTeX / RIS / CSV / Markdown), re-read with AI, duplicate check.
- **Ask** — questions about one paper (or up to 10 selected papers) with streamed answers and `p. N` citations that open the built-in reader at the cited sentence.
- **Explain** — press ⌃⌥E in any app (Preview, a browser, Acrobat, Skim, the PaperDeck reader…), drag a box or use the magnifier, and get an explanation next to the text; copy-then-⌃⌥E and the Services menu work without any permission.
- **Minimal PDF reader** — thumbnails, page labels, find, page memory, *Copy as citation*, region capture; Preview stays the default PDF opener.
- **Mail** — capture reading requests from allowlisted senders (advisors, collaborators, paper alerts) via a Microsoft 365 Power Automate folder, IMAP with an app password, or by dragging emails in; PDF attachments, Word manuscripts and paper or share links become rows you can merge into the library.
- **Desktop widget** (display only) and a menu-bar summary.
- **Portable configuration** — institution and field presets, settings export/import (never passwords), "use an existing library" for moving to another Mac, an 8-step first-run guide and an in-app Help Center.

## Requirements

- macOS 26 or later (Apple silicon tested).
- To build: Xcode **Command Line Tools** only (`xcode-select --install`); Xcode itself is not needed.
- Optional AI: the [Claude Code CLI](https://claude.ai/install.sh) signed in with a Claude subscription, and/or the Codex CLI signed in with ChatGPT (bundled with the ChatGPT desktop app, or `brew install --cask codex`).

## Build and install

```bash
./build_app.sh --run
```

- Installs to `/Applications/PaperDeck.app` (updated in place) and signs it with a self-signed code-signing certificate named **PaperDeck Local Signing** from your login keychain, so permissions, notifications and the widget survive rebuilds. Create it once: *Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…*, type *Code Signing*, validity 3650 days. Without it the script explains the steps; `--allow-adhoc` signs ad hoc for a quick try.
- Your own bundle id, signing identity, install folder etc.: copy `build.local.env.example` to `build.local.env` (not committed) or use environment variables / flags. `./build_app.sh --print-config` shows the result without building. See [docs/BUILDING.md](docs/BUILDING.md).
- Useful flags: `--no-install`, `--package` (a zip + INSTALL.md for someone else in `dist/`; never share your certificate), `--jobs N`, `--test`, `--dev` (forces every AI switch off for GUI debugging — don't use it for the copy you use every day).
- Tests: `./test.sh -j 8` (Swift Testing). `tools/verify_portability.sh` runs all portability checks.

Received a packaged build from someone? Move PaperDeck.app to Applications **before** the first launch; see [docs/INSTALL_RECIPIENT.md](docs/INSTALL_RECIPIENT.md).

## First run

A short setup guide (skippable steps; reopen it from *Help ▸ Setup Assistant…*):

1. **Welcome** — language; *Quick start*, *I'm moving from another Mac…*, or *Use a setup file from my lab or IT…*.
2. **About you** — field, career stage, how the AI should think of you, research interests, your institution's AI policy.
3. **AI** — detects Claude Code / Codex and their sign-in (no quota used). *Not now* is fine; nothing is sent until you turn it on.
4. **Library** — where your papers live (Documents, another folder, or an existing PaperDeck library).
5. **Plan & reminder**, **Mail** (optional), **Import existing PDFs** (optional; APFS clones use almost no extra space, originals are never modified), **Done** (a one-minute tour).

The UI is English by default; *Settings ▸ General ▸ Language* switches to Chinese. AI-generated card text is always English.

## AI: Claude, ChatGPT, or none

| | Claude | ChatGPT (Codex) |
|---|---|---|
| Install | `curl -fsSL https://claude.ai/install.sh \| bash` | bundled with the ChatGPT desktop app (found automatically) or `brew install --cask codex` |
| Sign in | run `claude`, type `/login`, choose your Claude subscription (claude.ai) | `codex login` → **Sign in with ChatGPT**; `codex login status` should say *Logged in using ChatGPT* |

Then *Settings ▸ AI Reading ▸ I've signed in*, pick the service and turn AI reading on.

- **Subscription only.** Before every run PaperDeck checks that the CLI uses a subscription login (Claude `authMethod == claude.ai`; Codex must be a ChatGPT login — API-key logins are refused, so nothing is billed to an API account). The child process gets an allowlisted environment (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CODEX_API_KEY` … never pass through). Codex runs with `--sandbox read-only`, `--ignore-user-config` and every tool feature disabled; paper text is sent as untrusted data to a model with no tools.
- **Quota-aware.** Usage-limit messages pause that service until it resets; a run log records service, model and timing. Detection (`--version`, login status) costs nothing.
- **Without AI** you still get local checklists, metadata lookup by DOI/arXiv/title, deadlines, the daily plan and reminder, search, the widget and rule-based mail sorting.

## Explain and Ask

Both share one switch in *Settings ▸ Explain & Ask*, **off by default**; turning it on sends nothing. Every call needs your own click, Return or button press in PaperDeck — the shortcut alone or a Services request never sends anything.

- **Explain** — ⌃⌥E dims the screens: drag a box, click a paragraph, or press Space for a magnifier; ⌥ sends the region as an image (figures, equations, tables). Copy-then-⌃⌥E, the Services menu (*Explain with PaperDeck*) and dropping an image need **no** permission; box/magnifier need *Screen Recording* once (PaperDeck explains first, then macOS asks). The panel floats next to the text: EN | 中 (Chinese with English terms by default), *Simpler · More technical · Define terms · Translate · Explain the figure*, follow-ups, copy, pin, save to notes, history.
- **Ask** — the detail inspector's *Ask* tab; streamed answers with page citations that open the reader at the supporting sentence; *Quick* (Haiku / GPT-5.6-Luna, default) or *Thorough* (Sonnet / GPT-5.6-Terra); answers in the question's language, English or Chinese; up to 10 selected papers in the *Ask* window.
- **Limits and privacy** — 50 calls a day ask first, 150 is the cap. Papers marked *Never use AI* are never sent; unpublished/confidential papers, papers from a confidential email (a review invitation, a manuscript under review), papers from personal email without a DOI/arXiv id, and anything showing a mail or chat window (mail apps, webmail and web chat in a browser, notification banners, PaperDeck's own Mail inbox) always ask before sending; without Screen Recording, text copied in a browser or sent from one through Services asks too, since webmail can't be told apart. Explanations are kept 90 days (pinned or saved ones are kept).

## Mail

PaperDeck can turn emails into **reading requests**: papers an advisor or colleague asks you to read or present, journal-club papers, papers shared with you, and paper alerts (Google Scholar, bioRxiv, arXiv, journal TOCs). Each relevant email becomes a card in the sidebar's *Mail* inbox — who sent it, what they asked, any due date, and every paper in it (PDF attached, downloadable, needs a PDF, already in library, Word manuscript, shared document) — and you can merge papers into the library one by one or all at once.

- **Read-only allowlist.** Only mail from senders on your list is opened; other mail is never read or stored. Nothing is sent, marked read, moved or deleted.
- **Sources** (*Settings ▸ Mail ▸ Accounts ▸ Add Account…*):

| Your mail | Route |
|---|---|
| Work/school Microsoft 365 (Outlook) | **Power Automate**: your own flow saves allowlisted mail as `.eml` into OneDrive, which syncs to your Mac; PaperDeck watches that folder. No app registration or IT approval needed if your institution allows Power Automate. See [docs/guides/POWER_AUTOMATE.md](docs/guides/POWER_AUTOMATE.md) |
| Microsoft 365 without Power Automate | drag emails in; an Apple Mail rule saving to a folder; or forward alerts to Gmail/iCloud |
| Gmail / iCloud / Yahoo / Fastmail / other IMAP | app-specific password, read-only IMAP (EXAMINE + BODY.PEEK) |
| Any folder that already receives `.eml` files | *.eml folder* account |

  You can always **drag emails from Outlook or Mail (or `.eml` files) onto PaperDeck** with no account at all.
- **Sorting.** Local rules classify each email immediately (request type, due date, papers, Safe Links/Proofpoint unwrapping). Paper alerts may be refined by AI automatically within a daily cap; **advisor/colleague mail goes to AI only after you click *Analyze with AI*** on that card. Word manuscripts from people can be converted to PDF locally (the original is kept next to it) and are treated as possibly unpublished.
- **Confidential mail** — review invitations, manuscript-system mail, decisions/proofs about your own submissions, and mail marked confidential — is never sent to AI, merged or downloaded automatically.
- The inbox shows one compact status pill (accounts, last sync, AI triage usage) and at most one notice at a time. Files in a Power Automate folder that aren't complete emails can be **ignored** (you are told again only about new ones) or **moved to the Trash** (only those files, restorable with Put Back).
- Passwords live only in your login keychain. Email bodies are deleted 30 days after a card is handled (configurable).

## Library, privacy and moving to another Mac

- Library default: `~/Documents/PaperDeck`; any folder, cloud-synced folder (use it on one Mac at a time) or external disk works. Imports use APFS clones; originals are never modified. Deleted papers stay in *Recently Deleted* for 30 days.
- Metadata (title, authors, venue, year) comes from free public sources — Crossref, arXiv, bioRxiv, OpenAlex — and can be turned off.
- **Another Mac:** *Settings ▸ General ▸ Export Settings…* (never includes passwords), copy the library folder, then on the new Mac *Use an existing PaperDeck library…* and *Import Settings…*; settings that are stricter on the new Mac about privacy or AI quota are kept unless you tick them one by one. See [docs/guides/MOVE_TO_ANOTHER_MAC.md](docs/guides/MOVE_TO_ANOTHER_MAC.md) and [docs/guides/DIFFERENT_ACCOUNT.md](docs/guides/DIFFERENT_ACCOUNT.md).
- **Institution AI policy** (*Settings ▸ Profile*) only changes wording; the safety defaults above are the same for everyone and can't be loosened by a preset or an imported file.

## Command line (diagnostics; never touches your real library)

```bash
PD=/Applications/PaperDeck.app/Contents/MacOS/PaperDeck
$PD --doctor                     # CLIs and sign-in (no quota), signing, database, widget, mail
$PD --doctor --mail-only         # mail accounts and sender list only
$PD --config                     # institution, field, bundle id, keychain service (read-only)
$PD --selftest all --root /tmp/pd-test       # full pipeline on sample data with a mock AI
$PD --mail-dry-run message.eml   # parse + local sorting + the exact text that would go to AI (no AI, no network)
$PD --export-settings settings.json
$PD --help
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) (English and Chinese); *Help ▸ Troubleshooting* in the app shows the items that apply to your Mac first. Common ones: the widget isn't listed (*Settings ▸ Widget ▸ Repair registration*), no notifications (*System Settings ▸ Notifications ▸ PaperDeck*), Claude/ChatGPT shows *not signed in* (`claude` → `/login`, or `codex login` → Sign in with ChatGPT, then *I've signed in*), no full-text search after moving Macs (*Settings ▸ Library & Storage ▸ Rebuild full-text index*).

## Documentation

| Document | Contents |
|---|---|
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | User guide (section anchors = Help Center topic ids) |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Troubleshooting (generated from the Help Center) |
| [docs/guides/](docs/guides/) | Power Automate, moving to another Mac, switching accounts |
| [docs/institutions/](docs/institutions/) | Institution notes and template |
| [docs/INSTALL_RECIPIENT.md](docs/INSTALL_RECIPIENT.md) | Installing a build someone sent you |
| [docs/BUILDING.md](docs/BUILDING.md) | Building, signing, `build.local.env`, packaging |
| [docs/ARCHITECTURE-CONFIG.md](docs/ARCHITECTURE-CONFIG.md) | Configuration layer, settings keys, migrations, presets |
| [docs/DESIGN.md](docs/DESIGN.md) · [docs/MAIL_DESIGN.md](docs/MAIL_DESIGN.md) · [docs/RESEARCH.md](docs/RESEARCH.md) · [docs/proposals/](docs/proposals/) | Design notes, research and plans (historical, partly in Chinese) |

## Project layout

| Directory | Responsibility |
|---|---|
| `Sources/PaperDeckShared` | Shared by app and widget: dates, deadline labels, widget snapshot, deep links, build identity |
| `Sources/PaperDeckObjCSupport` | A tiny Objective-C shim that catches framework exceptions (PDFKit's "nil NSFont" during title reads) |
| `Sources/PaperDeckCore` | Models, SQLite (FTS5), PDF extraction, metadata, import pipeline, planning, AI agents (Claude Code / Codex), mail, dedupe, Q&A, explain, engine |
| `Sources/PaperDeckConfig` | Institution / field / sender presets, config resolution and migration, mail sources, settings export/import, Help Center content |
| `Sources/PaperDeck` | AppKit + SwiftUI app: windows, settings, Help Center, floating panel, menu bar, reminders, reader, explain overlay, CLI |
| `Sources/PaperDeckWidget` | WidgetKit widget (display only; taps deep-link into the app) |
| `Tests/PaperDeckCoreTests` | Swift Testing suites (`./test.sh`) |

Built with SwiftPM and Swift 6 using only the Command Line Tools.
