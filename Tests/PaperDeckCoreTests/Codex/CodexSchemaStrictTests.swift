import Foundation
import Testing
@testable import PaperDeckCore

/// `codex exec --output-schema` sends the schema as an OpenAI strict `json_schema` response format;
/// a violation is an HTTP 400 `invalid_json_schema` for every paper. These rules are checked
/// offline so CardSchema can never drift out of strict mode.
@Suite struct CodexSchemaStrictTests {
    /// Keywords OpenAI strict mode rejects or that PaperDeck must not send (see §7: no constraints).
    private static let forbidden: Set<String> = [
        "$schema", "default", "format", "pattern", "minLength", "maxLength", "minItems", "maxItems",
        "minimum", "maximum", "patternProperties", "unevaluatedProperties", "if", "then", "else", "oneOf", "allOf", "not",
    ]
    private static let allowedTypes: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]

    /// Every problem found, as "path: message".
    private static func violations(_ node: JSONValue, path: String = "$", depth: Int = 1) -> [String] {
        guard let o = node.objectValue else { return ["\(path): schema node is not an object"] }
        var out: [String] = []
        if depth > 10 { out.append("\(path): nested deeper than 10 levels") }
        for key in o.keys where forbidden.contains(key) { out.append("\(path): forbidden keyword \(key)") }

        let types: [String]
        switch o["type"] {
        case .string(let t)?: types = [t]
        case .array(let a)?:
            types = a.compactMap(\.stringValue)
            if types.count != a.count { out.append("\(path): non-string type entry") }
            if types.count > 1, !types.contains("null") { out.append("\(path): type array must be T + null") }
            if types.count > 2 { out.append("\(path): more than one non-null type") }
        default:
            out.append("\(path): missing type")
            types = []
        }
        for t in types where !allowedTypes.contains(t) { out.append("\(path): unknown type \(t)") }

        if types.contains("object") {
            if o["additionalProperties"] != .bool(false) { out.append("\(path): additionalProperties must be false") }
            let props = o["properties"]?.objectValue ?? [:]
            if props.isEmpty { out.append("\(path): object without properties") }
            let required = o["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if Set(required) != Set(props.keys) || required.count != props.count {
                out.append("\(path): required must list every property exactly once")
            }
            for (k, v) in props { out += violations(v, path: path + "." + k, depth: depth + 1) }
        } else if o["properties"] != nil || o["required"] != nil {
            out.append("\(path): properties on a non-object")
        }
        if types.contains("array") {
            guard let items = o["items"] else { out.append("\(path): array without items"); return out }
            out += violations(items, path: path + "[]", depth: depth + 1)
        }
        if let e = o["enum"] {
            let values = e.arrayValue ?? []
            if values.isEmpty { out.append("\(path): empty enum") }
            if !types.contains("string") || values.contains(where: { $0.stringValue == nil }) {
                out.append("\(path): enum values must be strings of a string type")
            }
            if Set(values).count != values.count { out.append("\(path): duplicate enum values") }
        }
        return out
    }

    @Test func cardSchemaIsOpenAIStrict() {
        for categories in [PaperCategory.starters.map(\.name), [], ["Single-cell Omics", "  ", "__new__", "Single-cell Omics"]] {
            let schema = CardSchema.schema(categories: categories)
            #expect(Self.violations(schema) == [], "categories: \(categories)")
        }
    }

    /// Nullable fields use type arrays, and every top-level card field is required.
    @Test func nullableFieldsUseTypeArrays() {
        let schema = CardSchema.schema(categories: ["A"])
        let props = schema["properties"]?.objectValue ?? [:]
        #expect(props["extracted_metadata"]?["type"] == .array([.string("object"), .string("null")]))
        #expect(props["new_category"]?["type"] == .array([.string("object"), .string("null")]))
        let meta = props["extracted_metadata"]?["properties"]?.objectValue ?? [:]
        #expect(meta["doi"]?["type"] == .array([.string("string"), .string("null")]))
        #expect(meta["year"]?["type"] == .array([.string("integer"), .string("null")]))
        #expect(props["category"]?["enum"] == .array([.string("A"), .string("__new__")]))
    }

    /// The file handed to `--output-schema` is the same tree, compact, with no "$schema".
    @Test func schemaFileContent() throws {
        var withDialect = CardSchema.schema(categories: ["A"]).objectValue ?? [:]
        withDialect["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
        let text = ClaudeCodeProvider.schemaArgument(.object(withDialect))
        #expect(!text.contains("$schema") && !text.contains("\n"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(decoded == CardSchema.schema(categories: ["A"]))
        #expect(Self.violations(decoded) == [])
    }

    /// The checker itself catches the classic strict-mode mistakes.
    @Test func checkerFlagsViolations() {
        let optional: JSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("a")]),
            "properties": .object(["a": .object(["type": .string("string")]),
                                   "b": .object(["type": .string("string"), "format": .string("uri")])]),
        ])
        let v = Self.violations(optional)
        #expect(v.contains("$: required must list every property exactly once"))
        #expect(v.contains("$.b: forbidden keyword format"))
        let open: JSONValue = .object(["type": .string("object"), "required": .array([]), "properties": .object([:])])
        #expect(Self.violations(open).contains("$: additionalProperties must be false"))
        #expect(Self.violations(.object(["type": .string("array")])) == ["$: array without items"])
    }
}
