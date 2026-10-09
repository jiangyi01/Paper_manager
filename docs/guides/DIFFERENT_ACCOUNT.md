# Using a different account

PaperDeck stores no AI login and no mail password in its settings. Switching accounts happens where
the account lives.

## Another Claude or ChatGPT account on the same Mac

PaperDeck uses whichever account the official command-line tool is signed in to.

- **Claude:** in Terminal run `claude`, type `/logout`, then `/login` and sign in with the other
  Claude account (a subscription login on claude.ai).
- **ChatGPT:** `codex logout`, then `codex login` and choose *Sign in with ChatGPT*.

Then click **I've Signed In** in Settings ▸ AI Reading; the status line shows the new plan.

- **API keys are refused by design.** If a tool is signed in with an API key (or a console / API
  account), PaperDeck won't read with it, so nothing is ever billed per call.
- **Usage-limit pauses** belong to the account that hit the limit and end at its reset time. Claude
  and ChatGPT limits are separate: you can switch services meanwhile (Settings ▸ AI Reading ▸ reading
  service).
- In the app: Help ▸ PaperDeck Help ▸ *Switch to another AI account*.

## Another mailbox

Add or remove accounts in Settings ▸ Mail ▸ Accounts. Several accounts can be active at once; each
can be paused. Removing an IMAP account also deletes its app password from this Mac's keychain.
App passwords live in each Mac's keychain and are never exported.

## Another Microsoft 365 organization

A Power Automate flow belongs to one organization's tenant. For a new organization:

1. Sign in to OneDrive with the new work or school account (PaperDeck detects the new OneDrive root
   automatically).
2. Create the flow again in that tenant (Generate Import Package… makes it quick) — see
   [POWER_AUTOMATE.md](POWER_AUTOMATE.md).
3. Add the new folder as an account; remove the old one when you no longer need it.

## Another institution

Settings ▸ Profile ▸ Institution AI policy: a built-in preset, *No specific policy*, or *Other…*. It
changes the wording of mail warnings and policy notes only; the safety defaults are the same for
everyone. See [docs/institutions/](../institutions/).

## Another person on the same Mac

Each macOS user account has its own PaperDeck settings, keychain, permissions and library. Give each
person their own macOS account rather than sharing one: PaperDeck runs as one instance per user, and
its library, AI sign-in and mailboxes are personal.
