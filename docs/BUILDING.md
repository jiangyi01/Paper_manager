# Building PaperDeck

PaperDeck builds with Apple's **Command Line Tools only** — no Xcode. `./build_app.sh` compiles with
SwiftPM, assembles the `.app` bundle (app + widget extension), signs it and installs it.

## Prerequisites

- macOS 26 or later (Apple silicon).
- Command Line Tools: `xcode-select --install`. Swift 6.2 or later.
- A **self-signed code-signing certificate** (below). Optional, but without it macOS forgets
  PaperDeck's permissions (Documents access, notifications, the widget, keychain access) after every
  rebuild.

## Quick start

```bash
./build_app.sh --run        # build, sign, install into /Applications and open it
./test.sh -j 8              # the test suites (Swift Testing)
```

`./build_app.sh --print-config` shows what a build would use without building anything.

## The signing certificate

Create it once, in Keychain Access:

1. Keychain Access ▸ **Certificate Assistant ▸ Create a Certificate…**
2. Name: **PaperDeck Local Signing** (the default the script looks for; any name works with
   `PAPERDECK_SIGN_IDENTITY`). Identity Type: *Self Signed Root*. Certificate Type: **Code Signing**.
3. Tick **Let me override defaults**, continue, and set **Validity Period (days): 3650**.
4. Continue through the remaining pages (the defaults are fine) and **Create**.

Why: macOS ties permissions to the app's *designated requirement*. Signed with a certificate, the
requirement names the certificate, so it stays the same across rebuilds. An ad-hoc signature changes
with every build, so permissions reset each time. The script checks that the requirement is
certificate-based and warns when the certificate expires within 60 days. When you replace an expiring
certificate, give the new one the same name; macOS asks for Documents and notification access once
more.

Ad-hoc builds: `--allow-adhoc` falls back to ad-hoc signing when the certificate is missing;
`--sign -` always signs ad-hoc (no keychain access at all — useful for checks).

## Configuration

Precedence, lowest to highest: the script's defaults < **`build.local.env`** < **`PAPERDECK_*`
environment variables** < **flags**. `build.local.env` sits next to `build_app.sh`, is git-ignored,
and holds `KEY=VALUE` lines (`#` comments, optional quotes, a leading `~/` means your home). It is read
as data and never `source`d; an unknown key stops the build. Start from `build.local.env.example`.

| Setting | Variable | Flag | Default |
|---|---|---|---|
| Bundle id (reverse DNS) | `PAPERDECK_BUNDLE_ID` | `--bundle-id ID` | the original build's id (see `--print-config`) |
| Widget id | `PAPERDECK_WIDGET_ID` | — | `<bundle id>.widget` (must start with the bundle id + `.`) |
| Signing identity | `PAPERDECK_SIGN_IDENTITY` | `--sign NAME\|SHA1\|-` | PaperDeck Local Signing |
| Install folder | `PAPERDECK_INSTALL_DIR` | `--install-dir DIR` | `/Applications` |
| Keychain service (IMAP app passwords) | `PAPERDECK_KEYCHAIN_SERVICE` | — | `<bundle id>.mail` |
| Channel | `PAPERDECK_CHANNEL` | `--package` sets `distribution` | `local` |
| Parallel jobs | `PAPERDECK_JOBS` | `--jobs N` | SwiftPM's default |
| Testing.framework folder (`./test.sh`) | `PAPERDECK_DEV_DIR` | — | the Command Line Tools location, else derived from `xcode-select -p` |

Other flags: `--run` (open after installing), `--test` (run `./test.sh` first), `--no-widget`,
`--no-install`, `--package`, `--dev` (see below), `--help`.

**Changing the bundle id starts a fresh settings domain, keychain service, permissions and widget —
settings don't carry over** from a build with another id. **It does not make a separate copy.** Every
bundle id shares one library and database (`~/Library/Application Support/PaperDeck`, with its
backups, text cache and mail files), `~/Library/Caches/PaperDeck`, the widget data, the
`paperdeck:` URL scheme and the single-instance lock:

- two copies can't run at the same time — the second one hands the first `paperdeck://today` and quits;
- a copy with a fresh settings domain still opens the shared library, and a newer build upgrades the
  shared database. After an additive upgrade (new tables or columns, such as the stored mail
  confidentiality verdict) an older build still opens and writes it, and the newer build fills in
  what the older one left out at its next launch; after a change to the core schema an older build
  refuses to open it until it is updated too;
- widgets and `paperdeck:` links may reach either copy.

Keep the default id. To try a build next to your daily library, quit PaperDeck and run that build's
binary with `--gui-root DIR` (for example `.build/debug/PaperDeck --gui-root ~/pd-test`): the
library is an isolated one in DIR. `--gui-root` isolates the library only, not settings — run from
an installed app it reads and writes that app's settings domain — and every copy shares the
single-instance lock, so it refuses to start (exit 1, with a message) while PaperDeck is running.

