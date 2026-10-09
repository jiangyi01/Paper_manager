import Foundation

/// Tolerant HTML → plain text for mail bodies (MAIL_DESIGN Part A §2 "Local extraction" 1).
///
/// A small hand-written tokenizer — no WebKit, no `NSAttributedString(html:)` (which needs the
/// main thread). `<style>`, `<script>`, `<head>`, comments and hidden elements (preheaders,
/// `display:none`, `mso-hide:all`…) are dropped, block elements become line breaks, entities
/// are decoded and whitespace is collapsed. Anchors are kept as `(href, text)` in document order.
/// Mail HTML is untrusted: nothing here fetches, evaluates or follows anything.
package enum HTMLText {

    package enum Token: Sendable, Equatable {
        case start(name: String, attributes: [String: String], selfClosing: Bool)
        case end(name: String)
        case text(String)                    // entity-decoded, whitespace as in the source
    }

    package struct Anchor: Sendable, Equatable {
        package var href: String             // entity-decoded, trimmed (not unwrapped)
        package var text: String             // collapsed visible text (img alt when there is none)
        package var classes: [String]
        package init(href: String, text: String, classes: [String] = []) {
            self.href = href; self.text = text; self.classes = classes
        }
    }

    package struct Output: Sendable, Equatable {
        package var text: String
        package var anchors: [Anchor]
    }

    /// Private-use delimiters of anchor markers (`markAnchors`). Text nodes never contain them:
    /// the converter strips both characters from the input, so markers cannot be forged.
    package static let markerOpen: Unicode.Scalar = "\u{E000}"
    package static let markerClose: Unicode.Scalar = "\u{E001}"

    package static func marker(_ index: Int) -> String {
        String(Character(markerOpen)) + String(index) + String(Character(markerClose))
    }

    /// Longer inputs are truncated (mail HTML beyond this is junk or hostile).
    package static let maxInputScalars = 4_000_000

    // MARK: - Public entry points

    /// Visible text only.
    package static func text(_ html: String) -> String { convert(html).text }

    /// Visible text plus anchors. With `markAnchors`, every recorded anchor is followed by
    /// `marker(i)` (i = index into `anchors`); anchors whose text is itself a URL emit only the
    /// marker, so no raw (possibly wrapped/tracking) URL survives in the text.
    package static func convert(_ html: String, markAnchors: Bool = false) -> Output {
        var r = Renderer(markAnchors: markAnchors)
        for token in tokenize(html) { r.consume(token) }
        return r.finish()
    }

    // MARK: - Tokenizer

    private static let rawTextElements: Set<String> = ["script", "style", "title", "textarea", "xmp", "noembed", "noframes"]

    package static func tokenize(_ html: String) -> [Token] {
        let s = Array(html.unicodeScalars.prefix(maxInputScalars))
        let n = s.count
        var tokens: [Token] = []
        var text = String.UnicodeScalarView()
        var i = 0

        func flushText() {
            guard !text.isEmpty else { return }
            tokens.append(.text(decodeEntities(String(text))))
            text = String.UnicodeScalarView()
        }
        func isLetter(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
        }
        func hasPrefix(_ p: String, at k: Int) -> Bool {
            var j = k
            for pc in p.unicodeScalars {
                guard j < n else { return false }
                let c = s[j]
                let lower = (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c
                if lower != pc { return false }
                j += 1
            }
            return true
        }
        func find(_ p: String, from k: Int) -> Int? {
            let ps = Array(p.unicodeScalars)
            guard !ps.isEmpty else { return k }
            var j = k
            while j + ps.count <= n {
                if s[j] == ps[0] || (ps[0] >= "a" && ps[0] <= "z" && s[j].value == ps[0].value - 32) {
                    if hasPrefix(p, at: j) { return j }
                }
                j += 1
            }
            return nil
        }

        while i < n {
            let c = s[i]
            guard c == "<", i + 1 < n else { text.append(c); i += 1; continue }
            let next = s[i + 1]
            if hasPrefix("<!--", at: i) {
                flushText()
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                continue
            }
            if hasPrefix("<![cdata[", at: i) {
                flushText()
                let end = find("]]>", from: i + 9) ?? n
                tokens.append(.text(String(String.UnicodeScalarView(s[(i + 9)..<end]))))
                i = min(n, end + 3)
                continue
            }
            if next == "!" || next == "?" {
                flushText()
                var j = i + 2
                while j < n, s[j] != ">" { j += 1 }
                i = j + 1
                continue
            }
            if next == "/" {
                guard i + 2 < n, isLetter(s[i + 2]) else {
                    // "</" not followed by a name: bogus comment up to ">"
                    flushText()
                    var j = i + 2
                    while j < n, s[j] != ">" { j += 1 }
                    i = j + 1
                    continue
                }
                flushText()
                var j = i + 2
                var name = String.UnicodeScalarView()
                while j < n, !isSpace(s[j]), s[j] != ">", s[j] != "/" { name.append(s[j]); j += 1 }
                while j < n, s[j] != ">" { j += 1 }
                tokens.append(.end(name: String(name).lowercased()))
                i = j + 1
                continue
            }
            guard isLetter(next) else { text.append(c); i += 1; continue }

            // Start tag
            flushText()
            var j = i + 1
            var nameView = String.UnicodeScalarView()
            while j < n, !isSpace(s[j]), s[j] != ">", s[j] != "/" { nameView.append(s[j]); j += 1 }
            let name = String(nameView).lowercased()
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < n {
                while j < n, isSpace(s[j]) { j += 1 }
                guard j < n else { break }
                if s[j] == ">" { j += 1; break }
                if s[j] == "/" {
                    if j + 1 < n, s[j + 1] == ">" { selfClosing = true; j += 2; break }
                    j += 1; continue
                }
                var an = String.UnicodeScalarView()
                while j < n, !isSpace(s[j]), s[j] != "=", s[j] != ">", !(s[j] == "/" && j + 1 < n && s[j + 1] == ">") {
                    an.append(s[j]); j += 1
                }
                while j < n, isSpace(s[j]) { j += 1 }
                var value = ""
                if j < n, s[j] == "=" {
                    j += 1
                    while j < n, isSpace(s[j]) { j += 1 }
                    if j < n, s[j] == "\"" || s[j] == "'" {
                        let q = s[j]
                        j += 1
                        var v = String.UnicodeScalarView()
                        while j < n, s[j] != q { v.append(s[j]); j += 1 }
                        j += 1
                        value = String(v)
                    } else {
                        var v = String.UnicodeScalarView()
                        while j < n, !isSpace(s[j]), s[j] != ">" { v.append(s[j]); j += 1 }
                        value = String(v)
                    }
                }
                let key = String(an).lowercased()
                if !key.isEmpty, attrs[key] == nil { attrs[key] = decodeEntities(value) }
            }
            tokens.append(.start(name: name, attributes: attrs, selfClosing: selfClosing))
            i = j

            if rawTextElements.contains(name), !selfClosing {
                let end = find("</" + name, from: i) ?? n
                if name == "title" || name == "textarea" {
                    let raw = String(String.UnicodeScalarView(s[i..<end]))
                    if !raw.isEmpty { tokens.append(.text(decodeEntities(raw))) }
                }
                var k = end
                while k < n, s[k] != ">" { k += 1 }
                tokens.append(.end(name: name))
                i = min(n, k + 1)
            }
        }
        flushText()
        return tokens
    }

    // MARK: - Visibility

    private static let hiddenClasses: Set<String> = ["preheader", "preview-text", "previewtext", "hidden", "mso-hide"]

    /// Elements a mail client would not show: preheaders, `display:none`, Outlook-only copies…
    package static func isHidden(_ attributes: [String: String]) -> Bool {
        if attributes["hidden"] != nil { return true }
        if let cls = attributes["class"] {
            let parts = cls.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            if parts.contains(where: { hiddenClasses.contains(String($0)) }) { return true }
        }
        guard let raw = attributes["style"] else { return false }
        let style = String(raw.lowercased().unicodeScalars.filter { !isSpace($0) }.map(Character.init))
        if style.contains("display:none") || style.contains("visibility:hidden") || style.contains("mso-hide:all") {
            return true
        }
        if style.contains("opacity:0;") || style.hasSuffix("opacity:0") { return true }
        // (font-size:0 alone is not "hidden": responsive templates use it on wrappers and reset it in children.)
        if style.range(of: #"(^|;)(max-)?height:0(px)?(;|$|!)"#, options: .regularExpression) != nil,
           style.contains("overflow:hidden") { return true }
        return false
    }

    // MARK: - Renderer

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "table", "hr", "dl", "figure",
    ]
    private static let lineElements: Set<String> = [
        "div", "li", "tr", "br", "dt", "dd", "section", "article", "header", "footer", "main", "nav", "aside",
        "center", "form", "address", "figcaption", "fieldset", "details", "summary", "tbody", "thead", "tfoot",
        "caption", "option", "legend", "hgroup", "menu",
    ]
    private static let droppedElements: Set<String> = [
        "head", "script", "style", "title", "template", "svg", "math", "object", "iframe", "noembed", "noframes",
        "select", "button", "audio", "video", "canvas", "map",
    ]
    /// A new block start implicitly closes an open `<p>` (HTML parsing rules, simplified).
    private static let closesParagraph: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "blockquote", "pre", "section",
        "article", "header", "footer", "hr", "dl", "figure", "form", "address", "center", "aside", "nav", "main",
    ]

    private struct Open {
        var name: String
        var hidden: Bool
        var anchor: Int?        // index into pending anchors
    }

    private struct PendingAnchor {
        var href: String
        var classes: [String]
        var text: String.UnicodeScalarView
        var alt: String?
        var outStart: Int
    }

    private struct Renderer {
        let markAnchors: Bool
        var out: [Unicode.Scalar] = []
        var stack: [Open] = []
        var hiddenDepth = 0
        var preDepth = 0
        var pending: [PendingAnchor] = []
        var anchors: [Anchor] = []

        init(markAnchors: Bool) { self.markAnchors = markAnchors }

        mutating func consume(_ token: Token) {
            switch token {
            case .text(let t): appendText(t)
            case .start(let name, let attrs, let selfClosing): start(name, attrs, selfClosing)
            case .end(let name): end(name)
            }
        }

        // Text

        mutating func appendText(_ t: String) {
            guard hiddenDepth == 0 else { return }
            for c in t.unicodeScalars {
                if c == HTMLText.markerOpen || c == HTMLText.markerClose || isInvisible(c) { continue }
                if preDepth > 0 {
                    if c == "\r" { continue }
                    emit(c)
                } else if isSpace(c) || c == "\u{A0}" {
                    // Collapse runs; never start a line with a space.
                    if let last = out.last, last != " ", last != "\n" { emit(" ") }
                    else if out.isEmpty { continue }
                    else if pending.last.map({ !$0.text.isEmpty && $0.text.last != " " }) == true {
                        pendingAppend(" ")
                    }
                } else {
                    emit(c)
                }
            }
        }

        mutating func emit(_ c: Unicode.Scalar) {
            out.append(c)
            pendingAppend(c)
        }

        mutating func pendingAppend(_ c: Unicode.Scalar) {
            guard !pending.isEmpty else { return }
            pending[pending.count - 1].text.append(c == "\n" ? " " : c)
        }

        mutating func newline() {
            guard hiddenDepth == 0 else { return }
            while out.last == " " { out.removeLast() }
            if !out.isEmpty, out.last != "\n" { out.append("\n") }
        }

        mutating func paragraph() {
            guard hiddenDepth == 0 else { return }
            newline()
            if !out.isEmpty, !(out.count >= 2 && out[out.count - 1] == "\n" && out[out.count - 2] == "\n") {
                out.append("\n")
            }
        }

        // Tags

        mutating func start(_ name: String, _ attrs: [String: String], _ selfClosing: Bool) {
            // Implied end tags that matter for visibility tracking.
            if HTMLText.closesParagraph.contains(name) { closeImplied("p", stopAt: ["div", "td", "th", "li", "table", "body", "blockquote"]) }
            if name == "li" { closeImplied("li", stopAt: ["ul", "ol", "menu"]) }
            if name == "td" || name == "th" { closeImplied("td", stopAt: ["tr", "table"]); closeImplied("th", stopAt: ["tr", "table"]) }
            if name == "tr" { closeImplied("tr", stopAt: ["table", "tbody", "thead", "tfoot"]) }
            if name == "a" { closeImplied("a", stopAt: []) }

            let hidden = HTMLText.droppedElements.contains(name) || HTMLText.isHidden(attrs)
            let isVoid = HTMLText.voidElements.contains(name) || selfClosing

            if name == "br" { if hiddenDepth == 0 && !hidden { out.append("\n"); pendingAppend(" ") }; return }
            if name == "img" {
                if hiddenDepth == 0, !hidden, let alt = attrs["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !alt.isEmpty, !pending.isEmpty, pending[pending.count - 1].alt == nil {
                    pending[pending.count - 1].alt = alt
                }
                return
            }
            if !hidden {
                if HTMLText.paragraphElements.contains(name) { paragraph() }
                else if HTMLText.lineElements.contains(name) { newline() }
                if name == "li", hiddenDepth == 0 { out.append(contentsOf: "• ".unicodeScalars) }
                if (name == "td" || name == "th"), hiddenDepth == 0, let last = out.last, last != " ", last != "\n" {
                    out.append(" ")
                }
            }
            guard !isVoid else { return }

            var open = Open(name: name, hidden: hidden, anchor: nil)
            if hidden { hiddenDepth += 1 }
            if name == "pre" { preDepth += 1 }
            if name == "a", hiddenDepth == 0 {
                let href = (attrs["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let classes = (attrs["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
                pending.append(PendingAnchor(href: href, classes: classes, text: String.UnicodeScalarView(),
                                             alt: attrs["title"], outStart: out.count))
                open.anchor = pending.count - 1
            }
            stack.append(open)
        }

        mutating func closeImplied(_ name: String, stopAt: Set<String>) {
            guard let idx = stack.lastIndex(where: { $0.name == name }) else { return }
            if stack[(idx + 1)...].contains(where: { stopAt.contains($0.name) }) { return }
            popTo(idx)
        }

        mutating func end(_ name: String) {
            if name == "br" { if hiddenDepth == 0 { out.append("\n") }; return }
            guard let idx = stack.lastIndex(where: { $0.name == name }) else {
                if HTMLText.paragraphElements.contains(name) { paragraph() }
                else if HTMLText.lineElements.contains(name) { newline() }
                return
            }
            popTo(idx)
        }

        mutating func popTo(_ idx: Int) {
            while stack.count > idx {
                let el = stack.removeLast()
                if el.anchor != nil { finishAnchor() }
                if el.name == "pre" { preDepth = max(0, preDepth - 1) }
                if el.hidden { hiddenDepth = max(0, hiddenDepth - 1); continue }
                if HTMLText.paragraphElements.contains(el.name) { paragraph() }
                else if HTMLText.lineElements.contains(el.name) { newline() }
                else if el.name == "td" || el.name == "th" { if let last = out.last, last != " ", last != "\n" { out.append(" ") } }
            }
        }

        mutating func finishAnchor() {
            guard let a = pending.popLast() else { return }
            var text = collapse(String(a.text))
            if text.isEmpty, let alt = a.alt { text = collapse(alt) }
            guard !a.href.isEmpty, hiddenDepth == 0 else { return }
            anchors.append(Anchor(href: a.href, text: text, classes: a.classes))
            guard markAnchors else { return }
            if looksLikeURL(text), a.outStart <= out.count {
                out.removeSubrange(a.outStart..<out.count)
            }
            if let last = out.last, last != " ", last != "\n" { out.append(" ") }
            out.append(contentsOf: HTMLText.marker(anchors.count - 1).unicodeScalars)
            // Parent anchors (invalid nesting) keep their text; markers never enter anchor text.
        }

        mutating func finish() -> Output {
            if !stack.isEmpty { popTo(0) }
            let raw = String(String.UnicodeScalarView(out))
            return Output(text: HTMLText.tidy(raw), anchors: anchors)
        }
    }

    // MARK: - Helpers

    /// Trims every line, drops trailing spaces and collapses 3+ newlines to one blank line.
    package static func tidy(_ s: String) -> String {
        var lines: [Substring] = []
        var blank = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if t.isEmpty {
                blank += 1
                if blank == 1, !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(Substring(t))
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for c in s.unicodeScalars {
            if isSpace(c) || c == "\u{A0}" { space = true; continue }
            if isInvisible(c) || c == markerOpen || c == markerClose { continue }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            out.append(c)
        }
        return String(out)
    }

    static func looksLikeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}"
    }

    /// Zero-width and formatting characters used for preheader padding and bidi tricks.
    static func isInvisible(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0x3164, 0xFFA0: return true
        default: return c.value < 0x20 && c != "\n" && c != "\t" && c != "\r"
        }
    }

    // MARK: - Entities

    /// Decodes named (HTML 4 set plus common HTML5 names) and numeric character references.
    /// Unknown names stay literal; `&amp` / `&lt` / `&gt` / `&quot` / `&nbsp` also decode without `;`.
    package static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        var out = String.UnicodeScalarView()
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            let c = scalars[i]
            guard c == "&", i + 1 < n else { out.append(c); i += 1; continue }
            if scalars[i + 1] == "#" {
                var j = i + 2
                var hex = false
                if j < n, scalars[j] == "x" || scalars[j] == "X" { hex = true; j += 1 }
                var digits = ""
                while j < n, digits.count < 8,
                      (hex ? scalars[j].properties.isASCIIHexDigit : (scalars[j] >= "0" && scalars[j] <= "9")) {
                    digits.unicodeScalars.append(scalars[j]); j += 1
                }
                guard !digits.isEmpty, let v = UInt32(digits, radix: hex ? 16 : 10) else { out.append(c); i += 1; continue }
                if j < n, scalars[j] == ";" { j += 1 }
                out.append(numericScalar(v))
                i = j
                continue
            }
            var j = i + 1
            var name = ""
            while j < n, name.count < 32, scalars[j].properties.isAlphabetic || (scalars[j] >= "0" && scalars[j] <= "9") {
                name.unicodeScalars.append(scalars[j]); j += 1
            }
            if j < n, scalars[j] == ";", let v = named[name] {
                out.append(contentsOf: v.unicodeScalars)
                i = j + 1
                continue
            }
            // Legacy forms without ";" (only the very common ones, and not inside "&ampxyz=").
            if ["amp", "lt", "gt", "quot", "nbsp"].contains(name), !(j < n && scalars[j] == "="), let v = named[name] {
                out.append(contentsOf: v.unicodeScalars)
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static let cp1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    private static func numericScalar(_ v: UInt32) -> Unicode.Scalar {
        if let mapped = cp1252[v], let s = Unicode.Scalar(mapped) { return s }
        if v == 0 || (0xD800...0xDFFF).contains(v) || v > 0x10FFFF { return "\u{FFFD}" }
        return Unicode.Scalar(v) ?? "\u{FFFD}"
    }

    private static let latin1Names = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not",
        "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1",
        "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc", "Atilde", "Auml",
        "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml", "ETH",
        "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc",
        "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil",
        "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde", "ograve", "oacute",
        "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ]
    private static let greekUpper = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota",
                                     "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi", "Rho"]
    private static let greekUpper2 = ["Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega"]
    private static let greekLower = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota",
                                     "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigmaf", "sigma",
                                     "tau", "upsilon", "phi", "chi", "psi", "omega"]
    private static let others: [(String, UInt32)] = [
        ("quot", 34), ("amp", 38), ("apos", 39), ("lt", 60), ("gt", 62), ("OElig", 338), ("oelig", 339),
        ("Scaron", 352), ("scaron", 353), ("Yuml", 376), ("fnof", 402), ("circ", 710), ("tilde", 732),
        ("thetasym", 977), ("upsih", 978), ("piv", 982), ("ensp", 8194), ("emsp", 8195), ("thinsp", 8201),
        ("hairsp", 8202), ("zwnj", 8204), ("zwj", 8205), ("lrm", 8206), ("rlm", 8207), ("hyphen", 8208),
        ("dash", 8208), ("ndash", 8211), ("mdash", 8212), ("horbar", 8213), ("lsquo", 8216), ("rsquo", 8217),
        ("sbquo", 8218), ("ldquo", 8220), ("rdquo", 8221), ("bdquo", 8222), ("dagger", 8224), ("Dagger", 8225),
        ("bull", 8226), ("hellip", 8230), ("permil", 8240), ("prime", 8242), ("Prime", 8243), ("lsaquo", 8249),
        ("rsaquo", 8250), ("oline", 8254), ("frasl", 8260), ("euro", 8364), ("image", 8465), ("weierp", 8472),
        ("real", 8476), ("trade", 8482), ("alefsym", 8501), ("larr", 8592), ("uarr", 8593), ("rarr", 8594),
        ("darr", 8595), ("harr", 8596), ("crarr", 8629), ("lArr", 8656), ("uArr", 8657), ("rArr", 8658),
        ("dArr", 8659), ("hArr", 8660), ("forall", 8704), ("part", 8706), ("exist", 8707), ("empty", 8709),
        ("nabla", 8711), ("isin", 8712), ("notin", 8713), ("ni", 8715), ("prod", 8719), ("sum", 8721),
        ("minus", 8722), ("lowast", 8727), ("radic", 8730), ("prop", 8733), ("infin", 8734), ("ang", 8736),
        ("and", 8743), ("or", 8744), ("cap", 8745), ("cup", 8746), ("int", 8747), ("there4", 8756), ("sim", 8764),
        ("cong", 8773), ("asymp", 8776), ("ne", 8800), ("equiv", 8801), ("le", 8804), ("ge", 8805), ("sub", 8834),
        ("sup", 8835), ("nsub", 8836), ("sube", 8838), ("supe", 8839), ("oplus", 8853), ("otimes", 8855),
        ("perp", 8869), ("sdot", 8901), ("lceil", 8968), ("rceil", 8969), ("lfloor", 8970), ("rfloor", 8971),
        ("lang", 9001), ("rang", 9002), ("loz", 9674), ("spades", 9824), ("clubs", 9827), ("hearts", 9829),
        ("diams", 9830), ("Tab", 9), ("NewLine", 10), ("excl", 33), ("num", 35), ("dollar", 36), ("percnt", 37),
        ("lpar", 40), ("rpar", 41), ("ast", 42), ("plus", 43), ("comma", 44), ("period", 46), ("sol", 47),
        ("colon", 58), ("semi", 59), ("equals", 61), ("quest", 63), ("commat", 64), ("lsqb", 91), ("lbrack", 91),
        ("bsol", 92), ("rsqb", 93), ("rbrack", 93), ("Hat", 94), ("lowbar", 95), ("grave", 96), ("lcub", 123),
        ("lbrace", 123), ("verbar", 124), ("vert", 124), ("rcub", 125), ("rbrace", 125), ("centerdot", 183),
        ("ZeroWidthSpace", 8203), ("NoBreak", 8288), ("nbhy", 8209), ("check", 10003), ("checkmark", 10003),
        ("star", 9734), ("starf", 9733), ("laquo", 171), ("raquo", 187),
    ]

    private static let named: [String: String] = {
        var d: [String: String] = [:]
        func put(_ k: String, _ v: UInt32) { if let s = Unicode.Scalar(v) { d[k] = String(Character(s)) } }
        for (i, k) in latin1Names.enumerated() { put(k, UInt32(160 + i)) }
        for (i, k) in greekUpper.enumerated() { put(k, UInt32(913 + i)) }
        for (i, k) in greekUpper2.enumerated() { put(k, UInt32(931 + i)) }
        for (i, k) in greekLower.enumerated() { put(k, UInt32(945 + i)) }
        for (k, v) in others { put(k, v) }
        return d
    }()
}
