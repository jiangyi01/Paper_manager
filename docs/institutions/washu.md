# Washington University in St. Louis (WashU)

*Notes for PaperDeck users at WashU. The general instructions are in the
[User Guide](../USER_GUIDE.md); this page only adds what is specific to WashU. 中文见下方。*

## Choosing the preset

Settings ▸ Profile ▸ Institution AI policy ▸ **Washington University in St. Louis (WashU)**. The
preset changes wording only — the mail warnings and policy notes name WashU's AI guidance and its
approved tools — and the safety defaults stay the same as for everyone.

A Mac that already used PaperDeck before institutions became configurable is set to this preset
automatically on its first launch of the new version, so nothing it shows changes; Settings ▸
Profile then says so ("Set to WashU because this Mac used PaperDeck before institutions were
configurable. Change it any time.").

## AI guidance

WashU's guidance: don't put WashU data or unpublished work into AI platforms that aren't approved.
**Claude Edu** and **ChatGPT Edu** are approved. With the preset:

- an advisor's or colleague's email stays on your Mac (local rules only) until you click **Analyze
  with AI** on that card; you can also set a sender to *Never*, or Settings ▸ Mail ▸ AI triage ▸
  *Local rules only*;
- for people's mail, prefer a Claude or Codex CLI signed in with your Claude Edu / ChatGPT Edu login;
- review invitations, manuscript-system emails, decisions on your own submissions and anything marked
  confidential are never sent to AI automatically (this holds for every institution).

## WashU email (Microsoft 365) with Power Automate

WashU email is Microsoft 365. PaperDeck can't sign in to it directly (that would need an app approved
by IT), so the [Power Automate route](../guides/POWER_AUTOMATE.md) is used:

1. Install OneDrive and sign in with your **WashU** account. Its folder on the Mac is
   `~/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/`. With the WashU preset,
   PaperDeck suggests `OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail/` even before the folder
   exists (the form has a Create Folder button).
2. Add your senders first, then build the flow at <https://make.powerautomate.com> with your WashU
   account — or use **Generate Import Package…** and *My flows ▸ Import ▸ Import Package (Legacy)*.
3. Add the account (its default name is "WashU (Power Automate)"), Test & Save, turn Mail on, and
   send yourself a test email.

## If Power Automate isn't available: Gmail for alerts

Paper alerts (Google Scholar, bioRxiv, arXiv, journal tables of contents) work well in a personal
Gmail account: subscribe them to that address (or forward them from WashU email), optionally label
them `PaperDeck` with a Gmail filter, turn on 2-Step Verification, create an app password and add the
account (Settings ▸ Mail ▸ Add Account… ▸ Gmail). Keep people's emails in WashU email and drag them in
when needed.

## Background

The tenant research behind the mail design (why Power Automate rather than IMAP or Graph sign-in) is
recorded in [docs/MAIL_DESIGN.md](../MAIL_DESIGN.md).

---

# 圣路易斯华盛顿大学（WashU）

*WashU 用户的补充说明。通用说明见 [用户指南](../USER_GUIDE.md)（英文）与 [README](../../README.md)，本页只写
WashU 特有的部分。*

## 选择预设

设置 ▸ 个人资料 ▸ 机构 AI 规定 ▸ **Washington University in St. Louis (WashU)**。预设只改变措辞——邮件提示和
规定说明会写明 WashU 的 AI 指引和获批准的工具——安全默认设置与所有人相同。

在机构可以配置之前就用过 PaperDeck 的 Mac，升级后第一次启动时会自动设为这个预设，所以显示的内容一字不变；
「设置 ▸ 个人资料」里会注明原因，可以随时更改。

## AI 使用指引

WashU 的指引：不要把 WashU 数据或未发表的工作放进未经批准的 AI 平台。**Claude Edu** 与 **ChatGPT Edu** 已获批准。
使用这个预设时：

- 导师 / 同事的邮件默认只用本机规则，直到你在那张卡片上点「让 AI 分析」；也可以把某个发件人设为「从不」，或在
  设置 ▸ 邮件 ▸ AI 分拣 选「仅本地规则」；
- 个人邮件建议使用以 Claude Edu / ChatGPT Edu 登录的 Claude 或 Codex CLI；
- 审稿邀请、投稿系统邮件、关于你自己投稿的决定，以及注明保密的邮件，永远不会被自动发给 AI（对所有机构都一样）。

## WashU 邮箱（Microsoft 365）+ Power Automate

WashU 邮箱是 Microsoft 365，不能直接登录（需要 IT 审批应用），所以使用 [Power Automate 路线](../guides/POWER_AUTOMATE.md)：

1. 安装 OneDrive 并用 **WashU** 账号登录。它在 Mac 上的文件夹是
   `~/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/`。使用 WashU 预设时，即使文件夹还不存在，
   PaperDeck 也会建议 `OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail/`（表单里有「创建文件夹」按钮）。
2. 先在「发件人」里加好发件人，再用 WashU 账号在 <https://make.powerautomate.com> 创建流——或者点「生成导入包…」，
   在「我的流 ▸ 导入 ▸ 导入包(旧版)」中导入。
3. 添加账户（默认名称「WashU (Power Automate)」），测试并保存，打开邮件，给自己发一封测试邮件。

## 不能用 Power Automate 时：用 Gmail 接收论文提醒

论文提醒（Google Scholar、bioRxiv、arXiv、期刊目录）很适合放在个人 Gmail：把它们订阅到这个地址（或从 WashU 邮箱转发），
可以用 Gmail 过滤器加上 `PaperDeck` 标签，开启两步验证，创建应用专用密码，然后添加账户（设置 ▸ 邮件 ▸ 添加账户… ▸
Gmail）。个人邮件留在 WashU 邮箱，需要时拖进 PaperDeck。

## 背景

邮件设计背后的租户调研（为什么用 Power Automate 而不是 IMAP 或 Graph 登录）记录在 [docs/MAIL_DESIGN.md](../MAIL_DESIGN.md)。