### What the script stamps

`Resources/Info.plist` and `Resources/PaperDeckWidget-Info.plist` keep their literal values. The
staged copies get `CFBundleIdentifier` and the URL handler's name (the same values with the
defaults), plus `PDHostBundleIdentifier` and `PDWidgetBundleIdentifier` (both plists), `PDKeychainService`, `PDSigningIdentity`
(the certificate name or `adhoc`) and `PDBuildChannel` (the app). At run time `BuildIdentity` reads
them; with nothing stamped it falls back to the same defaults, so the defaults domain, keychain
service, log subsystem and widget id never change for an existing install.

`local` builds show build instructions (signing, the widget) in Settings; `distribution` builds, made
for someone else, don't.

## Installing

- The default install is `/Applications/PaperDeck.app`, updated **in place** (`rsync`), so the widget
  registration and permissions stay. The running copy **of that install** is asked to quit first
  (other PaperDeck processes, such as a development binary, are left alone).
- `--install-dir ~/Applications` installs for your user only.
- `--no-install` builds, stamps, signs and verifies in `.build/stage/PaperDeck.bundle` only: nothing
  is copied, stopped, registered or written to any settings. Use it to check a build.
- The build number is one more than both the last build here (`.build_number`) and the installed
  copy's `CFBundleVersion`. A `--no-install` check doesn't use up a number.
- `--dev` (development copies only) also writes `agent.mode = off`, `assist.mode = off` and
  `dedupe.ai.auto = false` for the bundle id, so GUI checks never spend AI quota. **Don't use it for the copy you use every day.** It can't be combined with
  `--no-install`.

## Giving PaperDeck to someone else

```bash
./build_app.sh --package
```

builds the `distribution` channel, never installs it here, and writes to `dist/`:

- `PaperDeck-<version>-<build>.zip` (made with `ditto -c -k --sequesterRsrc --keepParent`, so the
  signature survives),
- `PaperDeck-<version>-<build>.zip.sha256`,
- `INSTALL.md` (a copy of [INSTALL_RECIPIENT.md](INSTALL_RECIPIENT.md)).

Send the zip and `INSTALL.md`. **Never send your signing certificate** (or its private key). The
recipient's copy is signed with your certificate, which their Mac doesn't trust, so macOS asks them to
use Open Anyway once. Notarization (an Apple Developer ID) would remove that step; it's optional and
not covered here. Builds are for Apple silicon.

## Tests and checks

```bash
./test.sh -j 8                              # all suites; ./test.sh --filter <Suite> for one
tools/check_build_config.sh                 # build_app.sh's configuration layering (seconds; builds nothing)
tools/check_build_config.sh --staging --sign - --jobs 8
                                            # + one --no-install build: staged plists, signature, nothing installed
tools/verify_portability.sh --jobs 8        # every portability gate (release build, tests, selftests, greps)
tools/make_fixtures.sh PAPER.pdf …          # read-only PDF fixtures for --selftest import|all
tools/check_callback_apis.sh                # callback-style APIs in the MainActor app target (build_app.sh warns;
                                            # the intended nonisolated wrapper marks its line // pd-callback-ok)
```

The app binary also has headless self-tests (`PaperDeck --help` lists them). None of them spends AI
quota unless its name says so (`--agent-smoke`, `--selftest … --agent claude|codex`).

## Developer issues

- **"Signing identity … not found".** Create the certificate (above), or check its name with
  `security find-identity -p codesigning`. `--allow-adhoc` builds anyway.
- **Permissions reset after every build.** The build was ad-hoc signed, or the certificate changed.
  Check with `codesign -d -r- /Applications/PaperDeck.app` — the requirement should mention
  `certificate leaf`.
- **The certificate is about to expire.** The script warns below 60 days. Create a new one with the
  same name and Validity 3650 days, delete the old one, rebuild; grant Documents and notifications once
  more.
- **`./test.sh` can't find Testing.framework.** Install the Command Line Tools, or set
  `PAPERDECK_DEV_DIR` to the folder that contains `Frameworks/Testing.framework` (the Command Line Tools
  keep it in `Library/Developer` inside their folder).
- **The widget doesn't appear.** It's registered from the installed copy; open the app from
  Applications once, then Settings ▸ Widget ▸ Repair registration.
- **Warnings about callback-style APIs.** The script greps the MainActor app target for callback APIs
  (`getNotificationSettings`, `getCurrentConfigurations`, …) whose callbacks run off the main thread;
  use the async variants or a `nonisolated` wrapper.
