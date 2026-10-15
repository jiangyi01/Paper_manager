# PaperDeck User Guide

PaperDeck is a paper-reading manager for macOS. Drop a PDF on it and it files the paper in your
library, makes a reading card with a checklist and a deadline, plans what to read each day and
reminds you once a day. Optionally it reads papers with **your own Claude or ChatGPT subscription**
(through the official command-line tools — never an API key) and collects reading requests from
your email.

The same help is built into the app: **Help ▸ PaperDeck Help** (⌘?). There every step checks this
Mac's real state and ticks itself when it's done. The section anchors in this guide are the Help
Center's topic ids, so a link such as `paperdeck://help/connect-mail` opens the same topic in the app.

- [Where PaperDeck lives](#where-paperdeck-lives)
- [Install](#install)
- [First run](#first-run)
- [Everyday use](#everyday-use)
- [AI reading](#ai-reading)
- [Explain what's on screen](#explain)
- [Ask and the reader](#ask)
- [Your field and institution](#profile-field-institution)
- [The library](#the-library)
- [Mail](#mail)
- [Moving to another Mac, giving PaperDeck to a labmate](#moving-and-sharing)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [Appendix](#appendix)

---

## Where PaperDeck lives

PaperDeck has no Dock icon. It lives in:

- **The edge strip** — a thin strip at the edge of your screen. Start dragging a PDF, a folder or a
  PDF link anywhere and it opens; let go to import. Hover over it to see today's list.
- **The menu-bar icon** — today's count, today's list and the AI reading status. You can drop
  files on the icon too.
- **The window** — Today, To Read, Reading, Read, categories and Recently Deleted, with the
  reading card beside the paper (⌘I).
- **The desktop widget** (display only) — right-click the desktop ▸ Edit Widgets… ▸ search for
  PaperDeck.
- **Finder** — Open With ▸ PaperDeck, or `open -a PaperDeck paper.pdf` in Terminal.
- **The daily reminder** — one notification a day (11:00 by default; change it in Settings ▸ Plan &
  Reminders) with today's papers, Skip Today and Remind Me in 1 Hour.

Help is always under **Help ▸ PaperDeck Help**, and in the menu bar under **Help & Setup**.

## Install

**(a) Someone sent you PaperDeck.** Unzip it and move **PaperDeck.app into Applications before you
open it the first time** (the widget and Open at Login need it there). macOS says it can't check the
app: open **System Settings ▸ Privacy & Security**, scroll down, click **Open Anyway** and confirm.
The step-by-step version is [docs/INSTALL_RECIPIENT.md](INSTALL_RECIPIENT.md).

**(b) Build it yourself.** You need macOS 26 and the Command Line Tools (no Xcode). See
[docs/BUILDING.md](BUILDING.md).

## First run

<a id="getting-started"></a>
On a new Mac PaperDeck opens a setup window. Every page can be revisited later from
**Help ▸ Setup Assistant…** (also in Settings ▸ General); revisiting never changes anything until you
confirm a change.

1. **Welcome.** Switch the language here (English | 中文). Choose **Get Started**, **I'm moving from
   another Mac…** (preselects "Use an existing library" and offers to import a settings file), or
   **Use a setup file from my lab or IT…**. *Quick start with recommended defaults* creates the
   library in Documents/PaperDeck, leaves AI and mail off, and jumps to the end — you can change
   everything later.
2. **About you.** Your research field (11 fields), career stage, how the AI should picture you, your
   research interests, and your institution's AI policy — see [Your field and institution](#profile-field-institution).
3. **AI reading (optional).** PaperDeck checks whether Claude Code and the Codex CLI are installed
   and signed in, without using any quota. Pick one, or **Not now**. Reading starts only when you
   click **Turn On** — see [AI reading](#ai-reading). Clicking a card only shows that service's
   install and sign-in steps: when reading is already on with the other service, it moves only when
   you click **Switch Reading to ‹service›**.
4. **Library.** Choose where the library lives *before* it's created: a new library in Documents
   (or ~/PaperDeck when Documents is in iCloud), in another folder, or **Use an existing PaperDeck
   library…**. macOS asks once for access to Documents — click Allow.
5. **Daily plan & reminder.** Your daily reading budget, reading days, the reminder time,
   notifications, and *Open PaperDeck at login* (recommended — it lives in the menu bar).
6. **Mail (optional).** Where your mail lives, then the matching route — see [Mail](#mail). You can
   also choose *Only when I drag emails in*, or *Not now*.
7. **Import (optional).** Bring in PDFs you already have (for example your Downloads folder; Zotero
   users: `~/Zotero/storage`, PDFs only). Files are copied — APFS clones take almost no extra space —
   and the originals are never touched.
8. **Finish.** A summary with a Change link per line, and the 1-minute tour.

Afterwards **Getting Started** on the Today page (and in the Help Center) lists the few remaining
things worth doing — your first paper, the widget, a settings backup — and ticks each one as
PaperDeck sees it done. Dismiss it any time.

<a id="tour"></a>
**The feature tour** (Help ▸ Feature Tour) is seven short pages — dropping papers, Today, the
reading card, AI reading, mail, the reminder and widget, and your data — each with a **Show Me**
button that points at the real thing.

## Everyday use

- **Add papers:** drop PDFs on the edge strip, the menu-bar icon or the window; Open With; or paste
  a PDF link. Duplicates are recognized by content, DOI / arXiv id, preprint ↔ journal version and
  title and text; PaperDeck asks before anything is replaced ([Duplicates](#duplicates)) — a new
  version of the same paper can replace the old file and keep your checklist.
- **Several papers at once:** ⌘- / ⇧-click or Select ▾, then change, export or check them together
  ([Selecting several papers](#multi-select)).
- **Explain what's on screen:** ⌃⌥E (or Services ▸ Explain with PaperDeck, or ⌘C then ⌃⌥E) puts a
  short explanation of a passage, figure or formula beside it, in any app that shows the paper
  ([Explain](#explain)). Off until you turn on Explain & Ask; every explanation is your own click.
- **Ask about a paper:** the inspector's **Ask** tab answers questions about the paper with page
  citations; select several papers to ask across them ([Ask and the reader](#ask)). Off until you
  turn it on; nothing is sent until you press Ask.
- **Read in PaperDeck:** citations and checklist "p. N" chips open the built-in reader at that page;
  Preview stays the default for everything else ([The reader](#reader)).
- **Today:** the papers to read now within your daily budget, deadlines first. **Skip Today** moves
  today's plan by a day.
- **Reading card:** a TL;DR and summary (with AI), contributions, methods, results, limitations,
  key terms, category, tags, an estimate, and a reading **checklist** with minutes per step. Tick
  steps as you read; edit anything. Without AI the checklist is made on your Mac.
- **Deadlines:** set a due date per paper; the plan schedules the remaining steps before it.
- **Search:** titles, authors, tags and the full text of the PDFs.
- **Deleting** moves a paper to Recently Deleted; after 30 days it goes to the Trash.
- **Metadata** (title, authors, journal, year) comes from free public sources — Crossref, arXiv,
  bioRxiv, OpenAlex — and can be turned off in Settings.

## AI reading

<a id="ai-setup"></a>
### Set up Claude or ChatGPT

PaperDeck can read each paper with **Claude** (the official Claude Code CLI) or **ChatGPT** (the
official Codex CLI). Both use **your own subscription login — never an API key** — and both are off
until you turn them on. You only need one.

| | Claude | ChatGPT (Codex) |
|---|---|---|
| Install | `curl -fsSL https://claude.ai/install.sh \| bash` | the ChatGPT desktop app includes it; or `brew install --cask codex` |
| Sign in | run `claude`, type `/login`, choose your Claude account (claude.ai) | `codex login` ▸ *Sign in with ChatGPT* |
| Check | Settings ▸ AI Reading shows "Signed in · <plan>" | `codex login status` says you're logged in using ChatGPT |

Then click **I've Signed In** in Settings ▸ AI Reading, pick the service and turn AI reading on.
New papers are read automatically; dropping more than 3 at once asks first. Detection only runs
`--version` and status commands — it never uses quota.

- **Switching services:** the reading service picker at the top of Settings ▸ AI Reading switches
  at once (the paper being read finishes with the old one). Claude and ChatGPT limits are separate.
- **Usage limits:** when a subscription's limit is reached, PaperDeck pauses that service until the
  reset time and then continues on its own. Nothing is lost.
- **Run log:** Settings ▸ AI Reading lists every run: service, model, duration, and Claude's
  estimated cost or ChatGPT's token counts.
- **What is sent:** the paper's text (as untrusted data), its metadata, your library's category
  names and frequent tags, and one line describing you (Settings ▸ Profile). The model gets no tools.
  AI cards are always written in English.

<a id="ai-without"></a>
### Using PaperDeck without AI

Everything except the AI-written parts works without AI: a reading checklist made on your Mac,
title / DOI / arXiv lookup, deadlines, the plan and reminder, search, the widget, and mail sorted by
local rules. You won't get TL;DRs, summaries, AI categories and tags, or AI sorting of email alerts.
If you turn AI on later, Settings ▸ AI Reading offers to queue the papers added in the meantime.

<a id="ai-switch-account"></a>
### Switching AI accounts

PaperDeck uses whichever account the command-line tool is signed in to; it stores no AI login
itself. To switch, sign out and in again in Terminal, then click **I've Signed In**:

- Claude: run `claude`, type `/logout`, then `/login` with the other account.
- ChatGPT: `codex logout`, then `codex login` ▸ *Sign in with ChatGPT*.

A usage-limit pause from the previous account ends at its reset time. A login with an API key is
refused by design. More: [docs/guides/DIFFERENT_ACCOUNT.md](guides/DIFFERENT_ACCOUNT.md).

<a id="explain"></a>
## Explain what's on screen

**Explain** puts a short explanation of a passage, figure, table or formula right beside it — in
Preview, a browser, Acrobat, Skim, the PaperDeck Reader or any other app that shows the paper —
using **your own Claude or ChatGPT subscription**. It shares the **Explain & Ask** switch with Ask:
off until you turn it on in **Settings ▸ Explain & Ask**, and turning it on sends nothing. Every
explanation needs your own gesture in PaperDeck (a box, a click, Return, a button in the panel) —
the shortcut alone and a Services request never send anything — and each one counts once on your
subscription.

**Ways in.** The shortcut **⌃⌥E** and the menu bar's **Explain…** open a dimmed overlay over every
display; the menu bar also has **Explain Copied Text** and **Explanation History**, and the library
window has the same items in its **Explain** menu. The shortcut is held only while Explain & Ask is on
(Settings ▸ Explain & Ask ▸ Explain ▸ *Shortcut* changes it and says when another app already uses
it). If it doesn't fire — a password field elsewhere can block shortcuts — use the menu bar.

Without any permission:

- **Copy, then the shortcut:** select text, press ⌘C, then ⌃⌥E: the overlay offers *Explain copied
  text ⏎* — press Return (or click it). Pressing ⌃⌥E twice quickly shows that offer even for text you
  explained before; it still waits for Return. Until you press Return, PaperDeck sees only whether
  something new was copied, not what.
- **Services:** right-click a selection › Services › **Explain with PaperDeck**: the panel opens with
  the text and a **Send** button, and nothing is sent until you press Return or click Send (another
  app can't send anything by calling the service). **Ask PaperDeck…** opens the panel with a question
  field and sends nothing until you ask. It works in most apps; you can give it a key in System
  Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.
- **A screenshot:** ⌃⇧⌘4 copies a region of the screen to the clipboard; then ⌃⌥E and Return.
- **Drop an image** (a screenshot thumbnail, a PNG or JPEG file) on the edge strip, the menu-bar icon,
  the library window or an explanation panel. A drag that holds any PDF, folder or email imports
  exactly as before.

With **Screen Recording** ([below](#screen-recording)):

- **Box:** drag over what you want explained; releasing explains it. A click without dragging explains
  the paragraph under the pointer; on a chart or a picture it sends only that figure (or a small area
  around the click), never more of the screen. Where nothing is legible the overlay says so and sends
  nothing.
- **Lens:** press Space to switch: a magnifier follows the pointer (scroll to zoom, 1.5×–6×). Click a
  paragraph to explain it; ⇧-click a word to define that term. Space switches back.
- Hold **⌥** while you release or click to send it as a figure (the image itself): a box sends the
  box, a click the figure under the pointer, found by its own edges. **Tab** switches the answer
  between EN and 中 for this request; **Esc** or a right-click cancels. Switching Spaces, a display
  change or sleep closes the overlay (nothing is sent).

**The panel** opens beside what you marked and floats over every app and Space (full screen too),
without taking the focus from your PDF app:

- **EN | 中** — Chinese with the English terms in parentheses by default (Settings ▸ Explain ▸
  *Explanation language*); switching after an answer offers to explain it again in the other language.
- **Simpler · More technical · Define terms · Translate**, and **Explain the figure** for an image
  (⌘1–⌘5); ⌥-click one for the *Thorough* model. The follow-up field asks about the same passage (follow-ups on Claude answer in about a
  second: the conversation stays open).
- **Copy**, **Pin** (pinned panels stay when the next one opens — up to 3 — and their explanations are
  kept), **Save to Notes** (for a paper in your library: appended to its notes with the page),
  **History**, **Stop** / **Regenerate**, and *today N*. **Esc** closes the panel.
- The header names the paper PaperDeck matched — from the window's title or the text, never sent —
  and the page, or says *Not from your library*. If it picked the wrong paper, **Change…** picks
  another and **Not this paper** drops it; either explains the same capture again (a new turn), and
  PaperDeck remembers the choice for that window for two hours, on this Mac only. Neither is offered
  while the panel asks you to confirm a send or refuses one for privacy: confirm first, or change the
  paper's AI setting.

**What is sent:** the text you marked (for a box, the text macOS's on-device text recognition read
from it on your Mac), the image only for a figure, a formula, a table, a chart or when you turn on
*Send as image*, and — for a paper in your library — its title, authors, section and the text around the
passage. The model gets no tools and all of it is marked as untrusted data. **Quick** (Haiku /
GPT-5.6-Luna) is the default; **Thorough** (Sonnet / GPT-5.6-Terra) uses more of your plan.

**Limits and privacy:** after 50 explanations and questions a day (Explain & Ask together) PaperDeck
asks before continuing; 150 is the limit. A paper marked *Never use AI for this paper* is never sent;
one marked unpublished or confidential and one from a person's email without a DOI or arXiv id ask
first (**Send Anyway** is a separate click). So does anything that shows a **mail or chat window**:
a mail or chat app, webmail or web chat in a browser (Gmail, Outlook, Slack, Teams, WhatsApp and
the like, recognised from the window's title on your Mac), a notification banner, a box that covers
any part of such a window, text copied in such an app, a Services request from one, and PaperDeck's
own **Mail** inbox. A box or a
click over **PaperDeck's own reader or library** uses the settings of the papers shown there: the
reader's paper is the one explained, a *Never use AI* paper on screen stops it, a confidential one
asks first. **Ask before every send** confirms each one. Pressing the same button twice quickly
starts one turn. With **Keep Claude ready**, Claude may start while the overlay is open so the first
answer comes sooner; the idle process uses no quota, is never closed while it answers, and closes
after 3 minutes idle (an imported or older setting can't make that longer).

**History:** completed explanations are kept for 90 days (Settings ▸ Explain ▸ *Keep explanations
for*); pinned and saved ones stay. The inspector's **Explanations** section lists a paper's;
**Explanation History** lists all of them, and *Open at p. N* opens the reader at that place.

**In the PaperDeck Reader:** select text and click **Explain**, **Terms** or **Translate** in the
selection toolbar, or ⌘-drag a box and explain it: the exact text and page are used (a box is drawn
from the PDF itself, sharper than a screenshot), no permission is needed, and History reopens the
reader at that spot.

<a id="screen-recording"></a>
### Screen Recording (only for the box and the lens)

macOS calls it **Screen & System Audio Recording**. Only Explain's box and lens need it; copying,
Services, screenshots and dropped images never do.

1. Press ⌃⌥E. While it's off, the overlay shows *Screen capture is off* with the ways that need
   nothing, **Open System Settings** and **Enable Screen Capture…**.
2. **Enable Screen Capture…** first explains what is captured (a still of the screen while the
   overlay is open, of which only the part you mark is used — see below), what is sent and what is
   kept; **Continue** lets macOS ask, once.
3. If you clicked *Don't Allow* earlier, macOS doesn't ask again: open **System Settings ▸ Privacy &
   Security ▸ Screen & System Audio Recording** (the card's button, or Settings ▸ Explain & Ask ▸
   Explain ▸ *Screen Recording* ▸ **Open System Settings**) and turn PaperDeck on.
4. macOS asks you to quit and reopen PaperDeck. After that the box and the lens work, and Settings ▸
   Explain shows *Screen Recording: On*.

When the overlay opens, PaperDeck takes one still of each display (its own panels left out) and you
draw on that still, so what is explained is exactly what you saw; moving the pointer or the lens
captures nothing more, and the still is dropped when the overlay closes. macOS may show its
screen-recording indicator for a moment, and may ask again from time to time whether PaperDeck may
keep recording — *Allow* keeps it on.

<a id="ask"></a>
## Ask and the reader

### Asking about a paper (Ask)

The inspector has two tabs, **Overview** and **Ask**. Ask answers questions about the paper you're
looking at, using **your own Claude or ChatGPT subscription** — the same login as AI reading, but a
separate switch.

- **Turn it on** in **Settings ▸ Explain & Ask** (or with *Use Claude* / *Use ChatGPT* on the Ask tab
  itself). It is off until you turn it on, it's independent of AI reading (you can use either one
  alone), and turning it on sends nothing. The same switch turns on [Explain](#explain).
- **Each question is one request**, sent only when you press **Ask** (⌘↩); **Stop** (Esc) keeps
  the partial answer. Under the question box, an estimate shows the size, how many pages go, the
  model, the expected time and today's count ("≈ 2.0k tokens · all 5 pages · haiku · ~5–15 s · today
  4/50"). After 50 questions a day PaperDeck asks before continuing; 150 a day is the limit.
- **Quick or Thorough:** Quick (Haiku / GPT-5.6-Luna) is the default and light on your quota;
  **Thorough** (Sonnet / GPT-5.6-Terra) gives more detail and uses more. **Auto / EN / 中** picks the
  answer's language (Auto follows your question); *Answer in 中文 / English* in an answer's menu asks
  that answer's question again in the other language (the thread's own setting stays). A question
  is sent with at most 1,000 characters.
- **What is sent:** the paper's metadata and card, the paper's text with page markers (a long paper:
  the first page plus the pages that best match your question, up to Settings ▸ Explain & Ask ▸
  *Paper text per question*, 80k characters by default), the conversation so far, and your question.
  Text is marked as untrusted data and the model gets no tools. Follow-ups resend the context.
- **Citations:** answers cite pages as chips — "p. 3 (1203)" when the printed page number differs.
  Click one to open the [reader](#reader) at that page with the supporting sentence highlighted. A
  dimmed chip points at a page the PDF doesn't have, a page that wasn't sent with the question (so it
  can't be checked), or a page with no paper label in a question about several papers; a dashed one
  means PaperDeck couldn't find the sentence on that page — check it yourself.
- **Answers:** Copy, **Save to Notes** (appends the answer to the paper's notes with the question,
  date and model; saving twice adds it once), Ask Thoroughly, Delete. Questions and answers are kept
  in threads per paper (the thread menu; New Thread).
- **Private papers:** a paper marked **Never use AI for this paper** (Overview) is never sent. A paper
  marked *Unpublished / confidential*, one that came from a confidential or possibly-unpublished email,
  or one from a person's email without a DOI / arXiv id asks first; **Send Anyway** is a separate click.
- **Where answers are kept:** in PaperDeck's database, and — for a single paper that isn't private —
  also in `qa.json` in the paper's folder, so **Rebuild index from folders** brings them back. Marking
  the paper private removes its `qa.json`.
- **Notices** explain anything that stops a question: Ask is off, the CLI isn't signed in (run
  `claude` then `/login`, or `codex login`), a usage limit (with the reset time), today's limits, or a
  failed or timed-out answer (**Try Again** is a new click).

### Asking across several papers

Select two or more papers and click **Ask** in the selection bar (also in the context menu and the
multi-paper inspector). The Ask window labels them **P1…Pn** (at most 10 — Settings ▸ Explain & Ask ▸
*Papers per question*); remove any you don't want. **Context:** *Cards* (cheapest), *Excerpts* (the
pages that match the question) or *Full text* (up to 3 papers). Citations read "P2 · p. 5"; Save to
Notes can save to one paper or all of them.

<a id="reader"></a>
### The reader

PaperDeck has a simple built-in PDF reader. **Preview stays the default** for opening PDFs; the
reader opens when you:

- click a citation in an answer, or a checklist "p. N" chip (it opens at that page);
- choose **Open in PaperDeck Reader** in a paper's context menu;
- pick **Settings ▸ General ▸ Open PDFs with ▸ PaperDeck Reader** to make it your opener.

It has thumbnails, a page field (it takes the printed page number too: type 1203), zoom (⌘= / ⌘- /
⌘0 actual size / ⌘9 fit width), **Find** (⌘F; Return or ⌘G next, ⇧⌘G previous) and **Open in
Preview**. Select text for **Copy**, **Copy as Quote** (with title and page) or **Ask**; ⌘-drag (or
**Select Region**) draws a box to copy as a sharp image or as text. Each paper reopens at the page you
left. Highlights are temporary — the reader never changes the PDF file.

<a id="profile-field-institution"></a>
## Your field and institution

**Settings ▸ Profile** (also the "About you" setup page):

- **Research field and career stage** — 11 fields (life sciences & computational biology,
  neuroscience, medicine, computer science & ML, engineering, physics & astronomy, chemistry &
  materials, mathematics & statistics, social sciences, humanities, and a general fallback) × 4 stages
  (Master's, PhD, postdoc, faculty). They set a new library's starter categories, the reading card's
  persona, the example hints and the suggested alert senders. Changing the field never touches your
  categories; **Add Missing Categories…** adds the field's suggestions without renaming or removing
  anything.
- **How the AI should picture you** — the one line (up to 200 characters) sent to your AI with each
  paper. **Show the instructions sent with each paper** displays the full text; **Reset to Default**
  goes back to the field's wording.
- **Research interests** — also used to pick relevant papers out of email alerts.
- **Institution AI policy** — *No specific policy*, a built-in institution preset, or *Other…*
  (name, short name, approved AI tools, a policy link, and whether people's emails *ask each time* or
  are *never sent to AI*). The policy changes **wording only**: the safety defaults below are the same
  for everyone. Notes on specific institutions are in [docs/institutions/](institutions/).

## The library

<a id="library-location"></a>
### Where your library lives

Your library is a normal folder — by default `Documents/PaperDeck` — with one folder per paper:

```
PaperDeck/Papers/2025_Author_Title-of-the-paper/
    Title-of-the-paper.pdf   card.json   notes.md   qa.json (Ask threads, when there are any)
```

PaperDeck's index (a SQLite database), caches and daily backups live separately in PaperDeck's own
folders on this Mac (`~/Library/Application Support/PaperDeck`, `~/Library/Caches/PaperDeck`). The
index can always be rebuilt from the folders (Settings ▸ Library & Storage ▸ Rebuild index from
folders).

- **Cloud folders** (iCloud Drive, Dropbox, Google Drive, OneDrive) work on **one Mac at a time**.
  Keep the folder downloaded (Finder ▸ Keep Downloaded / Always Keep on This Device).
- **External or network disks** work while the disk is connected. If it isn't at launch, PaperDeck
  asks you to connect it, choose another folder or quit — it never switches to another folder on its own.
- **Change…** (Settings ▸ Library & Storage) looks inside the folder first: your own library (moved),
  another PaperDeck library (switch to it — your current one stays where it is, and PaperDeck backs
  up its index first), or an empty folder (start a new library). The change applies when PaperDeck
  restarts (**Restart Now**).
- **To move your library:** quit PaperDeck, move the folder in Finder, open PaperDeck and choose the
  new place with Change… — it's recognized as the same library.
- **Re-index full text** (Settings ▸ Library & Storage) re-reads the PDFs on this Mac so search finds
  words inside papers — useful after moving Macs. It uses no AI quota.

<a id="library-two-macs"></a>
### One library on two Macs

A library in a cloud folder can be opened from two Macs — one at a time. Each Mac keeps its own
index, mail cards, AI run history and usage pauses. Quit PaperDeck on one Mac before using the
library on the other and let the folder finish syncing; after switching, use **Rebuild index from
folders** on that Mac. Using both Macs at the same time isn't supported.

<a id="duplicates"></a>
### Duplicates

When a new PDF looks like a paper you already have — the same file, DOI or arXiv ID, a preprint and
its journal version, or the same title and text — PaperDeck asks; nothing is replaced, merged or
removed without your click, and each decision can be undone for 30 seconds.

- **The same file or identifier:** the new file waits and the decision sheet offers *Keep the new
  one*, *Re-read the earlier one*, *Keep both* or *Skip*.
- **Probably the same paper:** the paper is added but waits — a **Duplicate?** ribbon on its card,
  no deadline and no AI reading until you decide.
- **Possibly the same:** added as usual, with a note and *Review…* in the inspector.
- Open questions are under **Duplicates** in the sidebar; **Library ▸ Check for Duplicates…** checks
  the whole library or the selected papers.
- **Several questions at once** (an import, a library check, or **Review All** under Duplicates)
  open one review sheet: every row starts on the suggested choice, **Set all to** changes the rows
  that offer that choice, any row can be changed or opened in full (**Details…**), and one Undo
  reverts them all for 30 seconds.
- **Ask AI** (optional, off by default): turn on *Let me ask AI about a possible duplicate* in
  Settings ▸ Library & Storage ▸ Duplicates — it also needs [Explain & Ask](#ask) on. Then **Ask AI**
  in the decision sheet sends the new paper and up to three possible matches (title, up to 6
  authors, year, venue, DOI / arXiv id, pages, the abstract and a short first-page excerpt — never
  notes or checklists) to a quick model,
  only when you click, at most 10 times a day, and never for papers marked private or possibly
  unpublished. The AI only moves a match between "probably" and "possibly"; it never replaces,
  merges or removes anything.
- **Email rows:** merging a single paper from an email first shows the library paper it looks like,
  with *Link to it*, *Link and re-read it*, *Use this version* (the email's PDF replaces the library's
  file, for a DOI or arXiv match) or *Add as a separate paper* (the default for a weak match).
- **Settings ▸ Library & Storage ▸ Duplicates:** turn the check off (a file with the same DOI or
  arXiv ID still asks Replace / Ignore, as before), the sensitivity of title-and-text matches, and
  whether removed papers are remembered (title, identifiers and when you read it — no text, no
  notes). The check runs on this Mac and sends nothing to an AI.

<a id="multi-select"></a>
### Selecting several papers

⌘-click adds or removes a paper, ⇧-click selects a range; with the list focused, the arrow keys move
(⇧ extends), ⌘A selects all and Esc clears. The toolbar's **Select ▾** picks all papers, the most
recently added, the oldest unread (by deadline) or the recently opened. The selection bar and the
context menu then change status, priority, category or tags, pin or postpone deadlines, move papers
to Recently Deleted (or restore them), check them for duplicates, or **export** BibTeX, RIS, CSV or
Markdown — metadata only. Every batch change is one step to undo (30 seconds); papers you changed
since are left alone. Reading the selection with AI asks first and queues only while AI reading is on.

The menu bar's **Paper** menu has the context menu's shortcuts for the selected paper (or the whole
selection): ⌘O open the PDF, ⌥⌘O open in Preview, ⌘D mark as read / unread, ⌥⌘1 / ⌥⌘2 / ⌥⌘3
priority, ⇧⌘P postpone one day, ⌥⌘R read with AI, ⇧⌘R show in Finder, ⌘⌫ move to Recently Deleted.
They work while the library window is in front and you aren't typing in a field (there ⌘⌫ still
deletes to the start of the line).

## Mail

<a id="connect-mail"></a>
PaperDeck can collect **reading requests** from your email: an advisor's or colleague's "please
read this", journal-club papers, shared papers, and paper alerts (Google Scholar, bioRxiv, arXiv,
journal tables of contents). Each relevant email becomes a card in **Mail**: who sent it, what they
asked, any deadline, and every paper in it (attached PDF, downloadable, needs a PDF, already in your
library — or a [Word manuscript or shared file](#mail-documents)). Merge papers one by one or all at
once; the card records where each paper came from.

PaperDeck **reads only emails from senders you list**, keeps them on this Mac, and never sends,
moves, deletes or marks mail as read. Mail stays off until an account passes **Test & Save** and you
turn it on. You can always **drag an email in** without any account.

**Which route?**

| Your mail | Route |
|---|---|
| Work or school Microsoft 365 (Outlook) | [Power Automate → OneDrive folder](#mail-m365-power-automate) |
| Microsoft 365 that blocks Power Automate | [drag emails in, an Apple Mail rule, or forward alerts](#mail-m365-blocked) |
| Gmail (personal) | [Gmail with an app password](#mail-gmail) |
| Google Workspace (work or school Gmail) | [Gmail, or an Apps Script → Drive folder](#mail-google-workspace) |
| iCloud Mail | [iCloud with an app-specific password](#mail-icloud) |
| Outlook.com / Hotmail | [Apple Mail rule, forwarding, or drag](#mail-outlook-com) |
| Yahoo, Fastmail, a university IMAP server | [other IMAP](#mail-other-imap) |
| A folder that already receives .eml files | [folder sources](#mail-folder-sources) |
| No account | [just drag emails in](#mail-drag-only) |

<a id="mail-m365-power-automate"></a>
### Microsoft 365 with Power Automate (any work or school tenant)

Your own Power Automate flow saves new emails from your sender list into OneDrive as `.eml` files;
OneDrive syncs them to this Mac and PaperDeck watches the folder. No app registration or IT approval
is needed if your organization allows Power Automate.

1. Install OneDrive and sign in with your **work or school** account (not a personal one).
2. Create a folder **PaperDeck Mail** at the top of that OneDrive (the account form has Create Folder).
3. Add your senders first (Settings ▸ Mail ▸ Senders) — the flow's From field is generated from them.
4. Build the flow at <https://make.powerautomate.com>, or import the ready-made package
   (**Generate Import Package…** in the account form). The full walkthrough, including every field
   value, is [docs/guides/POWER_AUTOMATE.md](guides/POWER_AUTOMATE.md).
5. Settings ▸ Mail ▸ **Add Account…** ▸ Microsoft 365 via Power Automate — PaperDeck suggests the
   folder it found — then **Test & Save** and turn Mail on.
6. Send yourself a test email from a listed sender; a card appears within minutes.

<a id="mail-m365-blocked"></a>
### When Microsoft 365 blocks Power Automate

- **Drag emails** from Outlook onto PaperDeck — always works, no account.
- **Apple Mail rule** (Beta): if the mailbox is also in Apple Mail, a rule can save matching
  emails as `.eml` into a folder PaperDeck watches — see [folder sources](#mail-folder-sources).
- **Forward alerts** (journal and preprint alerts only — not people's emails) to a Gmail or iCloud
  address and connect that.
- Or ask IT whether Power Automate and the OneDrive connector can be allowed for you.

<a id="mail-outlook-com"></a>
### Outlook.com / Hotmail

Microsoft no longer lets other apps sign in to Outlook.com mail with an app password, so PaperDeck
can't connect to it directly. Use an Apple Mail rule into a folder (Beta), forward your alerts to
Gmail or iCloud, or drag emails in.

<a id="mail-gmail"></a>
### Gmail

1. Subscribe or forward your alerts to the Gmail address. Optionally make a Gmail filter that labels
   them `PaperDeck`.
2. Turn on **2-Step Verification** for the Google account (app passwords need it).
3. Create an app password at <https://myaccount.google.com/apppasswords>.
4. Settings ▸ Mail ▸ Add Account… ▸ **Gmail**: your address (the server `imap.gmail.com:993` is
   filled in), the mailbox (`INBOX` or the label `PaperDeck`), the app password, then **Test &
   Save**. PaperDeck signs in read-only before saving.

The password is stored only in this Mac's keychain — never in a settings file or a log. A rejected
password parks the account as "needs attention" instead of retrying (so Google doesn't lock it).

<a id="mail-google-workspace"></a>
### Google Workspace (Beta)

Try the Gmail steps first — many schools and companies allow app passwords. If your organization
turned them off, a small **Apps Script** in your own Google account can copy alert emails into a
Drive folder that Google Drive for desktop syncs to this Mac:

1. Install Google Drive for desktop; create **PaperDeck Mail** in My Drive.
2. In the Help Center topic, **Copy Apps Script** (generated from your sender list). At
   <https://script.google.com> create a project, paste it, run `savePaperDeckMail` once and allow
   access, then add a time-driven trigger (every hour).
3. Add the synced folder as a **Folder of .eml files** account.

Or forward your alerts to a personal address, or drag emails in.

<a id="mail-icloud"></a>
### iCloud Mail

Create an app-specific password at <https://account.apple.com> (Sign-In and Security ▸
App-Specific Passwords; it needs two-factor authentication). Then Add Account… ▸ **iCloud Mail**
(`imap.mail.me.com:993`) ▸ Test & Save.

<a id="mail-other-imap"></a>
### Yahoo, Fastmail and other IMAP

Yahoo: create an app password under Account Security. Fastmail: an app password with IMAP access.
Any other server: Add Account… ▸ **Other IMAP server** with its host and port (TLS, 993).

<a id="mail-folder-sources"></a>
### Mail from a folder (.eml)

PaperDeck can watch any folder that receives `.eml` files — new files only, not subfolders; files
still being written are read once they settle. Add it with Add Account… ▸ **Folder of .eml files**.

- **Apple Mail rule** (Beta): the folder form's *Save emails here with an Apple Mail rule* section
  has **Save Script…**, which saves a small AppleScript into
  `~/Library/Application Scripts/com.apple.mail/`. In Mail ▸ Settings ▸ Rules add a rule for your
  senders whose action is **Run AppleScript** with that script; each matching email is written to the
  folder as `<message id>.eml`.
- **Google Apps Script** (Beta): see [Google Workspace](#mail-google-workspace).
- **Dropbox, iCloud Drive or any synced folder** that another tool fills with `.eml` files.

Optional **Delete processed files** removes each `.eml` after it was collected.

<a id="mail-drag-only"></a>
### Just drag emails in

Drag an email from Outlook or Mail (or an `.eml` file) onto the edge strip, the menu-bar icon or the
Mail window. It becomes a card; a dragged email counts as your choice, so the sender doesn't need to
be on your list. Nothing goes to AI until you click **Analyze with AI** on that card.

<a id="mail-senders-and-ai"></a>
### Senders and AI

- **Senders** (Settings ▸ Mail ▸ Senders): `name@university.edu` (an address), `@biorxiv.org` (a
  domain), `@*.nature.com` (any subdomain). Only the address counts — never the display name.
- **Kinds:** advisor, colleague or paper alert. An advisor's requests get high priority when merged.
- **AI policy per sender:** *Ask each time*, *Always* or *Never*. People start at **Ask each time**:
  their emails stay on this Mac until you click Analyze with AI. Alerts start at *Always*. Your
  institution's policy sentence appears next to the choice.
- **Alert presets:** the suggestions for your field come first, unticked; *More presets* has others
  (check the sender address in one of your alerts before relying on them).
- **What counts as a reading request** (a section of Settings ▸ Mail): which kinds to keep,
  keywords to include or exclude, your research interests, instructions for the AI, a minimum
  confidence, how many papers per alert, and how dates like 3/10 are read (month first, day first, or
  your Mac's region).
- **Merging:** "Merge into Library" per paper or "Merge All"; papers already in your library are
  linked, never imported twice. A clear deadline in the email can become the paper's deadline (you
  confirm). Papers behind a paywall show as **needs PDF**: download it in your browser and drop it on
  that row.

<a id="mail-documents"></a>
### Manuscripts and shared files

Advisors and colleagues often send a draft as a Word file, or as a link to SharePoint, OneDrive, Box,
Google Drive or Dropbox, instead of a PDF. These show up as rows of the card too, so such an email
waits under **Pending** instead of *No Request*:

- **Document** (an attached Word `.docx` / `.doc`, `.rtf` or `.odt`, e.g. *Word manuscript attached
  · docx · 7.2 MB*): **Convert to PDF & Add** makes a PDF on this Mac — nothing is uploaded or sent
  to AI — and adds it like an attached PDF, with the email as its source. The original file is kept
  next to the PDF in the paper's folder. Figures may be moved to the end of the PDF, and some figures
  or complex layouts may not convert: **Open** shows the original in its app, and if the conversion
  fails the row says why — export a PDF there and drop it on the row.
- **Needs export** (attached PowerPoint, Keynote or Pages files): **Open** it, export a PDF from its
  File menu (Export To ▸ PDF in Keynote and Pages, Export… in PowerPoint), and drop the PDF on the row
  (**Export as PDF and drop it here**).
- **Shared link**: PaperDeck never downloads these — they need your sign-in. **Open Link** opens the
  link as it was in the email (your school's link scan still runs); download the file, export a PDF
  if it's a Word or PowerPoint file, and drop the PDF on the row (**Download it, then drop the PDF
  here**). Right-click ▸ **Copy Link** copies it.

Documents from a person, an advisor or a dragged-in email are treated as possibly unpublished: AI
reading of the converted paper — or of a PDF you drop on a document or shared-link row — is held
until you confirm it ("Possibly unpublished — confirm before AI reading"), even when its text shows
a DOI. Attachments over the size limit in Settings ▸ Mail aren't stored; their row says so and
waits for a PDF. **Add All** never converts — each document is converted by its own button.

Once after updating, PaperDeck looks again at emails from your senders that went to *No Request*
(and that you haven't touched) for documents and shared links, re-reading the original email where
it is still available (the `.eml` file, or the message on the IMAP server). It uses local rules
only — nothing is sent to AI.

## Moving and sharing

<a id="move-to-new-mac"></a>
### Moving to another Mac

1. **Old Mac:** Settings ▸ General ▸ **Export Settings…** (preferences, senders, reading criteria and
   mail accounts — never passwords; keep **Include mailbox addresses** ticked so accounts arrive with
   their addresses). Then quit PaperDeck and copy the library folder to the new Mac, or keep it in a
   cloud folder (one Mac at a time).
2. **New Mac:** put PaperDeck in Applications and open it; choose **Use an existing PaperDeck
   library…** and pick the copied folder.
3. **Import Settings…** shows every change before it applies. An import never turns AI reading or
   Mail on; IMAP accounts need their app passwords again (not one already set up here with the same
   server); a new person's "Always send to AI" arrives as "Ask each time". Senders and accounts are merged by id — this Mac's own entries stay. A privacy or quota
   setting that is looser in the file than on this Mac is **kept stricter** unless you tick it.
4. Sign in to Claude or ChatGPT, turn AI on; re-enter IMAP app passwords; allow notifications, add the
   widget, turn on Open at Login; **Re-index full text**.

Details, including what doesn't travel: [docs/guides/MOVE_TO_ANOTHER_MAC.md](guides/MOVE_TO_ANOTHER_MAC.md).
Another account, mailbox or institution: [docs/guides/DIFFERENT_ACCOUNT.md](guides/DIFFERENT_ACCOUNT.md).

<a id="install-for-labmate"></a>
### Giving PaperDeck to a labmate

On the Mac that builds PaperDeck run `./build_app.sh --package`; send `dist/PaperDeck-<version>-<build>.zip`
and `dist/INSTALL.md`. **Never send your signing certificate.** The recipient moves the app to
Applications before the first launch, uses Open Anyway once, and then the setup window takes over.
Each person signs in to their own AI account and mailbox; nothing of yours is in the package.

<a id="build-from-source"></a>
### Building from source

Command Line Tools, a self-signed code-signing certificate (Validity 3650 days), optional
`build.local.env`, then `./build_app.sh`. Use `--dev` only for development copies (it turns AI
reading off). See [docs/BUILDING.md](BUILDING.md).

## Privacy and safety

These are the same for every institution and can't be loosened by a preset or an imported file:

- **AI is off until you turn it on**, and it uses only your subscription login — never an API key.
  The model gets no tools; paper and email text are marked as untrusted data.
- **Mail is off until an account passes Test & Save.** Only listed senders are read.
- **People's emails ask first** ("Ask each time"). A settings import turns "Always" for new people
  into "Ask each time" unless you opt out.
- **An imported file never loosens privacy or quota silently.** Where this Mac is stricter — AI email
  sorting on "Local rules only", a lower daily limit or less text sent to AI, smaller attachments,
  notifications or automatic reading off, email text kept for less time, a lighter model, a sender's
  lower AI policy, a sender or account turned off (or a sender's automatic merge / attachment storing
  off, an account's shorter look-back), the institution's "Never send to AI" for people, AI email
  sorting on another AI service, a folder account's "Delete processed files", a person's or advisor's
  sender turned into an alert, an IMAP account pointed at another mail server (its saved app password
  is never sent there), a new sender more specific than a stricter rule here (it would take over that
  mail) — this Mac's value stays and is listed under **Kept stricter**; that item's own checkbox
  (off by default) takes the file's value. Values out of range (a daily limit of 1e300) aren't
  imported, and the instructions for AI email sorting, like the reader description, only after you
  confirm them.
- **Confidential mail is never sent to AI or merged automatically**, whatever a sender's policy says:
  review invitations and requests, manuscript-system emails, decisions and proofs of your own
  submissions, and emails marked confidential. Titles of possibly unpublished manuscripts aren't
  searched online until you allow it. When you merge such an email yourself, **Read with AI** starts
  unticked and a PDF dropped on its row isn't queued for AI; if you tick it, the reading waits as
  "Possibly unpublished — confirm before AI reading" until the paper is identified (DOI / arXiv id)
  or you confirm.
- **A PDF from a person that can't be identified** (no DOI / arXiv id) waits before AI reads it.
- **Explain, Ask and the AI duplicate check are off until you turn them on** (Settings ▸ Explain &
  Ask, which a settings file never turns on), and every explanation, question or check is sent only
  by your click. A paper marked *Never use AI for this paper* is never sent; one that may be
  unpublished or confidential, and text from a mail or chat window, ask first. Private papers keep no
  `qa.json` beside them.
- **Explain sees the screen only when you ask it to.** Copying, Services and dropped images need no
  permission. With Screen Recording on, the overlay takes one still when you open it and sends only
  the box you draw (or the paragraph you click); window titles stay on your Mac, and nothing is kept
  unless you pin or save an explanation.
- **AI email sorting** is capped (30 a day by default) and sends only a cleaned copy of one email:
  links become markers, other addresses and phone numbers are removed, the signature is cut.
  Settings ▸ Mail ▸ AI triage ▸ Show Example… shows a request byte for byte.
- **Diagnostics are redacted:** your home folder becomes `~`, email addresses are masked, and paper
  titles, subjects and passwords are never included.
- **Settings files never contain passwords.** IMAP app passwords live in this Mac's keychain.

<a id="diagnostics"></a>
**Diagnostics** (Help ▸ Diagnostics…) lists version, bundle id, app location, signing, library,
paper counts, both AI services (checked without quota), notifications, Open at Login, the widget,
mail accounts and the configuration. **Copy Diagnostics…** previews the redacted text first.

## Troubleshooting

The Help Center's **Troubleshooting** checks your Mac live and marks the entries that apply now. The
same entries, with every step, are in [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md):

- <a id="fix-documents-access"></a>[PaperDeck can't use the library folder](TROUBLESHOOTING.md#fix-documents-access) — allow Documents access in System Settings ▸ Privacy & Security ▸ Files and Folders.
- <a id="fix-library-missing"></a>[The library folder is missing](TROUBLESHOOTING.md#fix-library-missing) — reconnect the disk or choose the moved folder; don't start an empty library.
- <a id="fix-library-mismatch"></a>[This folder holds a different library](TROUBLESHOOTING.md#fix-library-mismatch) — open it (the index is backed up and rebuilt), go back, or choose another folder.
- <a id="fix-cloud-evicted"></a>[Papers in a cloud folder won't open](TROUBLESHOOTING.md#fix-cloud-evicted) — keep the library downloaded.
- <a id="fix-cli-not-found"></a>[Claude Code or the Codex CLI isn't found](TROUBLESHOOTING.md#fix-cli-not-found) — install it or set a custom path.
- <a id="fix-cli-not-signed-in"></a>[AI reading says "not signed in"](TROUBLESHOOTING.md#fix-cli-not-signed-in) — sign in in Terminal, then I've Signed In.
- <a id="fix-cli-api-key"></a>["Signed in with an API key"](TROUBLESHOOTING.md#fix-cli-api-key) — sign in with your subscription instead.
- <a id="fix-usage-limit"></a>[AI reading is paused by a usage limit](TROUBLESHOOTING.md#fix-usage-limit) — it resumes at the reset time.
- <a id="fix-notifications"></a>[The daily reminder doesn't appear](TROUBLESHOOTING.md#fix-notifications) — allow notifications; check Focus.
- <a id="fix-widget-missing"></a>[The widget isn't in the widget gallery](TROUBLESHOOTING.md#fix-widget-missing) — run from Applications once; Repair registration.
- <a id="fix-login-item"></a>[PaperDeck doesn't open at login](TROUBLESHOOTING.md#fix-login-item) — approve it in Login Items.
- <a id="fix-app-blocked"></a>[macOS blocks PaperDeck or runs a temporary copy](TROUBLESHOOTING.md#fix-app-blocked) — move it to Applications; Open Anyway.
- <a id="fix-mail-auth-failed"></a>[A mail account can't sign in](TROUBLESHOOTING.md#fix-mail-auth-failed) — make a new app password.
- <a id="fix-mail-not-email-files"></a>["Files in this folder aren't complete emails"](TROUBLESHOOTING.md#fix-mail-not-email-files) — fix the flow's File Content; then **Ignore** the old files or **Move to Trash…** them from the notice (only files inside the watched folder; Finder's Put Back restores them).
- <a id="fix-mail-onedrive-missing"></a>[PaperDeck can't find the OneDrive mail folder](TROUBLESHOOTING.md#fix-mail-onedrive-missing) — sign in to OneDrive with the work or school account.
- <a id="fix-search-after-move"></a>[Search finds titles but not the text inside papers](TROUBLESHOOTING.md#fix-search-after-move) — Re-index full text.
- <a id="fix-two-macs-diverged"></a>[Two Macs show different libraries](TROUBLESHOOTING.md#fix-two-macs-diverged) — rebuild the index; one Mac at a time.

## Appendix

### Settings you might look for

| Setting | Where | Key |
|---|---|---|
| Interface language | Settings ▸ General | `language` |
| Library location | Settings ▸ Library & Storage | `library.path` |
| AI service, model, effort | Settings ▸ AI Reading | `agent.provider`, `agent.model`, `agent.codexModel`, `agent.effort` |
| AI reading on/off | Settings ▸ AI Reading | `agent.mode` (never imported) |
| Daily budget, reminder time | Settings ▸ Plan & Reminders | `plan.*`, `reminder.hour`, `reminder.minute` |
| Field, stage, reader line | Settings ▸ Profile | `profile.field`, `profile.stage`, `profile.readerDescription` |
| Institution policy | Settings ▸ Profile | `org.preset`, `org.custom` |
| How dates like 3/10 are read | Settings ▸ Mail ▸ What counts as a reading request | `mail.dateOrder` |
| Mail on/off | Settings ▸ Mail | `mail.enabled` (never imported) |
| Duplicate check, sensitivity, removed papers | Settings ▸ Library & Storage ▸ Duplicates | `dedupe.enabled`, `dedupe.sensitivity`, `dedupe.history` |
| Ask AI about duplicates | Settings ▸ Library & Storage ▸ Duplicates | kept in the library (never exported) |
| Explain & Ask on/off, service | Settings ▸ Explain & Ask | `assist.mode` (never imported) |
| Ask: depth, language, text per question, papers per question | Settings ▸ Explain & Ask ▸ Ask | `assist.qa.depth`, `assist.qa.lang`, `assist.qa.textBudget`, `assist.qa.multiMax` |
| Explain: shortcut, what it opens, language, model, ask before every send, history | Settings ▸ Explain & Ask ▸ Explain | `assist.explain.hotkey`, `assist.explain.defaultMode`, `assist.explain.lang`, `assist.explain.depth`, `assist.explain.askBeforeSend`, `assist.explain.historyDays` |
| Keep Claude ready, the daily limit before asking (Explain & Ask together) | Settings ▸ Explain & Ask ▸ Explain | `assist.keepWarm`, `assist.dailySoftCap` |
| Open PDFs with Preview / the default app / PaperDeck Reader | Settings ▸ General | `pdf.opener` |

### Command line

The app binary has headless tools; none of them spends AI quota unless noted, and none writes
your settings:

```bash
PD=/Applications/PaperDeck.app/Contents/MacOS/PaperDeck
$PD --config                      # institution, field, stage, date order, bundle id, keychain service, channel
$PD --doctor --mail-only          # mail accounts, senders and statuses (never a password)
$PD --doctor                      # also the Claude / Codex CLIs (no quota), database, signing, widget
                                  # (the database is only read: an older one says "open the app to upgrade")
$PD --mail-dry-run message.eml --default-settings --now 2026-09-29T10:00:00
                                  # parse + local sorting + the exact text that would go to AI, with the
                                  # built-in mail settings (no AI, no network, nothing stored)
$PD --migrate-dry-run --plist settings.plist --db-exists yes   # what a first launch would add to a defaults export
$PD --export-settings out.json    # a settings file, like Export Settings…
$PD --import-settings in.json --dry-run                        # what an import would change
$PD --dedupe-report --root DIR    # the pairs a duplicate check would ask about (a scratch copy; no AI, DIR untouched)
$PD --selftest qa                 # Ask's strings (en / zh), notices, the estimate line, citation links (pure)
$PD --ask-render OUT --root SCRATCH                            # PNGs of every Ask state (mock AI, no CLI probed)
$PD --explain-render OUT --root SCRATCH                        # PNGs of every Explain state (mock AI, no CLI probed, no screen captured)
$PD --render OUT --root SCRATCH --reader-only                  # PNGs of the reader (fixture PDF, no CLI probed)
$PD --render OUT --root SCRATCH --library-only --widths "720, 1280"   # PNGs of the library at those window widths (no CLI probed)
$PD --help
```

A mistyped option (`--doctr`) stops with "unknown option" instead of opening the app. `--gui-root DIR`
opens the app on an isolated library in DIR for testing; it isolates the library only, not
settings, and refuses to start while PaperDeck is running.

### Institution notes

What a built-in institution preset changes, and notes for specific institutions:
[docs/institutions/](institutions/).
