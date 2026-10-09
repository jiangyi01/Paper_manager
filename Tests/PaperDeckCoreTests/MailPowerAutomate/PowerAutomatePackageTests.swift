import Foundation
import Testing
@testable import PaperDeckCore

@Suite("Mail · Power Automate package") struct PowerAutomatePackageTests {

    private typealias PA = PowerAutomatePackage
    private static let senders = ["Prof.X@wustl.edu", "\"Lab Bot\" <lab-bot@wustl.edu>"]

    // MARK: Helpers

    private static func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func dict(_ any: Any?) throws -> [String: Any] { try #require(any as? [String: Any]) }

    private static func flowDir(_ files: [String: Data]) throws -> String {
        let def = try #require(files.keys.first { $0.hasSuffix("/definition.json") })
        return String(def.dropLast("definition.json".count))
    }

    private struct Parsed {
        let files: [String: Data]
        let dir: String
        let manifest, flows, apis, connections, definition: [String: Any]
        let properties, workflow, trigger, actions: [String: Any]
    }

    private static func parsed(senders: [String] = senders, folderPath: String = PA.defaultFolderPath,
                               flowName: String = PA.defaultFlowName) throws -> Parsed {
        let files = try PA.files(senders: senders, folderPath: folderPath, flowName: flowName)
        let dir = try flowDir(files)
        let definition = try object(files[dir + "definition.json"])
        let properties = try dict(definition["properties"])
        let workflow = try dict(properties["definition"])
        let triggers = try dict(workflow["triggers"])
        return Parsed(
            files: files, dir: dir,
            manifest: try object(files["manifest.json"]),
            flows: try object(files["Microsoft.Flow/flows/manifest.json"]),
            apis: try object(files[dir + "apisMap.json"]),
            connections: try object(files[dir + "connectionsMap.json"]),
            definition: definition, properties: properties, workflow: workflow,
            trigger: try dict(triggers[PA.triggerName]), actions: try dict(workflow["actions"])
        )
    }

    private static func uuidShaped(_ s: String) -> Bool {
        s.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    private final class TempDir {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-flowpkg-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    // MARK: File set and JSON

    @Test func fileSetMatchesTheLegacyExportLayout() throws {
        let p = try Self.parsed()
        let id = String(p.dir.dropFirst("Microsoft.Flow/flows/".count).dropLast())
        #expect(Self.uuidShaped(id))
        #expect(Set(p.files.keys) == [
            "manifest.json",
            "Microsoft.Flow/flows/manifest.json",
            "Microsoft.Flow/flows/\(id)/apisMap.json",
            "Microsoft.Flow/flows/\(id)/connectionsMap.json",
            "Microsoft.Flow/flows/\(id)/definition.json",
        ])
        for path in p.files.keys {
            #expect(!path.hasPrefix("/") && !path.contains("\\") && !path.contains("//"))
        }
    }

    @Test func everyFileIsCompactSortedJSON() throws {
        let files = try PA.files(senders: Self.senders)
        for (path, data) in files {
            let text = try #require(String(data: data, encoding: .utf8), "\(path) is UTF-8")
            #expect(!text.contains("\\/"), "\(path): slashes are not escaped")
            #expect(!text.contains("\n"), "\(path): compact")
            // Rebuilding the parsed value and re-encoding reproduces the bytes: nothing is lost and
            // every object's keys were already in the writer's (UTF-8 byte) order.
            let parsed = try JSONSerialization.jsonObject(with: data)
            #expect(PA.encode(try Self.rebuild(parsed)) == data, "\(path) is canonical")
        }
    }

    private static func rebuild(_ any: Any) throws -> PA.JSON {
        if let d = any as? [String: Any] { return .object(try d.mapValues(rebuild)) }
        if let a = any as? [Any] { return .array(try a.map(rebuild)) }
        if let s = any as? String { return .string(s) }
        let n = try #require(any as? NSNumber)
        #expect(CFGetTypeID(n) == CFBooleanGetTypeID(), "only strings and booleans are emitted")
        return .bool(n.boolValue)
    }

    @Test func jsonWriterEscapesStrings() throws {
        typealias J = PA.JSON
        let value = J.object(["b": .string("q\"\\\n\t\u{1}/é\u{2028}"), "a": .array([.bool(true), .bool(false)])])
        let data = PA.encode(value)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":[true,false],"b":"q\"\\\n\t\u0001/é\u2028"}"#)
        let keys = PA.encode(.object(["b": .bool(true), "B": .bool(true), "10": .bool(true), "9": .bool(true), "$x": .bool(true)]))
        #expect(String(decoding: keys, as: UTF8.self) == #"{"$x":true,"10":true,"9":true,"B":true,"b":true}"#)
        let back = try Self.dict(try JSONSerialization.jsonObject(with: data))
        #expect(back["b"] as? String == "q\"\\\n\t\u{1}/é\u{2028}")
    }

