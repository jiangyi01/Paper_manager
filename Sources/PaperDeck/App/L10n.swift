import Foundation
import Observation
import PaperDeckCore
import PaperDeckConfig

/// SwiftUI views observe this so a language switch re-renders everything.
@Observable
final class LangStore {
    static let shared = LangStore()
    var lang: UILang = .en
    /// The reading provider generic strings name (「Claude 解读后显示 TL;DR」 / 「ChatGPT 解读后…」):
    /// SettingsStore keeps it equal to `agent.provider` (a claude / codex `agent.mode` wins).
    var provider: AIProviderKind = .claude
    /// The institution and research field the organization- and field-dependent strings use
    /// (`ConfigStore` mirrors its snapshot here). Until then: every existing install's
    /// configuration (`ConfigSnapshot.legacy`).
    var org: OrganizationProfile = ConfigSnapshot.legacy.organization
    var field: FieldPreset = ConfigSnapshot.legacy.field
    /// The folder the import hints name as an example (`import.lastFolder`, else ~/Downloads;
    /// `ConfigStore` mirrors it).
    var importFolderExample: String = ConfigStore.defaultImportFolder
    private init() {}
}

/// App-chrome strings (chips, reminders and widget text live in SharedStrings).
enum L {
    static var lang: UILang { LangStore.shared.lang }
    private static var zh: Bool { lang == .zh }
    /// The chosen reading provider (see `LangStore.provider`).
    static var provider: AIProviderKind { LangStore.shared.provider }
    /// "Claude" / "ChatGPT" — the chosen provider's short name for generic strings. Status views
    /// name `AgentQueueStatus.shownKind` instead (the provider the status describes).
    static var ai: String { provider.shortName }
    /// The configured institution / research field (see `LangStore.org` / `.field`).
    static var org: OrganizationProfile { LangStore.shared.org }
    static var field: FieldPreset { LangStore.shared.field }

    static var appName: String { "PaperDeck" }
    static var ok: String { zh ? "好" : "OK" }
    static var cancel: String { zh ? "取消" : "Cancel" }
    static var quit: String { zh ? "退出 PaperDeck" : "Quit PaperDeck" }
    static var settings: String { zh ? "设置…" : "Settings…" }
    static var settingsTitle: String { zh ? "PaperDeck 设置" : "PaperDeck Settings" }
    static var openLibrary: String { zh ? "打开 PaperDeck" : "Open PaperDeck" }
    static var language: String { zh ? "语言 / Language" : "Language / 语言" }
    static var launchAtLogin: String { zh ? "开机自动启动" : "Launch at login" }
    static var libraryTitle: String { zh ? "PaperDeck 论文库" : "PaperDeck Library" }
    static var emptyLibrary: String { zh ? "把论文 PDF 拖到这里" : "Drop paper PDFs here" }

    static func ignoredNonPDF(count: Int, names: String) -> String {
        zh ? "已忽略 \(count) 个非 PDF 文件：\(names)" : "Ignored \(count) non-PDF file(s): \(names)"
    }
    static func markedDone(_ title: String) -> String {
        zh ? "已标记为已读：\(title)" : "Marked as read: \(title)"
    }
    static var pdfMissing: String { zh ? "找不到这篇论文的 PDF 文件" : "The PDF file for this paper is missing" }
    static var libraryUnavailableTitle: String { zh ? "无法使用论文库文件夹" : "Can't use the library folder" }
    static func libraryUnavailableBody(path: String, alt: String) -> String {
        zh ? "PaperDeck 无法写入 \(path)（可能未授权访问「文稿」）。\n\n可以在「系统设置 → 隐私与安全性 → 文件与文件夹」中允许后重试，或改用 \(alt)。"
           : "PaperDeck can't write to \(path) (Documents access may be denied).\n\nAllow it in System Settings → Privacy & Security → Files and Folders and retry, or use \(alt) instead."
    }
    static var useAlternativeLibrary: String { zh ? "改用 ~/Papers" : "Use ~/Papers" }
    static var retry: String { zh ? "重试" : "Retry" }

