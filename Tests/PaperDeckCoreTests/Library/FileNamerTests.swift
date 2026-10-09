import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct FileNamerTests {
    @Test func designExample() {
        let name = FileNamer.folderName(year: 2024, firstAuthor: "Li Wang",
                                        title: "Molecular and cellular dynamics of the developing human neocortex")
        #expect(name == "2024_Wang_Molecular-and-cellular-dynamics-of-the-developing-human-neocortex")
        #expect(FileNamer.pdfName(forFolder: name) == name + ".pdf")
    }

    @Test func missingPartsAreOmitted() {
        #expect(FileNamer.folderName(year: nil, firstAuthor: "Li Wang", title: "Brain atlas") == "Wang_Brain-atlas")
        #expect(FileNamer.folderName(year: 2025, firstAuthor: nil, title: "Brain atlas") == "2025_Brain-atlas")
        #expect(FileNamer.folderName(year: 2025, firstAuthor: "Li Wang", title: nil) == "2025_Wang")
        #expect(FileNamer.folderName(year: 2025, firstAuthor: "  ", title: "") == "2025")
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: nil) == "Untitled")
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "???***") == "Untitled")
        #expect(FileNamer.folderName(year: 99_999, firstAuthor: nil, title: "X ray") == "X-ray")
    }

    @Test func pathTraversalAndReservedCharacters() {
        let name = FileNamer.folderName(year: nil, firstAuthor: nil, title: "../../etc/passwd")
        #expect(!name.contains("/"))
        #expect(!name.hasPrefix("."))
        #expect(name == "etc-passwd")

        let nasty = FileNamer.folderName(year: 2024, firstAuthor: "O/Brien",
                                         title: #"a/b:c\d?e%f*g|h"i<j>k"#)
        for ch in #"/:\?%*|"<>"# { #expect(!nasty.contains(ch)) }
        #expect(nasty == "2024_O-Brien_a-b-c-d-e-f-g-h-i-j-k")

        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "...hidden") == "hidden")
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "..") == "Untitled")
    }

    @Test func controlAndBidiCharactersAreReplaced() {
        let title = "Evil\u{202E}fdp.exe\u{0000}name\u{0007}with\u{200F}marks\u{2066}x"
        let name = FileNamer.folderName(year: nil, firstAuthor: nil, title: title)
        #expect(name == "Evil-fdp.exe-name-with-marks-x")
        for scalar in name.unicodeScalars {
            #expect(scalar.value >= 0x20 && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value))
        }
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "Line\nbreak\ttab") == "Line-break-tab")
    }

    @Test func repeatsCollapseAndTrailingPunctuationDrops() {
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "scGPT: toward building a foundation model.")
                == "scGPT-toward-building-a-foundation-model")
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: "Cells, genes;  and -- more")
                == "Cells-genes-and-more")
    }

    @Test func nfcNormalization() {
        let decomposed = "Me\u{0301}thodes cellulaires"      // e + combining acute
        let name = FileNamer.folderName(year: nil, firstAuthor: "Jose\u{0301} Nu\u{0301}n\u{0303}ez", title: decomposed)
        #expect(name == "Núñez_Méthodes-cellulaires".precomposedStringWithCanonicalMapping)
        #expect(name.unicodeScalars.count == name.precomposedStringWithCanonicalMapping.unicodeScalars.count)
        #expect(!name.unicodeScalars.contains("\u{0301}"))
    }

    @Test func emojiAndCJKSurvive() {
        let cjk = FileNamer.folderName(year: 2025, firstAuthor: "王力", title: "单细胞 空间 转录组 图谱")
        #expect(cjk == "2025_王力_单细胞-空间-转录组-图谱")
        let emoji = FileNamer.folderName(year: nil, firstAuthor: nil, title: "Cells 🧬 and 👩‍🔬 scientists")
        #expect(emoji == "Cells-🧬-and-👩‍🔬-scientists")
    }

    @Test func titleIsWordTruncatedTo80Characters() {
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let name = FileNamer.folderName(year: nil, firstAuthor: nil, title: words)
        #expect(name.count <= 80)
        #expect(name.hasPrefix("word1-word2-"))
        #expect(!name.hasSuffix("-"))
        // Cut on a word boundary: every piece is a complete word.
        #expect(name.split(separator: "-").allSatisfy { $0.hasPrefix("word") && Int($0.dropFirst(4)) != nil })
        let next = name + "-word\(name.split(separator: "-").count + 1)"
        #expect(next.count > 80)

        let oneLongWord = String(repeating: "a", count: 200)
        #expect(FileNamer.folderName(year: nil, firstAuthor: nil, title: oneLongWord).count == 80)
    }

    @Test func wholeNameCappedAt120BytesWithoutSplittingScalars() {
        // 80 CJK characters = 240 bytes → must be cut to ≤ 120 bytes on a scalar boundary.
        let cjkTitle = String(repeating: "脑", count: 100)
        let name = FileNamer.folderName(year: 2024, firstAuthor: "Wang", title: cjkTitle)
        #expect(name.utf8.count <= 120)
        #expect(name.hasPrefix("2024_Wang_脑"))
        #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name)
        #expect(name.unicodeScalars.allSatisfy { $0 == "_" || $0.isASCII || $0 == "脑" })

        // 4-byte emoji and ZWJ sequences are never cut in half.
        let emojiTitle = String(repeating: "👩‍🔬", count: 30)
        let e = FileNamer.folderName(year: nil, firstAuthor: nil, title: emojiTitle)
        #expect(e.utf8.count <= 120)
        #expect(e.allSatisfy { $0 == "👩‍🔬" })

        let mixed = FileNamer.folderName(year: 2024, firstAuthor: "Wang",
                                         title: String(repeating: "é🧬", count: 60))
        #expect(mixed.utf8.count <= 120)
        #expect(mixed.utf8.count > 100)
    }

    @Test func lastNames() {
        #expect(FileNamer.lastName(from: "Li Wang") == "Wang")
        #expect(FileNamer.lastName(from: "Wang, Li") == "Wang")
        #expect(FileNamer.lastName(from: "Arnold R. Kriegstein") == "Kriegstein")
        #expect(FileNamer.lastName(from: "Kriegstein AR") == "Kriegstein")
        #expect(FileNamer.lastName(from: "Wang L.") == "Wang")
        #expect(FileNamer.lastName(from: "Jan van der Berg") == "van der Berg")
        #expect(FileNamer.lastName(from: "van der Berg, Jan") == "van der Berg")
        #expect(FileNamer.lastName(from: "Ludwig van Beethoven") == "van Beethoven")
        #expect(FileNamer.lastName(from: "Leonardo da Vinci") == "da Vinci")
        #expect(FileNamer.lastName(from: "Robert De Niro") == "De Niro")
        #expect(FileNamer.lastName(from: "De Wang") == "Wang")            // "De" as a given name
        #expect(FileNamer.lastName(from: "Martin Luther King Jr.") == "King")
        #expect(FileNamer.lastName(from: "John Smith, Jr.") == "Smith")
        #expect(FileNamer.lastName(from: "Mary Smith-Jones") == "Smith-Jones")
        #expect(FileNamer.lastName(from: "Li Wang1,2*") == "Wang")
        #expect(FileNamer.lastName(from: "王力") == "王力")
        #expect(FileNamer.lastName(from: "Madonna") == "Madonna")
        #expect(FileNamer.lastName(from: "   ") == "")

        #expect(FileNamer.folderName(year: 2020, firstAuthor: "Jan van der Berg", title: "Tulips")
                == "2020_van-der-Berg_Tulips")
    }

    @Test func uniqueNamesAreCaseInsensitive() {
        let base = "2024_Wang_Brain"
        #expect(FileNamer.uniqueName(base, existing: []) == base)
        #expect(FileNamer.uniqueName(base, existing: ["2024_wang_brain"]) == base + "_2")
        #expect(FileNamer.uniqueName(base, existing: [base, base + "_2", base.uppercased() + "_3"]) == base + "_4")
        #expect(FileNamer.uniqueName(base, existing: [base + "_2"]) == base)

        let long = FileNamer.folderName(year: 2024, firstAuthor: "Wang", title: String(repeating: "脑", count: 100))
        let unique = FileNamer.uniqueName(long, existing: [long])
        #expect(unique.hasSuffix("_2"))
        #expect(unique.utf8.count <= 120)
        #expect(unique != long)
    }

    @Test func inboxNames() {
        let sha = "5F31A23CF3EB7B5137F0B49850CC7433B6B5966A0519AD42B96D33C83891C504"
        #expect(FileNamer.inboxFolderName(sha: sha, originalName: "s41586-024-08351-7.pdf") == "5f31a23c")
        #expect(FileNamer.inboxFolderName(sha: "zz", originalName: "../My paper.pdf") == "My paper")
        #expect(FileNamer.inboxPDFName(originalName: "s41586-024-08351-7.pdf") == "s41586-024-08351-7.pdf")
        #expect(FileNamer.inboxPDFName(originalName: "Dropped") == "Dropped.pdf")
        #expect(FileNamer.inboxPDFName(originalName: "PAPER.PDF") == "PAPER.PDF")
    }

    @Test func sanitizedFileNames() {
        #expect(FileNamer.sanitizedFileName("../../etc/passwd") == "etc-passwd")
        #expect(FileNamer.sanitizedFileName(".hidden.pdf") == "hidden.pdf")
        #expect(FileNamer.sanitizedFileName("a:b?.pdf") == "a-b-.pdf")
        #expect(FileNamer.sanitizedFileName("Molecular  and\tcellular.pdf") == "Molecular and-cellular.pdf")
        #expect(FileNamer.sanitizedFileName("") == "Untitled")
        #expect(FileNamer.sanitizedFileName("\u{202E}") == "Untitled")

        let long = String(repeating: "稿", count: 120) + ".pdf"
        let cut = FileNamer.sanitizedFileName(long)
        #expect(cut.utf8.count <= 200)
        #expect(cut.hasSuffix(".pdf"))
        #expect(cut.dropLast(4).allSatisfy { $0 == "稿" })

        let preprint = "Agentic_Laboratories_of_the_Future_Towards_World_Models_for_Scientific_Discoverypreprints202608.0213.v1.pdf"
        #expect(FileNamer.sanitizedFileName(preprint) == preprint)
    }
}
