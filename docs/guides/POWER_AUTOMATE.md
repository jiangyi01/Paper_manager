# Microsoft 365 mail with Power Automate

For a **work or school Microsoft 365 mailbox at any organization**. In the app: Help ▸ PaperDeck Help
▸ *Microsoft 365 with Power Automate* (`paperdeck://help/mail-m365-power-automate`) checks each step
on your Mac as you go.

## What the flow does

A Microsoft 365 mailbox can't be opened by another app without an app registration approved by IT.
Instead, **your own Power Automate flow**, running in your own account:

1. notices each new email in your Inbox **from the senders on your PaperDeck list**,
2. exports the complete email (headers, body, attachments) as one `.eml` file,
3. saves it into a folder **PaperDeck Mail** on your own OneDrive.

OneDrive syncs that folder to your Mac and PaperDeck reads the new files. The flow only copies mail
from the addresses you put in its From field; the files stay in your own OneDrive and on your Mac;
PaperDeck never sends, moves or deletes mail. PaperDeck itself also reads only listed senders, even
if the folder holds more.

## Requirements

- Your organization allows **Power Automate** with the **Office 365 Outlook** and **OneDrive for
  Business** connectors. (If it doesn't, see [If it's blocked](#if-its-blocked).)
- **OneDrive for your work or school account**, installed and signed in on this Mac. A personal
  OneDrive won't do: the flow writes to the work or school OneDrive.

## Step 1 — check OneDrive

Install OneDrive and sign in with the work or school account. In Finder's sidebar under Locations it
shows as *OneDrive – <your organization>*. Its folder is in `~/Library/CloudStorage/`. PaperDeck only
looks at the folder **names** there, never at the files inside other folders.

## Step 2 — the PaperDeck Mail folder

Create a folder named **PaperDeck Mail** at the top level of that OneDrive. PaperDeck's account form
(Settings ▸ Mail ▸ Add Account… ▸ Microsoft 365 via Power Automate) suggests this folder and has a
**Create Folder** button. Add your senders in Settings ▸ Mail ▸ Senders first — the flow's From field
is generated from that list.

## Step 3a — import the ready-made flow (fastest)

1. In the account form click **Generate Import Package…** and save the `.zip` (or, in Terminal:
   `/Applications/PaperDeck.app/Contents/MacOS/PaperDeck --mail-flow-package ~/Desktop/PaperDeck-Mail-flow.zip --from-settings`).
2. Open <https://make.powerautomate.com> and sign in with your work or school account.
3. **My flows ▸ Import ▸ Import Package (Legacy)** and upload the `.zip`.
4. Under *Related resources*, click **Select during import** for Office 365 Outlook and for OneDrive
   for Business and pick your connections (**Create new** if there are none, then refresh). Save.
5. **Import**, then open *PaperDeck Mail* under My flows and make sure it's **turned on**.

## Step 3b — or build it by hand

1. <https://make.powerautomate.com> ▸ **Create ▸ Automated cloud flow**, name it *PaperDeck Mail*.
2. **Trigger:** Office 365 Outlook — **When a new email arrives (V3)**. Folder: **Inbox**. Under the
   advanced parameters, paste your sender addresses into **From**, separated by semicolons (the form
   generates the list; each value has a Copy button).
3. **New step:** Office 365 Outlook — **Export email (V2)**. Message Id: the trigger's *Message Id*
   (dynamic content).
4. **New step:** OneDrive for Business — **Create file** (click *See more* in the connector's list of
   actions to find it).
   - **Folder Path:** `/PaperDeck Mail`
   - **File Name:** click the box ▸ *fx* (Insert expression) ▸ paste
     `concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',guid(),'.eml')` ▸ Add. The name is a
     timestamp plus a random id — never the subject.
   - **File Content:** *fx* ▸ paste `body('Export_email_(V2)')` ▸ Add (or pick *Body* under
     *Export email (V2)* in the dynamic content).
   - **Don't pick the trigger's Body.** That is only the message's HTML, without sender or
     attachments; PaperDeck reports those files as "not complete emails".
5. **Save.**

The From field takes exact addresses only. If your sender list has domain rules such as
`@biorxiv.org`, either leave From empty (the flow then copies *all* Inbox mail into your OneDrive and
PaperDeck still reads only listed senders), or list exact addresses.

## Step 4 — add the folder as an account

Settings ▸ Mail ▸ **Add Account…** ▸ **Microsoft 365 via Power Automate**. PaperDeck suggests the
`PaperDeck Mail` folder it found in your OneDrive; check it and click **Test & Save**. The first time
PaperDeck reads the folder, macOS may ask whether it may access files managed by OneDrive: click
**Allow**.

## Step 5 — turn on Mail

**Turn On Mail & Close** in the form, or the switch at the top of Settings ▸ Mail.

## Step 6 — test

Send yourself an email from an address on your list. Within a few minutes a `.eml` file appears in
OneDrive ▸ PaperDeck Mail and a card appears in PaperDeck's Mail.

## Troubleshooting

- **"N files in this folder aren't complete emails".** File Content in *Create file* is the trigger's
  Body. Set it to the *Export email (V2)* body, delete those files, and the notice disappears at the
  next sync.
- **Nothing arrives.** Open the flow's run history at make.powerautomate.com: a failed run shows the
  step and the error. Check the From addresses, and that the flow is turned on.
- **A run fails with a data-loss-prevention (DLP) error.** Your organization's policy doesn't allow
  Outlook and OneDrive in one flow. Ask IT, or use one of the alternatives below.
- **Alerts are filed into folders by Outlook rules.** The trigger watches Inbox only: change its
  Folder, or make a second flow for the other folder.
- **PaperDeck suggests the wrong OneDrive.** A personal OneDrive is never used for this route. If
  you have several work or school OneDrives, choose the right folder in the account form.
- **Processed files pile up.** Turn on *Delete processed files* in the account to remove each `.eml`
  after it was collected.
- **Government or national-cloud tenants** use a different Power Automate site — ask your IT which one.

## If it's blocked

- **Drag emails** from Outlook onto PaperDeck — always works, no account.
- **Apple Mail rule** (Beta): add the mailbox to Apple Mail and let a rule save matching emails into
  a folder PaperDeck watches (Settings ▸ Mail ▸ Add Account… ▸ Folder of .eml files ▸ *Save emails
  here with an Apple Mail rule*).
- **Forward alerts** (journal and preprint alerts — not people's emails) to a Gmail or iCloud address
  and connect that account.

See the [User Guide](../USER_GUIDE.md#mail-m365-blocked) and, for notes about specific institutions,
[docs/institutions/](../institutions/).
