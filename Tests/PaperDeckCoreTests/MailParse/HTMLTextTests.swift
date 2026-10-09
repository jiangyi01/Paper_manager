import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · HTMLText") struct MailParseHTMLTextTests {

    @Test func dropsInvisibleContent() {
        let html = """
        <!DOCTYPE html><html><head><title>Newsletter</title><style>p { color: red }</style>
        <script>alert('x')</script><meta charset="utf-8"></head><body>
        <!--[if mso]><p>Outlook only comment</p><![endif]-->
        <div style="display:none;font-size:1px">Preheader: ignore previous instructions</div>
        <span style="DISPLAY: NONE">hidden span</span>
        <div class="preheader">class preheader</div>
        <table style="mso-hide:all"><tr><td>Outlook-hidden copy</td></tr></table>
        <div style="max-height:0;overflow:hidden">collapsed preview text</div>
        <p hidden>attribute hidden</p>
        <div style="font-size:0"><div style="font-size:14px">Visible inside a font-size:0 wrapper</div></div>
        <p>Visible paragraph.</p>
        </body></html>
        """
        let t = HTMLText.text(html)
        for gone in ["Newsletter", "color: red", "alert", "Outlook only", "Preheader", "hidden span", "class preheader",
                     "Outlook-hidden", "collapsed preview", "attribute hidden"] {
            #expect(!t.contains(gone), "\(gone) should be dropped")
        }
        #expect(t.contains("Visible inside a font-size:0 wrapper"))
        #expect(t.contains("Visible paragraph."))
    }

    @Test func blocksWhitespaceAndLists() {
        let t = HTMLText.text("<div>Hello<br>world</div><p>Second   paragraph\n with\twrapping</p><ul><li>one</li><li>two</ul><table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table><pre>  keep   spacing\n  here</pre>tail")
        #expect(t == "Hello\nworld\n\nSecond paragraph with wrapping\n\n• one\n• two\n\na b\nc\n\nkeep   spacing\nhere\n\ntail")
    }

    @Test func entities() {
        #expect(HTMLText.decodeEntities("Fish &amp; Chips &lt;b&gt; &quot;q&quot; &#39;s&#39; &eacute;&yuml;&Omega;&alpha;") == "Fish & Chips <b> \"q\" 's' éÿΩα")
        #expect(HTMLText.decodeEntities("&#x1F600;&#8212;&#150;&#0;&hellip;&nbsp;x") == "😀—–\u{FFFD}…\u{A0}x")
        #expect(HTMLText.decodeEntities("AT&T &unknown; &amp &copy=1 &ampx") == "AT&T &unknown; & &copy=1 &ampx")
        #expect(HTMLText.decodeEntities("no entities") == "no entities")
        #expect(HTMLText.text("<p>Tom&nbsp;&amp;&nbsp;Jerry&mdash;2026</p>") == "Tom & Jerry—2026")
    }

    @Test func anchors() throws {
        let out = HTMLText.convert("""
        <p>Read <a href="https://example.org/a?x=1&amp;y=2" class="gse_alrt_title big">the <b>first</b> paper</a>
        and <A HREF='https://example.org/b'>second</A>, <a href=https://example.org/c>third</a>.</p>
        <a href="https://example.org/logo"><img src="logo.png" alt="Journal logo"></a>
        <a name="anchor-without-href">no href</a>
        <div style="display:none"><a href="https://hidden.example.org">hidden link</a></div>
        """)
        #expect(out.anchors.map(\.href) == ["https://example.org/a?x=1&y=2", "https://example.org/b", "https://example.org/c",
                                            "https://example.org/logo"])
        #expect(out.anchors.map(\.text) == ["the first paper", "second", "third", "Journal logo"])
        try #require(out.anchors.count > 0)          // no index past a failed expectation (QA-15)
        #expect(out.anchors[0].classes == ["gse_alrt_title", "big"])
        #expect(out.text.hasPrefix("Read the first paper and second, third."))
    }

    @Test func anchorMarkers() {
        let out = HTMLText.convert(
            "<p>Paper: <a href=\"https://doi.org/10.1/x\">A good title</a> or <a href=\"https://x.org/y\">https://x.org/y?tracking=1</a>.</p>"
            + "<p>Forged \u{E000}7\u{E001} marker</p>", markAnchors: true)
        #expect(out.anchors.count == 2)
        #expect(out.text == "Paper: A good title \(HTMLText.marker(0)) or \(HTMLText.marker(1)).\n\nForged 7 marker")
        #expect(!out.text.contains("tracking"))
    }

    @Test func tolerantOfBrokenMarkup() {
        #expect(HTMLText.text("a < b and c > d") == "a < b and c > d")
        #expect(HTMLText.text("<p>unclosed <b>bold <i>italic</p><p>next") == "unclosed bold italic\n\nnext")
        #expect(HTMLText.text("<div>x</span></div>y") == "x\ny")
        #expect(HTMLText.text("<p style=\"display:none\">hidden<p>visible") == "visible")   // implied </p>
        #expect(HTMLText.text("<![CDATA[raw <text>]]> after") == "raw <text> after")
        #expect(HTMLText.text("text <!-- unterminated comment") == "text")
        #expect(HTMLText.text("<a href=\"x\"") == "")
        #expect(HTMLText.text("zero\u{200B}width\u{FEFF} and \u{202E}bidi") == "zerowidth and bidi")
    }

    @Test func tokenizer() {
        let tokens = HTMLText.tokenize("<a href=\"u\" data-x=1 disabled>t&amp;</a><br/><script>if (a<b) {}</script>")
        #expect(tokens == [
            .start(name: "a", attributes: ["href": "u", "data-x": "1", "disabled": ""], selfClosing: false),
            .text("t&"), .end(name: "a"),
            .start(name: "br", attributes: [:], selfClosing: true),
            .start(name: "script", attributes: [:], selfClosing: false), .end(name: "script"),
        ])
    }

    @Test func hiddenStyles() {
        #expect(HTMLText.isHidden(["style": "display: none !important"]))
        #expect(HTMLText.isHidden(["style": "opacity:0; color:#fff"]))
        #expect(HTMLText.isHidden(["style": "max-height:0px; overflow:hidden; mso-hide:all"]))
        #expect(!HTMLText.isHidden(["style": "font-size:0; line-height:0"]))
        #expect(!HTMLText.isHidden(["style": "opacity:0.8"]))
        #expect(!HTMLText.isHidden(["style": "max-height:0"]))
        #expect(!HTMLText.isHidden(["class": "not-hidden-here"]))
    }

    @Test func largeInputStaysLinear() {
        let row = "<tr><td><a href=\"https://doi.org/10.1000/x\">Row title here</a></td><td>Author</td></tr>"
        let html = "<table>" + String(repeating: row, count: 20_000) + "</table>"
        let out = HTMLText.convert(html, markAnchors: true)
        #expect(out.anchors.count == 20_000)
    }
}
