# Moving PaperDeck to another Mac

In the app: Help ▸ PaperDeck Help ▸ *Move to a new Mac* (`paperdeck://help/move-to-new-mac`) checks
each step on the new Mac.

Two things travel: **your library folder** (every paper's PDF, `card.json` and notes) and **a
settings file**. Everything else is rebuilt or set up again on the new Mac.

## On the old Mac

1. **Export your settings** while PaperDeck is still running: Settings ▸ General ▸ **Export
   Settings…**. Pick the sections (profile and institution, general, plan and reminder, AI
   preferences, library preferences, mail senders and criteria, mail accounts, the edge strip). The
   file never contains passwords or app passwords. **Include mailbox addresses** is on by default,
   so mail accounts arrive with their addresses; untick it to leave every mailbox address out (also
   out of account names and a Google Drive folder's account name) — then type each account's address
   again on the new Mac. The Crossref contact email is a separate box, off by default.
2. **Quit PaperDeck** (menu-bar icon ▸ Quit), so nothing changes while you copy.
3. **Copy the library folder** (default `~/Documents/PaperDeck`) to the new Mac — an external disk,
   AirDrop, or `ditto`, which keeps file dates and attributes:

   ```bash
   ditto ~/Documents/PaperDeck /Volumes/Backup/PaperDeck
   ```

   Or keep the library in a cloud folder (iCloud Drive, Dropbox, OneDrive, Google Drive) that both
   Macs sync — then use it on **one Mac at a time** (see [Two Macs](#two-macs)).

## On the new Mac

1. **Install PaperDeck into Applications** and open it from there (see
   [INSTALL_RECIPIENT.md](../INSTALL_RECIPIENT.md) for a copy someone sent you).
2. On the welcome page choose **I'm moving from another Mac…**, then on the library page **Use an
   existing PaperDeck library…** and pick the copied folder. PaperDeck indexes it from the cards —
   your checklists, categories, tags and deadlines come back; nothing is read by AI again. (On a Mac
   that already runs PaperDeck: Settings ▸ Library & Storage ▸ **Change…**.)
3. **Import the settings file:** Settings ▸ General ▸ **Import Settings…** (or the welcome page's
   option). Every change is listed before it's applied ("Reminder: 11:00 → 09:30"). The import rules:
   - **An import never turns AI reading or Mail on**: they stay as they are on this Mac (on a new
     Mac, off until you turn them on).
   - **Senders and mail accounts are merged, not replaced.** An entry is matched by its id, else a
     sender by its address or domain and an account by its mailbox (IMAP server and address) or
     watched folder. A matched entry takes the file's version but keeps **this Mac's id** — so an
     account keeps its saved app password and its emails stay linked; the file's other entries are
     added, and entries only this Mac has (say, an account added during setup) are kept. The preview
     lists them: "Sender list: add 2 · replace 1 · keep 3". The saved app password is only ever used
     for the server it was saved for (see below).
   - **Nothing gets looser about privacy or quota.** Where this Mac is stricter than the file —
     AI email sorting on "Local rules only", a lower AI triage daily limit, less email or paper text
     sent to AI, a smaller attachment limit, mail checked less often (or manually), notifications of
     new requests or automatic AI reading off, email text kept for less time, a lighter model or
     effort, online metadata lookups off, a sender's lower AI policy (Never → Ask → Always), a
     sender or mail account turned off, a sender's automatic merge or attachment storing off, an
     account's shorter look-back, the institution's "Never send to AI" for people — this Mac's
     value stays. The same goes for AI email sorting switched to **another AI service** than the one
     this Mac uses, for a folder account's **Delete processed files** turned on where this Mac keeps
     the files, for a person's or advisor's sender turned into an **alert** (alert mail is treated as
     public, so a person's unpublished PDF would no longer wait before AI reads it), for an IMAP
     account pointed at **another mail server** (host, port or address — ticked, it gets a new
     identity, so the app password saved for the old server is never sent to the new one and you
     type it again), and for a **new sender that is more specific than a stricter rule here** — say
     `news@lab.example.edu` set to Always while this Mac has `@lab.example.edu` on Never or turned
     off: it would take over that mail, so it arrives with the stricter rule's values. The preview
     lists each one under **Kept stricter** ("Kept stricter: AI triage daily limit — 30 per day
     (file: 200 per day)") with its own checkbox, off by default: tick it to take the file's value.
     Stricter values in the file are imported as usual. (`--import-settings … --dry-run` shows the
     same list; `--accept-looser` previews taking them all.)
   - **Values out of range are dropped.** A number this app can't use (a daily limit of 1e300, an
     hour of 25, an account's look-back of 100,000 days) or a value of the wrong type is not
     imported; the preview says which.
   - **IMAP accounts need their app password again** (it's in the old Mac's keychain), unless the
     same account or mailbox is already set up on this Mac with the same server — re-importing your
     own backup asks for none.
   - **Folder accounts** are matched to this Mac's cloud folders: the same OneDrive / Dropbox / Google
     Drive root if it exists, else the only root of the same provider, else "choose later". A Google
     Drive folder keeps its area — My Drive or a shared drive.
   - **A new person's "Always send to AI"** arrives as "Ask each time" unless you tick *Keep "Always"
     for people I set myself*.
   - **The reader description** and **the instructions for AI email sorting** (Mail ▸ Reading
     criteria) are shown and imported only if you confirm them — both go into what is sent to your
     AI. The rest of the reading criteria imports as usual.
   - **The institution** carries only its name, short name, approved tools, policy link and people
     default — never other text.
4. **Sign in to Claude or ChatGPT** on this Mac and turn AI reading on (Settings ▸ AI Reading).
5. **Re-enter IMAP app passwords:** Settings ▸ Mail ▸ edit each account ▸ Test & Save (type the
   address too if you exported without mailbox addresses).
6. **Check the cloud folder of a Power Automate account** is detected again (Settings ▸ Mail shows
   the account as ready after a sync).
7. **Grant permissions again:** notifications (the first reminder asks), the desktop widget (right-click
   the desktop ▸ Edit Widgets…), Open PaperDeck at login (Settings ▸ General).
8. **Re-index full text:** Settings ▸ Library & Storage ▸ Re-index full text, so search finds words
   inside papers. It runs on this Mac and uses no AI quota.

## What doesn't travel

| Stays on the old Mac | Why / what to do |
|---|---|
| Keychain items (IMAP app passwords) | per Mac by design — re-enter them |
| Mail cards, AI run history, usage pauses | they live in the index database, not in the library folder |
| AI sign-ins | sign in to Claude / Codex again on the new Mac |
| macOS permissions (Documents, notifications, login item, widget) | macOS asks again |
| The daily backups of the index | in `~/Library/Application Support/PaperDeck/Backups` on the old Mac |

## A different macOS user name

Paths in the settings file are stored relative to your home folder (and cloud roots by name), so
`~/Documents/PaperDeck` on the old Mac becomes `~/Documents/PaperDeck` on the new one even if the
user name differs. Paths that can't be matched are listed in the import preview.

## Two Macs

A library in a cloud folder can be opened from two Macs, **one at a time**: quit PaperDeck on one Mac
before using the library on the other, and let the folder finish syncing. Each Mac keeps its own
index; after switching, use Settings ▸ Library & Storage ▸ **Rebuild index from folders** on that
Mac. Live use on both Macs at once isn't supported.