    // Launch: the library database is newer than this build, couldn't be opened / upgraded, or
    // the app's own folders couldn't be created (`LibraryOpenFailure`). Quit, Retry, Show Backups /
    // Show in Finder — never another library folder (`LaunchAlert.buttons`).
    static func databaseFailureTitle(_ f: LibraryOpenFailure) -> String {
        switch f {
        case .newerVersion: return zh ? "这个论文库需要更新版本的 PaperDeck" : "This library needs a newer PaperDeck"
        case .appData: return zh ? "PaperDeck 无法创建它的数据文件夹" : "PaperDeck couldn't create its data folder"
        default: return zh ? "PaperDeck 无法打开论文库数据库" : "PaperDeck couldn't open its library database"
        }
    }
    static func databaseFailureBody(_ f: LibraryOpenFailure) -> String {
        if case .newerVersion(let found, let supported) = f {
            return zh
                ? "论文库数据库已被更新版本的 PaperDeck 升级（格式 v\(found)；这个版本最多支持 v\(supported)）。请安装更新版本的 PaperDeck 再打开。\n\n没有修改或删除任何内容。每次升级前保存的副本在「Backups」文件夹里。"
                : "Your library database was upgraded by a newer version of PaperDeck (format v\(found); this version reads up to v\(supported)). Install the newer PaperDeck to open it.\n\nNothing was changed or deleted. The copies saved before each upgrade are in the Backups folder."
        }
        if case .appData(let folder) = f {
            return zh
                ? "PaperDeck 把论文库数据库、备份和缓存保存在这个文件夹里，但无法创建它：\n\(folder.path)\n\n请在 Finder 中检查它所在的文件夹是否可写。换一个论文库文件夹也无济于事，因此没有做任何更改。修复后点「重试」。"
                : "PaperDeck keeps its library database, backups and caches in this folder but couldn't create it:\n\(folder.path)\n\nCheck in Finder that the folder containing it can be written to. Choosing another library folder wouldn't help, so nothing was changed. Fix it, then click Retry."
        }
        let diskFull = f == .database(diskFull: true)
        if zh {
            return (diskFull ? "磁盘已满。" : "") + "PaperDeck 无法打开或升级论文库数据库，为免影响你的论文库，没有继续打开。\n\n没有删除任何内容。每次升级前保存的副本在「Backups」文件夹里。"
                + (diskFull ? "请先释放一些磁盘空间，再点「重试」。" : "点「重试」再试一次；如果问题一直出现，请退出并保留「Backups」文件夹。")
        }
        return (diskFull ? "The disk is full. " : "") + "PaperDeck couldn't open or upgrade the library database, so it stopped rather than risk your library.\n\nNothing was deleted. The copies saved before each upgrade are in the Backups folder. "
            + (diskFull ? "Free up some disk space, then click Retry." : "Click Retry to try again; if this keeps happening, quit and keep the Backups folder.")
    }
    static var showInFinder: String { zh ? "在 Finder 中显示" : "Show in Finder" }
    static func launchButton(_ b: LaunchAlert.Button) -> String {
        switch b {
        case .useAlternative: useAlternativeLibrary
        case .retry: retry
        case .quit: quit
        case .showBackups: showBackups
        case .showFolder: showInFinder
        }
    }
    static var showBackups: String { zh ? "显示备份" : "Show Backups" }

    /// A file or storage size, worded in the UI language (`lang`), never the system's: every
    /// size the app shows (sidebar footer, Settings ▸ Library, the detail's facts, the bytes sent
    /// to AI) goes through here. `ByteCountFormatter` follows the system language and spells
    /// zero out ("Zero KB" in a Chinese window); this says `0 bytes` / `0字节`.
    static func bytes(_ n: Int64, lang: UILang? = nil) -> String {
        let l = lang ?? self.lang
        return max(0, n).formatted(.byteCount(style: .file, spellsOutZero: false)
            .locale(Locale(identifier: l == .zh ? "zh_CN" : "en_US")))
    }
}
