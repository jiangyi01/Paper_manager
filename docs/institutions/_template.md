# <Institution name> (<short name>)

*Template for an institution page. Copy it to `docs/institutions/<preset-id>.md` and fill in what
is specific to the institution; everything general stays in the [User Guide](../USER_GUIDE.md).
English first, then 中文.*

## Choosing the preset

- Built-in preset: Settings ▸ Profile ▸ Institution AI policy ▸ **<Institution name>**.
- No built-in preset yet: choose **Other…** and enter the name, short name, approved AI tools, the
  policy link (https) and the people default (*Ask each time* or *Never send to AI*). A lab can share
  these as a setup file: Settings ▸ General ▸ Export Settings… with only *Profile & institution* and
  *Mail senders & criteria* ticked.

A preset changes **wording only**. AI off until turned on, people's emails asking first and the
confidentiality guard are the same for every institution.

## AI guidance

- The institution's policy, in one or two sentences, and a link to it.
- Which AI tools or logins are approved (for example an Edu plan of Claude or ChatGPT).
- What that means for people's emails in PaperDeck (keep *Ask each time*, or set *Never*).

## Mail

- Mail system (Microsoft 365, Google Workspace, other) and which PaperDeck route works:
  [Power Automate](../guides/POWER_AUTOMATE.md), Gmail / IMAP app passwords, a folder source, or
  dragging emails in.
- For Microsoft 365: whether Power Automate and the OneDrive for Business connector are allowed, and
  the name of the OneDrive folder on a Mac (`~/Library/CloudStorage/OneDrive-<Organization>/`).
- For Google Workspace: whether app passwords are allowed.
- The fallback for paper alerts if the institution's mail can't be connected.

## Preset data (for maintainers)

The values a built-in preset carries (`Sources/PaperDeckConfig/Presets/OrganizationPresets.swift`):
`id`, `name` (en and zh), `shortName`, `approvedAITools`, `policyURL`, `peopleDefault`,
`mail.oneDriveRootHint`, `mail.oneDriveFallbackRootName`, `mail.knownSenderDomains`,
`mail.powerAutomatePortal`, and optional verbatim `texts`. See
[ARCHITECTURE-CONFIG.md](../ARCHITECTURE-CONFIG.md#adding-a-preset).

---

# <机构名称>（<简称>）

*机构页面模板。复制为 `docs/institutions/<preset-id>.md`，只写该机构特有的内容。*

- **选择预设**：设置 ▸ 个人资料 ▸ 机构 AI 规定 ▸ <机构名称>；没有内置预设时选「其他…」填写名称、简称、获批准的 AI 工具、
  规定链接和个人邮件默认值。预设只改变措辞，安全默认设置对所有机构都一样。
- **AI 指引**：机构规定（一两句话 + 链接）、获批准的工具或登录方式、对个人邮件的建议。
- **邮件**：邮件系统与可用的 PaperDeck 路线；Microsoft 365 是否允许 Power Automate 与 OneDrive for Business 连接器，
  以及 Mac 上 OneDrive 文件夹的名称；Google Workspace 是否允许应用专用密码；论文提醒的备选方案。