    // MARK: Manifests and maps

    @Test func rootManifestDeclaresFlowApisAndConnections() throws {
        let p = try Self.parsed()
        #expect(p.manifest["schema"] as? String == "1.0")
        let details = try Self.dict(p.manifest["details"])
        #expect(details["displayName"] as? String == "PaperDeck Mail")
        for key in ["description", "createdTime", "packageTelemetryId", "creator", "sourceEnvironment"] {
            #expect(details[key] is String, "details.\(key)")
        }
        let resources = try Self.dict(p.manifest["resources"])
        #expect(resources.count == 5)

        let flowID = String(p.dir.dropFirst("Microsoft.Flow/flows/".count).dropLast())
        let flow = try Self.dict(resources[flowID])
        #expect(flow["type"] as? String == "Microsoft.Flow/flows")
        #expect(flow["hierarchy"] as? String == "Root")
        #expect(flow["configurableBy"] as? String == "User")
        #expect(flow["suggestedCreationType"] as? String == "New")
        #expect(flow["creationType"] as? String == "Existing, New, Update")
        #expect(try Self.dict(flow["details"])["displayName"] as? String == "PaperDeck Mail")
        let deps = try #require(flow["dependsOn"] as? [String])
        #expect(deps.count == 4 && Set(deps).count == 4)
        #expect(Set(deps) == Set(resources.keys).subtracting([flowID]))

        // apisMap / connectionsMap point at API and connection resources keyed like connectionReferences.
        let refs = try Self.dict(p.properties["connectionReferences"])
        #expect(Set(p.apis.keys) == ["shared_office365", "shared_onedriveforbusiness"])
        #expect(Set(p.connections.keys) == Set(p.apis.keys))
        #expect(Set(refs.keys) == Set(p.apis.keys))
        let display = ["shared_office365": "Office 365 Outlook", "shared_onedriveforbusiness": "OneDrive for Business"]
        for key in p.apis.keys {
            let apiID = try #require(p.apis[key] as? String)
            let api = try Self.dict(resources[apiID])
            #expect(api["type"] as? String == "Microsoft.PowerApps/apis")
            #expect(api["name"] as? String == key)
            #expect(api["id"] as? String == "/providers/Microsoft.PowerApps/apis/\(key)")
            #expect(api["configurableBy"] as? String == "System")
            #expect(api["suggestedCreationType"] as? String == "Existing")
            #expect(try Self.dict(api["details"])["displayName"] as? String == display[key])
            #expect((api["dependsOn"] as? [String])?.isEmpty == true)

            let connID = try #require(p.connections[key] as? String)
            let conn = try Self.dict(resources[connID])
            #expect(conn["type"] as? String == "Microsoft.PowerApps/apis/connections")
            #expect(conn["configurableBy"] as? String == "User")
            #expect(conn["hierarchy"] as? String == "Child")
            #expect(conn["suggestedCreationType"] as? String == "Existing")
            #expect(conn["dependsOn"] as? [String] == [apiID])

            let ref = try Self.dict(refs[key])
            #expect(ref["id"] as? String == "/providers/Microsoft.PowerApps/apis/\(key)")
            #expect(ref["source"] as? String == "Embedded")
            #expect((ref["connectionName"] as? String)?.hasPrefix("shared-") == true)
        }

        #expect(p.flows["packageSchemaVersion"] as? String == "1.0")
        #expect(try Self.dict(p.flows["flowAssets"])["assetPaths"] as? [String] == [flowID])
    }

    // MARK: Flow definition

