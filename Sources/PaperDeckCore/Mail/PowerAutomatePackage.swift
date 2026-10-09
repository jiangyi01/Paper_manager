import CryptoKit
import Foundation
import PaperDeckShared

// Ready-to-import Power Automate flow package (MAIL_DESIGN decision 2a, folder source).
//
// Instead of building the flow by hand, the user imports this .zip:
//   make.powerautomate.com ▸ My flows ▸ Import ▸ Import Package (Legacy) ▸ Upload ▸
//   Related resources: pick the "Office 365 Outlook" and "OneDrive for Business" connections ▸
//   Import ▸ open the flow ▸ Turn on.
//
// The flow (one trigger, two actions):
//   When a new email arrives (V3)  office365 / OnNewEmailV3, folder Inbox, From = exact senders
//   Export email (V2)              office365 / ExportEmail_V2, messageId = triggerOutputs()?['body/id']
//   Create file                    onedriveforbusiness / CreateFile, folderPath "/PaperDeck Mail",
//                                  name = <UTC yyyyMMdd-HHmmss>-<guid>.eml, body = body('Export_email_(V2)')
// OneDrive syncs "/PaperDeck Mail" into the work/school OneDrive root under ~/Library/CloudStorage/
// (…/PaperDeck Mail/), which FolderMailSource watches.
//
// Package layout (the legacy "Package (.zip)" export format; no top-level folder):
//   Microsoft.Flow/flows/<flowId>/apisMap.json        connection-reference key → API resource id
//   Microsoft.Flow/flows/<flowId>/connectionsMap.json connection-reference key → connection resource id
//   Microsoft.Flow/flows/<flowId>/definition.json     Microsoft.Flow/flows resource (Logic Apps definition)
//   Microsoft.Flow/flows/manifest.json                {"packageSchemaVersion":"1.0","flowAssets":{"assetPaths":[flowId]}}
//   manifest.json                                     schema 1.0: details + resources (flow, 2 APIs, 2 connections)
// Ground truth: real exports (ronan-deshays/power-automate-cloud-utility-flows, trent-hord/
// outlook-google-calendar-sync-via-json-email, Ephesoft-Labs/Semantik.Toolkit.PowerAutomate), the PnP
// sample pnp/powerplatform-samples "mail-archive-pdf" (same Export email → Create file chain), and the
// connector references on learn.microsoft.com/connectors/office365 and /onedriveforbusiness.
//
// Sender filter: the V3 trigger's From field takes exact addresses separated by ';' ("If any match,
// the trigger will run"); it can't express domain rules. Any domain/wildcard rule ("@biorxiv.org",
// "@*.nature.com") therefore switches to the all-senders variant (empty From): every Inbox mail is
// exported and PaperDeck's allowlist filters locally (non-allowlisted .eml files are removed there).
//
// Output is byte-stable: ids are derived from the flow name, JSON keys are sorted, the ZIP uses
// stored entries with a fixed timestamp. Zero dependencies (own JSON writer and ZIP writer).
package enum PowerAutomatePackage {

    package static let defaultFolderPath = "/PaperDeck Mail"
    package static let defaultFlowName = "PaperDeck Mail"

    /// Create-file name expression: UTC timestamp + a fresh GUID, so names never collide and never
    /// contain the subject (FolderMailSource only ever hashes file names anyway).
    package static let fileNameExpression = "@concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',guid(),'.eml')"
    package static let messageIdExpression = "@triggerOutputs()?['body/id']"
    package static let exportBodyExpression = "@body('Export_email_(V2)')"

    package static let triggerName = "When_a_new_email_arrives_(V3)"
    package static let exportActionName = "Export_email_(V2)"
    package static let createFileActionName = "Create_file"

    /// Connection-reference keys (also the keys of apisMap.json / connectionsMap.json).
    package static let outlookKey = "shared_office365"
    package static let oneDriveKey = "shared_onedriveforbusiness"

    package enum PackageError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidFlowName
        case invalidFolderPath(String)
        case invalidEntry(String)
        case entryTooLarge(String)

        package var description: String {
            switch self {
            case .invalidFlowName: "flow name must be 1–200 printable characters"
            case .invalidFolderPath(let p): "invalid OneDrive folder path: \(p)"
            case .invalidEntry(let p): "invalid package entry path: \(p)"
            case .entryTooLarge(let p): "package entry too large: \(p)"
            }
        }
    }

    // MARK: Public API

    /// Writes the import package to `outputURL` (atomically).
    package static func makeZip(senders: [String], folderPath: String = defaultFolderPath,
                                flowName: String = defaultFlowName, into outputURL: URL) throws {
        let data = try zipData(senders: senders, folderPath: folderPath, flowName: flowName)
        try data.write(to: outputURL, options: .atomic)
    }

    /// The package as ZIP bytes.
    package static func zipData(senders: [String], folderPath: String = defaultFolderPath,
                                flowName: String = defaultFlowName) throws -> Data {
        try ZipWriter.archive(orderedFiles(senders: senders, folderPath: folderPath, flowName: flowName))
    }

    /// Relative path → bytes of every file in the package (for tests and previews).
    package static func files(senders: [String], folderPath: String = defaultFolderPath,
                              flowName: String = defaultFlowName) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for (path, data) in try orderedFiles(senders: senders, folderPath: folderPath, flowName: flowName) {
            out[path] = data
        }
        return out
    }

    /// The V3 trigger's From value: exact addresses joined by ';', or "" (all senders) when the list
    /// is empty or contains a domain/wildcard rule the From field can't express.
    package static func fromFilter(_ senders: [String]) -> String { senderPlan(senders).fromFilter }

    /// Enabled sender-list patterns, ready for `makeZip(senders:)`.
    package static func senders(from rules: [SenderRule]) -> [String] {
        rules.filter(\.enabled).map(\.pattern)
    }

    /// How a sender list maps onto the V3 trigger (the UI shows `domainRules` / `ignored`).
    package struct SenderPlan: Equatable, Sendable {
        /// Exact addresses (lowercased, deduplicated, sorted) usable in the From field.
        package var addresses: [String]
        /// Domain / wildcard rules; any of them forces the all-senders variant.
        package var domainRules: [String]
        /// Entries that are neither an address nor a domain rule.
        package var ignored: [String]

        package var allSenders: Bool { addresses.isEmpty || !domainRules.isEmpty }
        package var fromFilter: String { allSenders ? "" : addresses.joined(separator: ";") }
    }

    package static func senderPlan(_ senders: [String]) -> SenderPlan {
        var addresses = Set<String>(), domains: [String] = [], ignored: [String] = []
        for raw in senders {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch SenderMatcher.Pattern(trimmed) {
            case .address:
                if let literal = literalAddress(trimmed) { addresses.insert(literal) } else { ignored.append(trimmed) }
            case .domain(let d):
                if !domains.contains("@" + d) { domains.append("@" + d) }
            case .wildcard(let d):
                if !domains.contains("@*." + d) { domains.append("@*." + d) }
            case nil:
                ignored.append(trimmed)
            }
        }
        return SenderPlan(addresses: addresses.sorted(), domainRules: domains, ignored: ignored)
    }

    /// Suggested download name, e.g. "PaperDeck-Mail-flow.zip".
    package static func suggestedFileName(flowName: String = defaultFlowName) -> String {
        var stem = ""
        for s in flowName.unicodeScalars {
            if s.isASCII, CharacterSet.alphanumerics.contains(s) || s == "_" { stem.unicodeScalars.append(s) }
            else if !stem.isEmpty, !stem.hasSuffix("-") { stem += "-" }
        }
        while stem.hasSuffix("-") { stem.removeLast() }
        return (stem.isEmpty ? "PaperDeck-Mail" : stem) + "-flow.zip"
    }

    /// Step-by-step import instructions (shown by the CLI and the Mail settings sheet).
    package static func importInstructions(fileName: String, flowName: String = defaultFlowName,
                                           folderPath: String = defaultFolderPath, lang: UILang) -> String {
        let folder = (try? normalizedFolderPath(folderPath)) ?? folderPath
        let flow = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
        if lang == .zh {
            return """
            1. 打开 https://make.powerautomate.com ，用学校 Microsoft 365 账号登录。
            2. 左侧「我的流」▸ 顶部「导入」▸「导入包(旧版)」（Import Package (Legacy)）。
            3. 「上传」选择 \(fileName)。
            4. 「相关资源」里点「导入时选择」（Select during import）：Office 365 Outlook 选你的邮箱连接，OneDrive for Business 选你的 OneDrive 连接（没有就点「新建」，登录后回来刷新列表），保存。
            5. 点「导入」。在「我的流」打开「\(flow)」，确认已「打开」（Turn on）。
            6. 给自己发一封测试邮件，1–5 分钟后 OneDrive 的 \(folder) 文件夹里会出现 .eml。
            """
        }
        return """
        1. Open https://make.powerautomate.com and sign in with your university Microsoft 365 account.
        2. My flows ▸ Import ▸ Import Package (Legacy).
        3. Upload \(fileName).
        4. Under Related resources, click "Select during import" for Office 365 Outlook and for OneDrive for Business and pick your connections (use "Create new" if none exist, then refresh the list). Save.
        5. Click Import. Open "\(flow)" under My flows and make sure it is turned on.
        6. Send yourself a test email; within 1–5 minutes an .eml appears in OneDrive \(folder).
        """
    }

    // MARK: Package contents

    /// Stable ids derived from the flow name.
    struct IDs {
        let flowResource, flowName, telemetry: String
        let outlookAPI, outlookConnection, oneDriveAPI, oneDriveConnection: String
        let outlookConnectionName, oneDriveConnectionName: String

        init(flowName: String) {
            func id(_ role: String) -> String { PowerAutomatePackage.stableUUID(flowName, role) }
            flowResource = id("flow-resource"); self.flowName = id("flow-name"); telemetry = id("telemetry")
            outlookAPI = id("api-office365"); outlookConnection = id("connection-office365")
            oneDriveAPI = id("api-onedriveforbusiness"); oneDriveConnection = id("connection-onedriveforbusiness")
            // Placeholder connection names in the exported shape ("shared-<api, ≤20 chars>-<guid>");
            // the importer replaces them with the connections picked under Related resources.
            outlookConnectionName = "shared-office365-" + id("connection-name-office365")
            oneDriveConnectionName = "shared-onedriveforbu-" + id("connection-name-onedriveforbusiness")
        }
    }

    static let outlookAPIId = "/providers/Microsoft.PowerApps/apis/shared_office365"
    static let oneDriveAPIId = "/providers/Microsoft.PowerApps/apis/shared_onedriveforbusiness"
    static let outlookIcon = "https://connectoricons-prod.azureedge.net/releases/v1.0.1659/1.0.1659.3460/office365/icon.png"
    static let oneDriveIcon = "https://static.powerapps.com/resource/ppcr/releases/v1.0.1814/1.0.1814.4751/onedriveforbusiness/icon.png"
    static let createdTime = "2026-01-01T00:00:00.0000000Z"   // fixed: byte-stable output

    /// Files in the order Power Automate's own exports use.
    static func orderedFiles(senders: [String], folderPath: String, flowName: String) throws -> [(String, Data)] {
        let name = try normalizedFlowName(flowName)
        let folder = try normalizedFolderPath(folderPath)
        let plan = senderPlan(senders)
        let ids = IDs(flowName: name)
        let dir = "Microsoft.Flow/flows/\(ids.flowResource)/"
        return [
            (dir + "apisMap.json", encode(apisMap(ids))),
            (dir + "connectionsMap.json", encode(connectionsMap(ids))),
            (dir + "definition.json", encode(definition(ids: ids, flowName: name, folder: folder, from: plan.fromFilter))),
            ("Microsoft.Flow/flows/manifest.json", encode(flowsManifest(ids))),
            ("manifest.json", encode(rootManifest(ids: ids, flowName: name, folder: folder, plan: plan))),
        ]
    }

    static func rootManifest(ids: IDs, flowName: String, folder: String, plan: SenderPlan) -> JSON {
        let who = plan.allSenders
            ? "all senders (PaperDeck filters locally)"
            : "\(plan.addresses.count) allowlisted sender\(plan.addresses.count == 1 ? "" : "s")"
        func api(_ id: String, _ name: String, _ display: String, _ icon: String) -> JSON {
            .object([
                "id": .string(id), "name": .string(name), "type": .string("Microsoft.PowerApps/apis"),
                "suggestedCreationType": .string("Existing"),
                "details": .object(["displayName": .string(display), "iconUri": .string(icon)]),
                "configurableBy": .string("System"), "hierarchy": .string("Child"), "dependsOn": .array([]),
            ])
        }
        func connection(_ display: String, _ icon: String, dependsOn apiResource: String) -> JSON {
            .object([
                "type": .string("Microsoft.PowerApps/apis/connections"),
                "suggestedCreationType": .string("Existing"), "creationType": .string("Existing"),
                "details": .object(["displayName": .string(display), "iconUri": .string(icon)]),
                "configurableBy": .string("User"), "hierarchy": .string("Child"),
                "dependsOn": .array([.string(apiResource)]),
            ])
        }
        return .object([
            "schema": .string("1.0"),
            "details": .object([
                "displayName": .string(flowName),
                "description": .string("PaperDeck: saves new Inbox emails from \(who) as .eml files in OneDrive \(folder)."),
                "createdTime": .string(createdTime),
                "packageTelemetryId": .string(ids.telemetry),
                "creator": .string("PaperDeck"),
                "sourceEnvironment": .string(""),
            ]),
            "resources": .object([
                ids.flowResource: .object([
                    "type": .string("Microsoft.Flow/flows"),
                    "suggestedCreationType": .string("New"),
                    "creationType": .string("Existing, New, Update"),
                    "details": .object(["displayName": .string(flowName)]),
                    "configurableBy": .string("User"), "hierarchy": .string("Root"),
                    "dependsOn": .array([ids.outlookAPI, ids.outlookConnection, ids.oneDriveAPI, ids.oneDriveConnection].map(JSON.string)),
                ]),
                ids.outlookAPI: api(outlookAPIId, outlookKey, "Office 365 Outlook", outlookIcon),
                ids.outlookConnection: connection("Office 365 Outlook", outlookIcon, dependsOn: ids.outlookAPI),
                ids.oneDriveAPI: api(oneDriveAPIId, oneDriveKey, "OneDrive for Business", oneDriveIcon),
                ids.oneDriveConnection: connection("OneDrive for Business", oneDriveIcon, dependsOn: ids.oneDriveAPI),
            ]),
        ])
    }

    static func flowsManifest(_ ids: IDs) -> JSON {
        .object([
            "packageSchemaVersion": .string("1.0"),
            "flowAssets": .object(["assetPaths": .array([.string(ids.flowResource)])]),
        ])
    }

    static func apisMap(_ ids: IDs) -> JSON {
        .object([outlookKey: .string(ids.outlookAPI), oneDriveKey: .string(ids.oneDriveAPI)])
    }

    static func connectionsMap(_ ids: IDs) -> JSON {
        .object([outlookKey: .string(ids.outlookConnection), oneDriveKey: .string(ids.oneDriveConnection)])
    }

    static func definition(ids: IDs, flowName: String, folder: String, from: String) -> JSON {
        let auth = JSON.string("@parameters('$authentication')")
        func host(_ apiId: String, _ key: String, _ op: String) -> JSON {
            .object(["apiId": .string(apiId), "connectionName": .string(key), "operationId": .string(op)])
        }
        var triggerParams: [String: JSON] = [
            "folderPath": .string("Inbox"),
            "importance": .string("Any"),
            "fetchOnlyWithAttachment": .bool(false),
            "includeAttachments": .bool(false),
        ]
        if !from.isEmpty { triggerParams["from"] = .string(from) }

        let trigger = JSON.object([
            "type": .string("OpenApiConnectionNotification"),
            "splitOn": .string("@triggerOutputs()?['body/value']"),
            "inputs": .object([
                "host": host(outlookAPIId, outlookKey, "OnNewEmailV3"),
                "parameters": .object(triggerParams),
                "authentication": auth,
            ]),
        ])
        let export = JSON.object([
            "runAfter": .object([:]),
            "type": .string("OpenApiConnection"),
            "inputs": .object([
                "host": host(outlookAPIId, outlookKey, "ExportEmail_V2"),
                "parameters": .object(["messageId": .string(messageIdExpression)]),
                "authentication": auth,
            ]),
        ])
        let create = JSON.object([
            "runAfter": .object([exportActionName: .array([.string("Succeeded")])]),
            "type": .string("OpenApiConnection"),
            "inputs": .object([
                "host": host(oneDriveAPIId, oneDriveKey, "CreateFile"),
                "parameters": .object([
                    "folderPath": .string(folder),
                    "name": .string(fileNameExpression),
                    "body": .string(exportBodyExpression),
                ]),
                "authentication": auth,
            ]),
            // What the designer adds to OneDrive "Create file": large exports (big attachments) upload in chunks.
            "runtimeConfiguration": .object(["contentTransfer": .object(["transferMode": .string("Chunked")])]),
        ])
        func reference(_ connectionName: String, _ apiId: String, _ apiName: String) -> JSON {
            .object([
                "connectionName": .string(connectionName), "source": .string("Embedded"),
                "id": .string(apiId), "tier": .string("NotSpecified"), "apiName": .string(apiName),
            ])
        }
        return .object([
            "name": .string(ids.flowName),
            "id": .string("/providers/Microsoft.Flow/flows/\(ids.flowName)"),
            "type": .string("Microsoft.Flow/flows"),
            "properties": .object([
                "apiId": .string("/providers/Microsoft.PowerApps/apis/shared_logicflows"),
                "displayName": .string(flowName),
                "definition": .object([
                    "$schema": .string("https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"),
                    "contentVersion": .string("1.0.0.0"),
                    "parameters": .object([
                        "$connections": .object(["defaultValue": .object([:]), "type": .string("Object")]),
                        "$authentication": .object(["defaultValue": .object([:]), "type": .string("SecureObject")]),
                    ]),
                    "triggers": .object([triggerName: trigger]),
                    "actions": .object([exportActionName: export, createFileActionName: create]),
                    "outputs": .object([:]),
                ]),
                "connectionReferences": .object([
                    outlookKey: reference(ids.outlookConnectionName, outlookAPIId, "office365"),
                    oneDriveKey: reference(ids.oneDriveConnectionName, oneDriveAPIId, "onedriveforbusiness"),
                ]),
                "flowFailureAlertSubscribed": .bool(false),
                "isManaged": .bool(false),
            ]),
        ])
    }

    // MARK: Input normalization

    static func normalizedFlowName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw PackageError.invalidFlowName }
        return name
    }

    /// "PaperDeck Mail/" → "/PaperDeck Mail". Rejects the root, "."/"..", characters OneDrive
    /// disallows in names, and "@{" (workflow-expression interpolation).
    static func normalizedFolderPath(_ raw: String) throws -> String {
        let segments = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let forbidden = CharacterSet(charactersIn: "\"*:<>?|").union(.controlCharacters)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: forbidden) == nil })
        else { throw PackageError.invalidFolderPath(raw) }
        let path = "/" + segments.joined(separator: "/")
        guard !path.contains("@{"), path.count <= 400 else { throw PackageError.invalidFolderPath(raw) }
        return path
    }

    /// The address as written (lowercased, display name / angle brackets / mailto: removed), keeping any
    /// "+tag" because the From filter compares the literal sender address.
    static func literalAddress(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s = String(s[s.index(after: open)..<close])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
        if s.hasPrefix("mailto:") { s = String(s.dropFirst(7)) }
        while s.hasSuffix(".") { s.removeLast() }
        let bad = CharacterSet(charactersIn: ";,\"<>()[]\\ ").union(.whitespacesAndNewlines).union(.controlCharacters)
        guard let at = s.lastIndex(of: "@"), at != s.startIndex, s.index(after: at) != s.endIndex,
              s.rangeOfCharacter(from: bad) == nil, s.count <= 254 else { return nil }
        return s
    }

    /// Name-based, version-4-shaped UUID: SHA-256("paperdeck.powerautomate/1", flowName, role).
    static func stableUUID(_ flowName: String, _ role: String) -> String {
        let digest = SHA256.hash(data: Data("paperdeck.powerautomate/1\u{0}\(flowName)\u{0}\(role)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(c[$0]) }.joined(separator: "-")
    }

    // MARK: Deterministic JSON

    /// Minimal JSON value; serialized compactly with keys sorted by UTF-8 bytes, "/" not escaped.
    indirect enum JSON: Equatable, Sendable {
        case string(String), bool(Bool), array([JSON]), object([String: JSON])

        func write(into out: inout String) {
            switch self {
            case .string(let s): JSON.quote(s, into: &out)
            case .bool(let b): out += b ? "true" : "false"
            case .array(let items):
                out += "["
                for (i, item) in items.enumerated() {
                    if i > 0 { out += "," }
                    item.write(into: &out)
                }
                out += "]"
            case .object(let members):
                out += "{"
                for (i, key) in members.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).enumerated() {
                    if i > 0 { out += "," }
                    JSON.quote(key, into: &out)
                    out += ":"
                    members[key]!.write(into: &out)
                }
                out += "}"
            }
        }

        static func quote(_ s: String, into out: inout String) {
            out += "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{2028}", "\u{2029}": out += String(format: "\\u%04x", scalar.value)
                default:
                    if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                    else { out.unicodeScalars.append(scalar) }
                }
            }
            out += "\""
        }
    }

    static func encode(_ value: JSON) -> Data {
        var s = ""
        value.write(into: &s)
        return Data(s.utf8)
    }

    // MARK: ZIP writer (stored entries, no compression)

    /// PKWARE APPNOTE: local file headers + central directory + end of central directory. Entries are
    /// stored (method 0) with a CRC-32, a fixed DOS timestamp (2026-01-01 00:00) and no extra fields,
    /// no directory entries, forward-slash paths — the shape of Power Automate's own exports.
    enum ZipWriter {
        static let dosTime: UInt16 = 0
        static let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 1 << 5 | 1)

        static func archive(_ entries: [(String, Data)]) throws -> Data {
            var out = Bytes(), central = Bytes()
            guard entries.count < 0xFFFF else { throw PackageError.entryTooLarge("\(entries.count) entries") }
            for (path, data) in entries {
                let name = Array(path.utf8)
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                      !path.split(separator: "/").contains(".."), name.count < 0xFFFF
                else { throw PackageError.invalidEntry(path) }
                guard data.count < 0xFFFF_FFFF, out.count < 0xFFFF_FFFF else { throw PackageError.entryTooLarge(path) }
                let crc = crc32(data), size = UInt32(data.count), offset = UInt32(out.count)
                let flags: UInt16 = path.utf8.contains { $0 >= 0x80 } ? 0x0800 : 0   // bit 11: UTF-8 name

                out.u32(0x0403_4B50)
                out.u16(20); out.u16(flags); out.u16(0)            // version needed, flags, method: stored
                out.u16(dosTime); out.u16(dosDate)
                out.u32(crc); out.u32(size); out.u32(size)
                out.u16(UInt16(name.count)); out.u16(0)            // name length, extra length
                out.bytes += name
                out.bytes += data

                central.u32(0x0201_4B50)
                central.u16(20); central.u16(20)                   // made by (MS-DOS, 2.0), needed
                central.u16(flags); central.u16(0)
                central.u16(dosTime); central.u16(dosDate)
                central.u32(crc); central.u32(size); central.u32(size)
                central.u16(UInt16(name.count)); central.u16(0); central.u16(0)   // name, extra, comment
                central.u16(0); central.u16(0); central.u32(0)     // disk, internal attrs, external attrs
                central.u32(offset)
                central.bytes += name
            }
            guard out.count + central.count < 0xFFFF_FFFF else { throw PackageError.entryTooLarge("archive") }
            let cdOffset = UInt32(out.count), cdSize = UInt32(central.count)
            out.bytes += central.bytes
            out.u32(0x0605_4B50)
            out.u16(0); out.u16(0)                                 // this disk, central-directory disk
            out.u16(UInt16(entries.count)); out.u16(UInt16(entries.count))
            out.u32(cdSize); out.u32(cdOffset)
            out.u16(0)                                             // comment length
            return Data(out.bytes)
        }

        struct Bytes {
            var bytes: [UInt8] = []
            var count: Int { bytes.count }
            mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
            mutating func u32(_ v: UInt32) {
                bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
            }
        }

        static let crcTable: [UInt32] = (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }

        /// CRC-32 (IEEE 802.3, reflected, as used by ZIP).
        static func crc32(_ data: Data) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFF_FFFF
        }
    }
}
