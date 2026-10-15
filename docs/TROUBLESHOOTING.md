# Troubleshooting · 故障排查

**The quickest way: open Help ▸ Troubleshooting in PaperDeck.** It checks your Mac live and puts the
entries that apply right now at the top, with buttons that open the right settings.
最快的方法：在 PaperDeck 中打开「帮助 ▸ 故障排查」。它会实时检查你的 Mac，把当前适用的条目排在最前面，并提供直接打开相应设置的按钮。

The entries below are the same as in the app. They are generated from the Help Center content
(`PaperDeck --guide-export DIR --lang en|zh`) — edit `Sources/PaperDeckConfig/Guide/Content/`, not
the text between the markers. When asking someone for help, add the redacted report from
**Help ▸ Diagnostics… ▸ Copy Diagnostics…**.

- [English](#english)
- [中文](#中文)
- [Developer issues](#developer-issues)

## English

<!-- BEGIN GENERATED: troubleshooting en -->
<a id="fix-documents-access"></a>
### PaperDeck can't use the library folder

macOS asks once before an app may use Documents (or Desktop, Downloads, an external disk). If access was denied, PaperDeck can't open the library there.

1. Open System Settings ▸ Privacy & Security ▸ Files and Folders, find PaperDeck and turn on Documents Folder (or the folder your library is in).
2. Click Retry in PaperDeck's alert, or quit and open PaperDeck again.
3. PaperDeck isn't listed there? Reset the permission in Terminal, then open PaperDeck: macOS asks again.

   ```
   tccutil reset SystemPolicyDocumentsFolder "$(defaults read /Applications/PaperDeck.app/Contents/Info CFBundleIdentifier)"
   ```
4. Or keep the library somewhere else, for example ~/PaperDeck: Settings ▸ Library & Storage ▸ Change….

   [Where your library lives](USER_GUIDE.md#library-location)

**Related:** [The library folder is missing](#fix-library-missing), [Where your library lives](USER_GUIDE.md#library-location)

*Last reviewed: 2026-10*

<a id="fix-library-missing"></a>
### The library folder is missing

PaperDeck can't find its library folder — usually a disconnected disk, a moved or renamed folder, or a cloud folder that isn't available. Don't switch to a new empty folder: your papers are still where you left them.

1. Connect the disk (or sign in to the cloud service) that holds the library, then click Retry.
2. Moved or renamed the folder? Choose its new place — in PaperDeck's alert or with Settings ▸ Library & Storage ▸ Change…. PaperDeck recognizes it as the same library.
3. Avoid picking an empty folder such as ~/Papers just to get going: that starts a second, empty library.

**Related:** [PaperDeck can't use the library folder](#fix-documents-access), [Where your library lives](USER_GUIDE.md#library-location), [Papers in a cloud folder won't open](#fix-cloud-evicted)

*Last reviewed: 2026-10*

<a id="fix-library-mismatch"></a>
### This folder holds a different library

The library folder belongs to a different PaperDeck library than the index on this Mac. PaperDeck stopped before changing anything, so the two aren't mixed.

1. Open This Library: PaperDeck backs up its index, then rebuilds it from this folder's cards. Mail cards are kept; the previous index stays in the backups.
2. Changed the location by mistake? Go Back to … returns to the previous folder.
3. Neither is right: Choose Another Folder….

   [Where your library lives](USER_GUIDE.md#library-location)

**Related:** [Where your library lives](USER_GUIDE.md#library-location), [Two Macs show different libraries](#fix-two-macs-diverged), [One library on two Macs](USER_GUIDE.md#library-two-macs)

*Last reviewed: 2026-10*

<a id="fix-cloud-evicted"></a>
### Papers in a cloud folder won't open

iCloud Drive, OneDrive, Dropbox and Google Drive can move files off this Mac to save space. A paper whose PDF isn't downloaded can't be opened or indexed until it is.

1. In Finder, right-click the library folder and choose Keep Downloaded (iCloud Drive) or Always Keep on This Device (OneDrive, Dropbox, Google Drive).
2. For iCloud Drive you can also turn off Optimize Mac Storage, or keep the library outside iCloud (for example ~/PaperDeck).

   [Where your library lives](USER_GUIDE.md#library-location)
3. Once the files are back, PaperDeck stops reporting missing PDFs.
4. Use a cloud library on one Mac at a time.

   [One library on two Macs](USER_GUIDE.md#library-two-macs)

**Related:** [Where your library lives](USER_GUIDE.md#library-location), [One library on two Macs](USER_GUIDE.md#library-two-macs), [Search finds titles but not the text inside papers](#fix-search-after-move)

*Last reviewed: 2026-10*

<a id="fix-cli-not-found"></a>
### Claude Code or the Codex CLI isn't found

PaperDeck looks for the claude and codex command-line tools where their installers put them and on your login shell's PATH. If it can't find the one you chose, AI reading can't start.

1. Install it: Claude Code with the official installer; the Codex CLI with the ChatGPT desktop app or Homebrew.

   ```
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   ```
   brew install --cask codex
   ```

   [Set up AI reading](USER_GUIDE.md#ai-setup)
2. Installed but still not found (a shell other than zsh, an unusual folder)? Find the path in Terminal and enter it in Settings ▸ AI Reading ▸ Custom path.

   ```
   which claude
   ```

   ```
   which codex
   ```
3. Check again with I've Signed In, or reopen Settings ▸ AI Reading. Detection only runs version and status commands — no quota.

**Related:** [Set up AI reading](USER_GUIDE.md#ai-setup), [AI reading says “not signed in”](#fix-cli-not-signed-in)

*Last reviewed: 2026-10*

<a id="fix-cli-not-signed-in"></a>
### AI reading says “not signed in”

The Claude or Codex tool is installed but not signed in to your subscription. Signing in happens in Terminal; PaperDeck never sees your password.

1. **Claude:** run `claude`, type /login and choose your Claude subscription account; then click I've Signed In.

   ```
   claude
   ```
2. **ChatGPT:** run `codex login`, choose Sign in with ChatGPT and finish in the browser; `codex login status` should then say you're logged in using ChatGPT.

   ```
   codex login
   ```

   ```
   codex login status
   ```
3. Signed in but PaperDeck disagrees? Quit and reopen PaperDeck once, then look at Help ▸ Diagnostics… for the reason.

   [Diagnostics](USER_GUIDE.md#diagnostics)

**Related:** [“Signed in with an API key”](#fix-cli-api-key), [Switch to another AI account](USER_GUIDE.md#ai-switch-account), [Set up AI reading](USER_GUIDE.md#ai-setup)

*Last reviewed: 2026-10*

<a id="fix-cli-api-key"></a>
### “Signed in with an API key”

PaperDeck reads papers only with a subscription login (Claude: claude.ai; ChatGPT: Sign in with ChatGPT). A tool signed in with an API key is refused, so nothing is ever billed per call.

1. **Claude:** run `claude`, type /logout, then /login and choose your Claude subscription account (not an API / Console account).

   ```
   claude
   ```
2. **ChatGPT:** run `codex login` and choose Sign in with ChatGPT; it replaces the API-key login.

   ```
   codex login
   ```
3. API keys in your shell environment are never passed on: PaperDeck starts the tools with a short allowlist of variables.

**Related:** [AI reading says “not signed in”](#fix-cli-not-signed-in), [Switch to another AI account](USER_GUIDE.md#ai-switch-account)

*Last reviewed: 2026-10*

<a id="fix-usage-limit"></a>
### AI reading is paused by a usage limit

When your subscription's usage limit is reached, PaperDeck pauses that service until the reset time and then continues by itself. Nothing is lost; papers wait in the queue.

1. Wait for the reset time shown in the status, or switch to the other service in Settings ▸ AI Reading — Claude and ChatGPT limits are separate.
2. Big batches use more: dropping more than 3 papers at once asks first, and you can cancel queued papers from the reading queue in the toolbar.
3. A pause belongs to the account that hit the limit; it ends at that account's reset time.

   [Switch to another AI account](USER_GUIDE.md#ai-switch-account)

**Related:** [Switch to another AI account](USER_GUIDE.md#ai-switch-account), [Set up AI reading](USER_GUIDE.md#ai-setup)

*Last reviewed: 2026-10*

<a id="fix-notifications"></a>
### The daily reminder doesn't appear

The reminder is one macOS notification a day at the time you set (11:00 by default).

1. Allow notifications: System Settings ▸ Notifications ▸ PaperDeck ▸ Allow Notifications. The Alerts style keeps the reminder on screen until you act.
2. Check the time and days in Settings ▸ Plan & Reminders, then use Send Test Notification.
3. A Focus mode can hold notifications back: allow PaperDeck in the Focus you use at that time.
4. PaperDeck has to be running at reminder time: turn on Open PaperDeck at login.

   [PaperDeck doesn't open at login](#fix-login-item)

**Related:** [PaperDeck doesn't open at login](#fix-login-item), [Getting started](USER_GUIDE.md#getting-started)

*Last reviewed: 2026-10*

<a id="fix-widget-missing"></a>
### The widget isn't in the widget gallery

macOS lists PaperDeck's widget only after the app has run from Applications at least once.

1. Make sure PaperDeck is in Applications (or ~/Applications) and open it from there once.
2. Settings ▸ Widget ▸ Repair registration registers the app and its widget with macOS again.
3. Then right-click the desktop ▸ Edit Widgets… and search for PaperDeck.
4. Still missing? This Terminal command should list the widget:

   ```
   pluginkit -m -v -i "$(defaults read /Applications/PaperDeck.app/Contents/PlugIns/PaperDeckWidget.appex/Contents/Info CFBundleIdentifier)"
   ```

**Related:** [macOS blocks PaperDeck or runs a temporary copy](#fix-app-blocked), [Getting started](USER_GUIDE.md#getting-started)

*Last reviewed: 2026-10*

<a id="fix-login-item"></a>
### PaperDeck doesn't open at login

PaperDeck lives in the menu bar, so it should start when you log in — the edge strip, the reminder and mail sync need it running.

1. Turn on Open PaperDeck at login in Settings ▸ General. macOS then shows “Background item added” — that's PaperDeck.
2. If macOS asks for approval, allow PaperDeck in System Settings ▸ General ▸ Login Items.
3. Open at login needs PaperDeck in Applications: a copy run from Downloads or a disk image can't be registered.

**Related:** [macOS blocks PaperDeck or runs a temporary copy](#fix-app-blocked), [The daily reminder doesn't appear](#fix-notifications)

*Last reviewed: 2026-10*

<a id="fix-app-blocked"></a>
### macOS blocks PaperDeck or runs a temporary copy

A copy you received is marked as downloaded: macOS blocks its first launch, and opened from Downloads it may run from a hidden temporary copy, where the widget and Open at Login don't work.

1. Quit PaperDeck, move PaperDeck.app into Applications, then open it from there.
2. If macOS says it can't check the app: System Settings ▸ Privacy & Security ▸ Open Anyway, then confirm.
3. Built it yourself? Sign it with your stable certificate, so macOS keeps its permissions after each rebuild.

   [Build PaperDeck from source](USER_GUIDE.md#build-from-source)

**Related:** [Give PaperDeck to a labmate](USER_GUIDE.md#install-for-labmate), [Build PaperDeck from source](USER_GUIDE.md#build-from-source), [The widget isn't in the widget gallery](#fix-widget-missing)

*Last reviewed: 2026-10*

<a id="fix-mail-auth-failed"></a>
### A mail account can't sign in

The mail server rejected the password. PaperDeck stops trying that account, so the provider doesn't lock it, until you fix it.

1. Make a new app password (Google, Apple, Yahoo, Fastmail) — your normal password usually doesn't work — then edit the account in Settings ▸ Mail and click Test & Save.
2. Gmail: app passwords need 2-Step Verification, and a work or school Google account may have them turned off.

   [Gmail](USER_GUIDE.md#mail-gmail) · [Google Workspace (Beta)](USER_GUIDE.md#mail-google-workspace)
3. Outlook.com and Microsoft 365 mailboxes don't accept app passwords: use one of their routes instead.

   [Outlook.com / Hotmail](USER_GUIDE.md#mail-outlook-com) · [Microsoft 365 with Power Automate](USER_GUIDE.md#mail-m365-power-automate)
4. Test & Save retries just that account; Sync Now retries all of them.

**Related:** [Gmail](USER_GUIDE.md#mail-gmail), [Outlook.com / Hotmail](USER_GUIDE.md#mail-outlook-com), [Google Workspace (Beta)](USER_GUIDE.md#mail-google-workspace), [Yahoo, Fastmail and other IMAP](USER_GUIDE.md#mail-other-imap)

*Last reviewed: 2026-10*

<a id="fix-mail-not-email-files"></a>
### “Files in this folder aren't complete emails”

The watched folder holds files without the email's sender and attachments — usually a Power Automate flow that saves the trigger's Body instead of the exported email.

1. In the flow, open “Create file” and set File Content to the Body of “Export email (V2)” — not the trigger's Body, which is only the message's HTML.

   [make.powerautomate.com](https://make.powerautomate.com)
2. Delete the files that aren't complete emails from the folder; the notice goes away at the next sync.
3. Send yourself a test email from a listed sender to check.

   [Microsoft 365 with Power Automate](USER_GUIDE.md#mail-m365-power-automate)

**Related:** [Microsoft 365 with Power Automate](USER_GUIDE.md#mail-m365-power-automate), [Mail from a folder (.eml)](USER_GUIDE.md#mail-folder-sources)

*Last reviewed: 2026-10*

<a id="fix-mail-onedrive-missing"></a>
### PaperDeck can't find the OneDrive mail folder

The Power Automate route needs OneDrive for your work or school account on this Mac, with the “PaperDeck Mail” folder synced.

1. Install OneDrive and sign in with your work or school account; it then appears under Locations in Finder's sidebar.
2. A personal OneDrive isn't used for this route — sign in with the work or school account as well.
3. Make sure the “PaperDeck Mail” folder exists at the top of that OneDrive and is set to sync.
4. If the folder moved, edit the account in Settings ▸ Mail and choose it again. When PaperDeck first reads it, macOS may ask to allow access to files managed by OneDrive — click Allow.

**Related:** [Microsoft 365 with Power Automate](USER_GUIDE.md#mail-m365-power-automate), [Papers in a cloud folder won't open](#fix-cloud-evicted)

*Last reviewed: 2026-10*

<a id="fix-search-after-move"></a>
### Search finds titles but not the text inside papers

After moving to a new Mac or opening an existing library, the full-text index starts empty. Rebuilding it reads the PDFs on this Mac.

1. Settings ▸ Library & Storage ▸ Re-index full text reads the PDFs again (no AI quota) and fills the search index.
2. Scanned PDFs without a text layer can't be searched.
3. In a cloud folder, keep the library downloaded first.

   [Papers in a cloud folder won't open](#fix-cloud-evicted)

**Related:** [Move to a new Mac](USER_GUIDE.md#move-to-new-mac), [Papers in a cloud folder won't open](#fix-cloud-evicted)

*Last reviewed: 2026-10*

<a id="fix-two-macs-diverged"></a>
### Two Macs show different libraries

Each Mac keeps its own index of a shared library folder. Using the library on both Macs at once, or before the folder finished syncing, makes the indexes drift apart.

1. Quit PaperDeck on both Macs and let the cloud folder finish syncing.
2. On the Mac you'll use now: Settings ▸ Library & Storage ▸ Rebuild index from folders. The index is rebuilt from the cards in the folder.
3. From then on, use the library on one Mac at a time.

   [One library on two Macs](USER_GUIDE.md#library-two-macs)
4. A PDF missing on one Mac may simply not be downloaded there yet.

   [Papers in a cloud folder won't open](#fix-cloud-evicted)

**Related:** [One library on two Macs](USER_GUIDE.md#library-two-macs), [This folder holds a different library](#fix-library-mismatch), [Papers in a cloud folder won't open](#fix-cloud-evicted)

*Last reviewed: 2026-10*
<!-- END GENERATED: troubleshooting en -->

## 中文

<!-- BEGIN GENERATED: troubleshooting zh -->
<a id="fix-documents-access"></a>
### PaperDeck 无法使用论文库文件夹

应用第一次使用「文稿」（或桌面、下载、外置磁盘）时，macOS 会询问一次。如果当时拒绝了访问，PaperDeck 就无法打开那里的论文库。

1. 打开「系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹」，找到 PaperDeck，打开「文稿」文件夹（或论文库所在的文件夹）。
2. 在 PaperDeck 的提示里点「重试」，或退出后重新打开 PaperDeck。
3. 列表里没有 PaperDeck？在「终端」中重置这项权限，然后打开 PaperDeck：macOS 会再次询问。

   ```
   tccutil reset SystemPolicyDocumentsFolder "$(defaults read /Applications/PaperDeck.app/Contents/Info CFBundleIdentifier)"
   ```
4. 或者把论文库放到别处，例如 ~/PaperDeck：设置 ▸ 资料库与存储 ▸ 更改…。

   [论文库放在哪里](USER_GUIDE.md#library-location)

**相关:** [找不到论文库文件夹](#fix-library-missing), [论文库放在哪里](USER_GUIDE.md#library-location)

*最近核对: 2026-10*

<a id="fix-library-missing"></a>
### 找不到论文库文件夹

PaperDeck 找不到论文库文件夹——通常是磁盘没连接、文件夹被移动或改名，或者云文件夹不可用。不要改用一个新的空文件夹：你的论文还在原来的地方。

1. 连接存放论文库的磁盘（或登录对应的云服务），然后点「重试」。
2. 移动过或改过文件夹名？选择它的新位置——在 PaperDeck 的提示里，或用「设置 ▸ 资料库与存储 ▸ 更改…」。PaperDeck 会识别出这是同一个论文库。
3. 不要为了先用起来就选一个空文件夹（例如 ~/Papers）：那会新建第二个空的论文库。

**相关:** [PaperDeck 无法使用论文库文件夹](#fix-documents-access), [论文库放在哪里](USER_GUIDE.md#library-location), [云文件夹里的论文打不开](#fix-cloud-evicted)

*最近核对: 2026-10*

<a id="fix-library-mismatch"></a>
### 这个文件夹里是另一个论文库

论文库文件夹属于另一个 PaperDeck 论文库，与这台 Mac 上的索引不一致。PaperDeck 在改动任何内容之前就停了下来，所以两者没有被混在一起。

1. 「打开这个论文库」：PaperDeck 先备份索引，再根据这个文件夹里的卡片重建。邮件卡片会保留；之前的索引留在备份里。
2. 误改了位置？「回到 …」会回到之前的文件夹。
3. 两个都不对：点「选择其他文件夹…」。

   [论文库放在哪里](USER_GUIDE.md#library-location)

**相关:** [论文库放在哪里](USER_GUIDE.md#library-location), [两台 Mac 上的论文库不一样](#fix-two-macs-diverged), [两台 Mac 共用一个论文库](USER_GUIDE.md#library-two-macs)

*最近核对: 2026-10*

<a id="fix-cloud-evicted"></a>
### 云文件夹里的论文打不开

iCloud 云盘、OneDrive、Dropbox 和 Google 云端硬盘可能会为了节省空间把文件移出这台 Mac。PDF 没有下载的论文，在下载回来之前无法打开或建立索引。

1. 在 Finder 中右键点按论文库文件夹，选择「保留下载」（iCloud 云盘）或「始终保留在此设备上」（OneDrive、Dropbox、Google 云端硬盘）。
2. 对于 iCloud 云盘，也可以关闭「优化 Mac 储存空间」，或把论文库放在 iCloud 之外（例如 ~/PaperDeck）。

   [论文库放在哪里](USER_GUIDE.md#library-location)
3. 文件下载回来后，PaperDeck 就不再提示缺少 PDF。
4. 云端的论文库同一时间只在一台 Mac 上使用。

   [两台 Mac 共用一个论文库](USER_GUIDE.md#library-two-macs)

**相关:** [论文库放在哪里](USER_GUIDE.md#library-location), [两台 Mac 共用一个论文库](USER_GUIDE.md#library-two-macs), [搜索只能找到标题，找不到论文正文](#fix-search-after-move)

*最近核对: 2026-10*

<a id="fix-cli-not-found"></a>
### 找不到 Claude Code 或 Codex CLI

PaperDeck 会在安装程序的默认位置和登录 shell 的 PATH 中查找 claude 与 codex 命令行工具。找不到你选的那个时，AI 解读就无法开始。

1. 先安装：Claude Code 用官方安装命令；Codex CLI 用 ChatGPT 桌面版或 Homebrew。

   ```
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   ```
   brew install --cask codex
   ```

   [设置 AI 解读](USER_GUIDE.md#ai-setup)
2. 已经安装但仍然找不到（用的不是 zsh，或装在特殊位置）？在「终端」里查到路径，填到「设置 ▸ AI 解读 ▸ 自定义路径」。

   ```
   which claude
   ```

   ```
   which codex
   ```
3. 点「我已登录」或重新打开「设置 ▸ AI 解读」再检测一次。检测只运行版本和状态命令——不消耗额度。

**相关:** [设置 AI 解读](USER_GUIDE.md#ai-setup), [AI 解读显示「未登录」](#fix-cli-not-signed-in)

*最近核对: 2026-10*

<a id="fix-cli-not-signed-in"></a>
### AI 解读显示「未登录」

Claude 或 Codex 工具已安装，但没有登录你的订阅。登录在「终端」里完成；PaperDeck 永远看不到你的密码。

1. **Claude**：运行 `claude`，输入 /login 并选择你的 Claude 订阅账号；然后点「我已登录」。

   ```
   claude
   ```
2. **ChatGPT**：运行 `codex login`，选择 Sign in with ChatGPT 并在浏览器中完成；之后 `codex login status` 应显示已用 ChatGPT 登录。

   ```
   codex login
   ```

   ```
   codex login status
   ```
3. 已经登录但 PaperDeck 仍显示未登录？退出并重新打开 PaperDeck 一次，然后在「帮助 ▸ 诊断信息…」中查看原因。

   [诊断信息](USER_GUIDE.md#diagnostics)

**相关:** [「用 API key 登录」](#fix-cli-api-key), [切换到另一个 AI 账号](USER_GUIDE.md#ai-switch-account), [设置 AI 解读](USER_GUIDE.md#ai-setup)

*最近核对: 2026-10*

<a id="fix-cli-api-key"></a>
### 「用 API key 登录」

PaperDeck 只用订阅登录解读论文（Claude：claude.ai；ChatGPT：Sign in with ChatGPT）。用 API key 登录的工具会被拒绝，所以永远不会按调用计费。

1. **Claude**：运行 `claude`，输入 /logout，再输入 /login，选择你的 Claude 订阅账号（不是 API / Console 账号）。

   ```
   claude
   ```
2. **ChatGPT**：运行 `codex login` 并选择 Sign in with ChatGPT；它会替换当前的 API key 登录。

   ```
   codex login
   ```
3. shell 环境里的 API key 永远不会被传过去：PaperDeck 启动这些工具时只传递一小份白名单里的环境变量。

**相关:** [AI 解读显示「未登录」](#fix-cli-not-signed-in), [切换到另一个 AI 账号](USER_GUIDE.md#ai-switch-account)

*最近核对: 2026-10*

<a id="fix-usage-limit"></a>
### AI 解读因用量上限暂停

订阅达到用量上限时，PaperDeck 会暂停这个服务直到重置时间，然后自动继续。不会丢失任何内容；论文在队列里等待。

1. 等到状态里显示的重置时间，或在「设置 ▸ AI 解读」中换用另一个服务——Claude 和 ChatGPT 的额度分开计算。
2. 批量越大用得越多：一次拖入超过 3 篇会先询问，也可以在工具栏的解读队列里取消排队的论文。
3. 暂停属于达到上限的那个账号；在那个账号的重置时间结束。

   [切换到另一个 AI 账号](USER_GUIDE.md#ai-switch-account)

**相关:** [切换到另一个 AI 账号](USER_GUIDE.md#ai-switch-account), [设置 AI 解读](USER_GUIDE.md#ai-setup)

*最近核对: 2026-10*

<a id="fix-notifications"></a>
### 每日提醒没有出现

提醒是每天在你设定的时间（默认 11:00）发出的一条 macOS 通知。

1. 允许通知：系统设置 ▸ 通知 ▸ PaperDeck ▸ 允许通知。选择「提醒」样式时，通知会一直留在屏幕上直到你处理。
2. 在「设置 ▸ 阅读计划与提醒」中检查时间和日期，然后点「发送测试通知」。
3. 专注模式可能会拦下通知：在那个时间使用的专注模式里允许 PaperDeck。
4. 提醒时间 PaperDeck 需要在运行：打开「登录时自动启动 PaperDeck」。

   [登录时 PaperDeck 没有自动打开](#fix-login-item)

**相关:** [登录时 PaperDeck 没有自动打开](#fix-login-item), [入门清单](USER_GUIDE.md#getting-started)

*最近核对: 2026-10*

<a id="fix-widget-missing"></a>
### 小组件列表里找不到 PaperDeck

PaperDeck 至少从「应用程序」文件夹运行过一次后，macOS 才会列出它的小组件。

1. 确认 PaperDeck 在「应用程序」（或 ~/Applications）中，并从那里打开一次。
2. 「设置 ▸ 小组件 ▸ 修复注册」会重新向 macOS 注册应用和它的小组件。
3. 然后在桌面上右键 ▸ 编辑小组件…，搜索 PaperDeck。
4. 还是没有？下面的「终端」命令应该能列出这个小组件：

   ```
   pluginkit -m -v -i "$(defaults read /Applications/PaperDeck.app/Contents/PlugIns/PaperDeckWidget.appex/Contents/Info CFBundleIdentifier)"
   ```

**相关:** [macOS 阻止 PaperDeck 或运行临时副本](#fix-app-blocked), [入门清单](USER_GUIDE.md#getting-started)

*最近核对: 2026-10*

<a id="fix-login-item"></a>
### 登录时 PaperDeck 没有自动打开

PaperDeck 住在菜单栏里，所以应该在登录时启动——边缘竖条、提醒和邮件同步都需要它在运行。

1. 在「设置 ▸ 通用」中打开「登录时自动启动 PaperDeck」。之后 macOS 会显示「已添加后台项目」——那就是 PaperDeck。
2. 如果 macOS 要求批准，请在「系统设置 ▸ 通用 ▸ 登录项」中允许 PaperDeck。
3. 「登录时打开」需要 PaperDeck 在「应用程序」中：从「下载」或磁盘映像运行的副本无法注册。

**相关:** [macOS 阻止 PaperDeck 或运行临时副本](#fix-app-blocked), [每日提醒没有出现](#fix-notifications)

*最近核对: 2026-10*

<a id="fix-app-blocked"></a>
### macOS 阻止 PaperDeck 或运行临时副本

别人发给你的副本会被标记为下载的应用：macOS 会阻止第一次打开；如果从「下载」中打开，它可能会从一个隐藏的临时副本运行，那样小组件和「登录时打开」都无法使用。

1. 退出 PaperDeck，把 PaperDeck.app 移到「应用程序」文件夹，再从那里打开。
2. 如果 macOS 提示无法检查这个应用：系统设置 ▸ 隐私与安全性 ▸ 仍要打开，然后确认。
3. 是你自己构建的？用你固定的证书签名，这样每次重新构建后 macOS 都会保留它的权限。

   [从源代码构建 PaperDeck](USER_GUIDE.md#build-from-source)

**相关:** [把 PaperDeck 分享给同事](USER_GUIDE.md#install-for-labmate), [从源代码构建 PaperDeck](USER_GUIDE.md#build-from-source), [小组件列表里找不到 PaperDeck](#fix-widget-missing)

*最近核对: 2026-10*

<a id="fix-mail-auth-failed"></a>
### 邮件账户无法登录

邮件服务器拒绝了密码。PaperDeck 会停止尝试这个账户（避免被服务商锁定），直到你修好为止。

1. 重新生成一个应用专用密码（Google、Apple、Yahoo、Fastmail）——普通密码通常不行——然后在「设置 ▸ 邮件」中编辑账户并点「测试并保存」。
2. Gmail：应用专用密码需要两步验证；工作或学校的 Google 账号可能已关闭这项功能。

   [Gmail](USER_GUIDE.md#mail-gmail) · [Google Workspace（Beta）](USER_GUIDE.md#mail-google-workspace)
3. Outlook.com 和 Microsoft 365 邮箱不接受应用专用密码：请改用它们对应的路线。

   [Outlook.com / Hotmail](USER_GUIDE.md#mail-outlook-com) · [Microsoft 365 + Power Automate](USER_GUIDE.md#mail-m365-power-automate)
4. 「测试并保存」只重试这一个账户；「立即同步」会重试所有账户。

**相关:** [Gmail](USER_GUIDE.md#mail-gmail), [Outlook.com / Hotmail](USER_GUIDE.md#mail-outlook-com), [Google Workspace（Beta）](USER_GUIDE.md#mail-google-workspace), [Yahoo、Fastmail 与其他 IMAP](USER_GUIDE.md#mail-other-imap)

*最近核对: 2026-10*

<a id="fix-mail-not-email-files"></a>
### 「此文件夹中有文件不是完整的邮件」

被监视的文件夹里有缺少发件人和附件的文件——通常是 Power Automate 流保存了触发器的 Body，而不是导出的整封邮件。

1. 在流中打开「Create file」，把 File Content 设为「Export email (V2)」的 Body——不是触发器的 Body，那只是邮件的 HTML 正文。

   [make.powerautomate.com](https://make.powerautomate.com)
2. 从文件夹里删除那些不完整的文件；下次同步后提示就会消失。
3. 用列表中的发件人给自己发一封测试邮件来确认。

   [Microsoft 365 + Power Automate](USER_GUIDE.md#mail-m365-power-automate)

**相关:** [Microsoft 365 + Power Automate](USER_GUIDE.md#mail-m365-power-automate), [从文件夹接收邮件（.eml）](USER_GUIDE.md#mail-folder-sources)

*最近核对: 2026-10*

<a id="fix-mail-onedrive-missing"></a>
### PaperDeck 找不到 OneDrive 邮件文件夹

Power Automate 路线需要这台 Mac 上有工作或学校账号的 OneDrive，并且「PaperDeck Mail」文件夹已同步。

1. 安装 OneDrive 并用工作或学校账号登录；之后它会出现在 Finder 边栏的「位置」中。
2. 这条路线不使用个人 OneDrive——请同时登录工作或学校账号。
3. 确认这个 OneDrive 最上层有「PaperDeck Mail」文件夹，并且设为同步。
4. 如果文件夹移动过，在「设置 ▸ 邮件」中编辑账户并重新选择。PaperDeck 第一次读取它时，macOS 可能会询问是否允许访问由 OneDrive 管理的文件——点「允许」。

**相关:** [Microsoft 365 + Power Automate](USER_GUIDE.md#mail-m365-power-automate), [云文件夹里的论文打不开](#fix-cloud-evicted)

*最近核对: 2026-10*

<a id="fix-search-after-move"></a>
### 搜索只能找到标题，找不到论文正文

迁移到新 Mac 或打开已有论文库之后，全文索引是空的。重建全文索引会在这台 Mac 上重新读取 PDF。

1. 「设置 ▸ 资料库与存储 ▸ 重建全文索引」会重新读取 PDF（不消耗 AI 额度）并填好搜索索引。
2. 没有文字层的扫描版 PDF 无法搜索。
3. 放在云文件夹里时，先让论文库保持已下载。

   [云文件夹里的论文打不开](#fix-cloud-evicted)

**相关:** [迁移到新 Mac](USER_GUIDE.md#move-to-new-mac), [云文件夹里的论文打不开](#fix-cloud-evicted)

*最近核对: 2026-10*

<a id="fix-two-macs-diverged"></a>
### 两台 Mac 上的论文库不一样

每台 Mac 都为共享的论文库文件夹各自保存一份索引。两台 Mac 同时使用，或者在文件夹同步完成前使用，都会让两边的索引变得不一致。

1. 在两台 Mac 上都退出 PaperDeck，等云文件夹同步完成。
2. 在接下来要用的那台 Mac 上：设置 ▸ 资料库与存储 ▸ 从文件夹重建索引。索引会根据文件夹里的卡片重建。
3. 之后同一时间只在一台 Mac 上使用论文库。

   [两台 Mac 共用一个论文库](USER_GUIDE.md#library-two-macs)
4. 某台 Mac 上缺少的 PDF，可能只是还没有在那台 Mac 上下载。

   [云文件夹里的论文打不开](#fix-cloud-evicted)

**相关:** [两台 Mac 共用一个论文库](USER_GUIDE.md#library-two-macs), [这个文件夹里是另一个论文库](#fix-library-mismatch), [云文件夹里的论文打不开](#fix-cloud-evicted)

*最近核对: 2026-10*
<!-- END GENERATED: troubleshooting zh -->

## Developer issues

For people who build PaperDeck themselves (see [BUILDING.md](BUILDING.md)).

- **Permissions reset after every build** (Documents access, notifications, the widget, keychain
  prompts). The build was signed ad hoc (`--allow-adhoc`, `--sign -`) or with a different certificate.
  Sign with your stable self-signed certificate; `codesign -d -r- /Applications/PaperDeck.app` should
  show a requirement with `certificate leaf`.
- **The signing certificate expires.** `./build_app.sh` warns when fewer than 60 days are left. Create
  a new certificate with the same name and Validity 3650 days, delete the old one and rebuild; macOS
  asks for Documents and notification access once more.
- **"Signing identity … not found".** Check the name with `security find-identity -p codesigning`
  and with `./build_app.sh --print-config`; set `PAPERDECK_SIGN_IDENTITY` in `build.local.env` if
  your certificate has another name.
- **`./test.sh` can't find Testing.framework.** The tests use Swift Testing from the Command Line
  Tools. Install or update them (`xcode-select --install`), or set `PAPERDECK_DEV_DIR` (environment
  or `build.local.env`) to the folder that contains `Frameworks/Testing.framework`.
- **A second copy of the app shadows the installed one.** `./build_app.sh` lists other registered
  PaperDeck copies after installing; unregister stale ones with the `lsregister -u <path>` command it
  prints.
- **A development build spends no quota.** Use `./build_app.sh --dev` only for development copies:
  it turns AI reading off. Your daily copy is built without it.