    @Test func definitionHasTriggerExportAndCreateFile() throws {
        let p = try Self.parsed()
        #expect(p.definition["type"] as? String == "Microsoft.Flow/flows")
        let name = try #require(p.definition["name"] as? String)
        #expect(Self.uuidShaped(name))
        #expect(p.definition["id"] as? String == "/providers/Microsoft.Flow/flows/\(name)")
        #expect(p.properties["apiId"] as? String == "/providers/Microsoft.PowerApps/apis/shared_logicflows")
        #expect(p.properties["displayName"] as? String == "PaperDeck Mail")
        #expect(p.properties["isManaged"] as? Bool == false)
        #expect((p.workflow["$schema"] as? String)?.hasSuffix("/2016-06-01/workflowdefinition.json#") == true)
        #expect(p.workflow["contentVersion"] as? String == "1.0.0.0")
        let params = try Self.dict(p.workflow["parameters"])
        #expect(try Self.dict(params["$connections"])["type"] as? String == "Object")
        #expect(try Self.dict(params["$authentication"])["type"] as? String == "SecureObject")

        // Trigger: When a new email arrives (V3)
        #expect(try Self.dict(p.workflow["triggers"]).count == 1)
        #expect(p.trigger["type"] as? String == "OpenApiConnectionNotification")
        #expect(p.trigger["splitOn"] as? String == "@triggerOutputs()?['body/value']")
        let tIn = try Self.dict(p.trigger["inputs"])
        let tHost = try Self.dict(tIn["host"])
        #expect(tHost["apiId"] as? String == "/providers/Microsoft.PowerApps/apis/shared_office365")
        #expect(tHost["connectionName"] as? String == "shared_office365")
        #expect(tHost["operationId"] as? String == "OnNewEmailV3")
        #expect(tIn["authentication"] as? String == "@parameters('$authentication')")
        let tParams = try Self.dict(tIn["parameters"])
        #expect(tParams["folderPath"] as? String == "Inbox")
        #expect(tParams["importance"] as? String == "Any")
        #expect(tParams["includeAttachments"] as? Bool == false)
        #expect(tParams["fetchOnlyWithAttachment"] as? Bool == false)
        #expect(tParams["from"] as? String == "lab-bot@wustl.edu;prof.x@wustl.edu")
        #expect(Set(tParams.keys) == ["folderPath", "importance", "includeAttachments", "fetchOnlyWithAttachment", "from"])

        // Actions
        #expect(Set(p.actions.keys) == ["Export_email_(V2)", "Create_file"])
        let export = try Self.dict(p.actions["Export_email_(V2)"])
        #expect(export["type"] as? String == "OpenApiConnection")
        #expect(try Self.dict(export["runAfter"]).isEmpty)
        let eIn = try Self.dict(export["inputs"])
        let eHost = try Self.dict(eIn["host"])
        #expect(eHost["operationId"] as? String == "ExportEmail_V2")
        #expect(eHost["connectionName"] as? String == "shared_office365")
        #expect(eHost["apiId"] as? String == "/providers/Microsoft.PowerApps/apis/shared_office365")
        #expect(try Self.dict(eIn["parameters"]) as NSDictionary == ["messageId": "@triggerOutputs()?['body/id']"])

        let create = try Self.dict(p.actions["Create_file"])
        #expect(create["type"] as? String == "OpenApiConnection")
        #expect(try Self.dict(create["runAfter"])["Export_email_(V2)"] as? [String] == ["Succeeded"])
        let cIn = try Self.dict(create["inputs"])
        let cHost = try Self.dict(cIn["host"])
        #expect(cHost["operationId"] as? String == "CreateFile")
        #expect(cHost["connectionName"] as? String == "shared_onedriveforbusiness")
        #expect(cHost["apiId"] as? String == "/providers/Microsoft.PowerApps/apis/shared_onedriveforbusiness")
        #expect(cIn["authentication"] as? String == "@parameters('$authentication')")
        #expect(try Self.dict(cIn["parameters"]) as NSDictionary == [
            "folderPath": "/PaperDeck Mail",
            "name": "@concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',guid(),'.eml')",
            "body": "@body('Export_email_(V2)')",
        ])
        let transfer = try Self.dict(try Self.dict(create["runtimeConfiguration"])["contentTransfer"])
        #expect(transfer["transferMode"] as? String == "Chunked")
    }

    @Test func expressionConstants() {
        #expect(PA.fileNameExpression == "@concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',guid(),'.eml')")
        #expect(PA.messageIdExpression == "@triggerOutputs()?['body/id']")
        #expect(PA.exportBodyExpression == "@body('\(PA.exportActionName)')")   // must name the Export action
        #expect(PA.triggerName == "When_a_new_email_arrives_(V3)")
    }

    // MARK: Sender filter

    @Test func fromFilterJoinsExactAddresses() {
        #expect(PA.fromFilter(["b@x.org", "A@X.org", " a@x.org ", "Name <c@y.edu>", "mailto:d@z.com"])
                == "a@x.org;b@x.org;c@y.edu;d@z.com")
        #expect(PA.fromFilter(["me+papers@wustl.edu"]) == "me+papers@wustl.edu")      // literal, tag kept
        #expect(PA.fromFilter(["prof@wustl.edu", "not an address", ""]) == "prof@wustl.edu")
    }

    @Test func domainRulesOrEmptyListMeanAllSenders() throws {
        #expect(PA.fromFilter([]) == "")
        #expect(PA.fromFilter(["prof@wustl.edu", "@biorxiv.org"]) == "")
        #expect(PA.fromFilter(["@*.nature.com"]) == "")
        #expect(PA.fromFilter(["garbage", "also garbage"]) == "")

        let plan = PA.senderPlan(["Prof@wustl.edu", "@biorxiv.org", "@*.Nature.com", "biorxiv.org", "??"])
        #expect(plan.addresses == ["prof@wustl.edu"])
        #expect(plan.domainRules == ["@biorxiv.org", "@*.nature.com"])
        #expect(plan.ignored == ["??"])
        #expect(plan.allSenders && plan.fromFilter.isEmpty)

        // All-senders variant: the trigger has no "from" parameter at all.
        let p = try Self.parsed(senders: ["prof@wustl.edu", "@biorxiv.org"])
        let params = try Self.dict(try Self.dict(p.trigger["inputs"])["parameters"])
        #expect(params["from"] == nil)
        #expect(params["folderPath"] as? String == "Inbox")
        #expect((try Self.dict(p.manifest["details"])["description"] as? String)?.contains("all senders") == true)
    }

    @Test func sendersFromRulesUsesEnabledPatterns() {
        let rules = [
            SenderRule(id: "a", pattern: "prof@wustl.edu", kind: .advisor),
            SenderRule(id: "b", pattern: "@biorxiv.org", kind: .alert, enabled: false),
            SenderRule(id: "c", pattern: "scholaralerts-noreply@google.com", kind: .alert),
        ]
        #expect(PA.senders(from: rules) == ["prof@wustl.edu", "scholaralerts-noreply@google.com"])
        #expect(PA.fromFilter(PA.senders(from: rules)) == "prof@wustl.edu;scholaralerts-noreply@google.com")
        #expect(PA.fromFilter(PA.senders(from: SenderRule.presets)) == "")          // presets include domains
    }

    // MARK: Inputs

    @Test func folderPathIsNormalized() throws {
        #expect(try PA.normalizedFolderPath("PaperDeck Mail/") == "/PaperDeck Mail")
        #expect(try PA.normalizedFolderPath(" /Apps//PaperDeck\\Inbox ") == "/Apps/PaperDeck/Inbox")
        for bad in ["", "/", " // ", "/a/../b", "/a:b", "/what?", "/x@{y}", "/tab\there"] {
            #expect(throws: PA.PackageError.self, "\(bad)") { try PA.normalizedFolderPath(bad) }
        }
        let p = try Self.parsed(folderPath: "Research/Mail In")
        let params = try Self.dict(try Self.dict(try Self.dict(p.actions["Create_file"])["inputs"])["parameters"])
        #expect(params["folderPath"] as? String == "/Research/Mail In")
    }

    @Test func invalidFlowNameThrows() {
        #expect(throws: PA.PackageError.invalidFlowName) { try PA.files(senders: [], flowName: "  ") }
        #expect(throws: PA.PackageError.invalidFlowName) { try PA.files(senders: [], flowName: "a\u{7}b") }
    }

    // MARK: Stability

    @Test func idsAreStablePerFlowNameAndIndependentOfSenders() throws {
        let a = try Self.parsed(senders: ["a@x.org"])
        let b = try Self.parsed(senders: ["@biorxiv.org"])
        let c = try Self.parsed(flowName: "PaperDeck Mail (Gmail)")
        #expect(a.dir == b.dir)
        #expect(a.definition["name"] as? String == b.definition["name"] as? String)
        #expect(a.apis as NSDictionary == b.apis as NSDictionary)
        #expect(a.connections as NSDictionary == b.connections as NSDictionary)
        #expect(a.dir != c.dir)
        #expect(a.definition["name"] as? String != c.definition["name"] as? String)
        #expect(c.properties["displayName"] as? String == "PaperDeck Mail (Gmail)")
        #expect(PA.stableUUID("x", "r") == PA.stableUUID("x", "r"))
        #expect(Self.uuidShaped(PA.stableUUID("x", "r")))
        let ids = PA.IDs(flowName: "PaperDeck Mail")
        let all = [ids.flowResource, ids.flowName, ids.telemetry, ids.outlookAPI, ids.outlookConnection,
                   ids.oneDriveAPI, ids.oneDriveConnection]
        #expect(Set(all).count == all.count)
    }

    @Test func zipIsByteStable() throws {
        let one = try PA.zipData(senders: Self.senders)
        let two = try PA.zipData(senders: Array(Self.senders.reversed()))   // sender order doesn't matter
        #expect(one == two)
        #expect(one.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(try PA.zipData(senders: ["other@x.org"]) != one)
    }

    // MARK: ZIP

    @Test func crc32KnownVectors() {
        #expect(PA.ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(PA.ZipWriter.crc32(Data()) == 0)
        #expect(PA.ZipWriter.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test func zipStructureIsWellFormed() throws {
        let entries = try PA.orderedFiles(senders: Self.senders, folderPath: PA.defaultFolderPath, flowName: PA.defaultFlowName)
        let zip = [UInt8](try PA.ZipWriter.archive(entries))
        func u16(_ o: Int) -> Int { Int(zip[o]) | Int(zip[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let eocd = zip.count - 22
        #expect(u32(eocd) == 0x0605_4B50)
        #expect(u16(eocd + 8) == entries.count && u16(eocd + 10) == entries.count)
        let cdSize = u32(eocd + 12), cdOffset = u32(eocd + 16)
        #expect(cdOffset + cdSize == eocd)

        var cd = cdOffset
        for (path, data) in entries {
            #expect(u32(cd) == 0x0201_4B50)
            #expect(u16(cd + 10) == 0)                                  // stored
            let crc = u32(cd + 16), size = u32(cd + 20), nameLen = u16(cd + 28), local = u32(cd + 42)
            #expect(String(decoding: zip[(cd + 46)..<(cd + 46 + nameLen)], as: UTF8.self) == path)
            #expect(crc == Int(PA.ZipWriter.crc32(data)) && size == data.count && u32(cd + 24) == data.count)
            #expect(u32(local) == 0x0403_4B50 && u32(local + 14) == crc)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            #expect(Data(zip[start..<(start + size)]) == data)
            cd += 46 + nameLen + u16(cd + 30) + u16(cd + 32)
        }
        #expect(cd == eocd)

        for bad in ["/abs.json", "a\\b.json", "a/../b.json", ""] {
            #expect(throws: PA.PackageError.invalidEntry(bad)) { try PA.ZipWriter.archive([(bad, Data())]) }
        }
    }

    @Test func zipIsReadableByUnzip() throws {
        let tmp = try TempDir()
        let out = tmp.url.appendingPathComponent(PA.suggestedFileName())
        try PA.makeZip(senders: Self.senders, into: out)
        let files = try PA.files(senders: Self.senders)

        let list = try Self.run("/usr/bin/unzip", ["-Z1", out.path])
        #expect(list.status == 0)
        let names = String(decoding: list.out, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(Set(names) == Set(files.keys) && names.count == files.count)
        #expect(names.last == "manifest.json")                         // export order: manifest last

        #expect(try Self.run("/usr/bin/unzip", ["-l", out.path]).status == 0)
        #expect(try Self.run("/usr/bin/unzip", ["-tq", out.path]).status == 0)
        for (path, data) in files {
            let r = try Self.run("/usr/bin/unzip", ["-p", out.path, path])
            #expect(r.status == 0 && r.out == data, "\(path) round-trips")
        }

        // Re-generating overwrites with identical bytes.
        let first = try Data(contentsOf: out)
        try PA.makeZip(senders: Self.senders, into: out)
        #expect(try Data(contentsOf: out) == first)
    }

    // MARK: Misc

    @Test func suggestedFileNameAndInstructions() {
        #expect(PA.suggestedFileName() == "PaperDeck-Mail-flow.zip")
        #expect(PA.suggestedFileName(flowName: "  Mail / Gmail!! ") == "Mail-Gmail-flow.zip")
        #expect(PA.suggestedFileName(flowName: "邮件") == "PaperDeck-Mail-flow.zip")
        let en = PA.importInstructions(fileName: "X.zip", lang: .en)
        #expect(en.contains("Import Package (Legacy)") && en.contains("X.zip") && en.contains("OneDrive for Business"))
        #expect(en.contains("\"PaperDeck Mail\"") && en.contains("OneDrive /PaperDeck Mail."))
        let zh = PA.importInstructions(fileName: "X.zip", lang: .zh)
        #expect(zh.contains("Import Package (Legacy)") && zh.contains("X.zip") && zh.contains("/PaperDeck Mail"))
        let custom = PA.importInstructions(fileName: "Y.zip", flowName: "Lab Mail", folderPath: "Lab/In/", lang: .en)
        #expect(custom.contains("\"Lab Mail\"") && custom.contains("OneDrive /Lab/In."))
    }
}
