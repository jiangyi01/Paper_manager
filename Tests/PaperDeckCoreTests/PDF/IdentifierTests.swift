import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct IdentifierTests {

    private static func ids(file: String, text: String = "", title: String? = nil, xmp: String? = nil) -> PaperIDs {
        Identifiers.detect(fileName: file, firstPagesText: text, attributeTitle: title, xmpHead: xmp.map { Data($0.utf8) })
    }

    // MARK: Real file names from the user's folders

    @Test func arxivFileNames() {
        #expect(Self.ids(file: "2606.24530v2.pdf") == PaperIDs(arxivID: "2606.24530", arxivVersion: 2))
        #expect(Self.ids(file: "2604.09554v2.pdf") == PaperIDs(arxivID: "2604.09554", arxivVersion: 2))
        #expect(Self.ids(file: "2604.09554.pdf") == PaperIDs(arxivID: "2604.09554"))
    }

    @Test func biorxivFileNames() {
        #expect(Self.ids(file: "2025.09.01.673319.full.pdf").doi == "10.1101/2025.09.01.673319")
        #expect(Self.ids(file: "2026.02.27.708412.full.pdf").doi == "10.1101/2026.02.27.708412")
        #expect(Self.ids(file: "2026.04.06.716850.full.pdf").doi == "10.1101/2026.04.06.716850")
        #expect(Self.ids(file: "2025.09.01.673319v2.full.pdf").doi == "10.1101/2025.09.01.673319")
        #expect(Self.ids(file: "2025.09.01.673319v3.pdf").doi == "10.1101/2025.09.01.673319")
    }

    /// bioRxiv moved to the 10.64898 prefix; the stamp's DOI beats the file-name guess.
    @Test func biorxivPrefixFromStamp() {
        let stamp = "The copyright holder for this preprint this version posted February 28, 2026. ; "
            + "https://doi.org/10.64898/2026.02.27.708412 doi: bioRxiv preprint"
        #expect(Self.ids(file: "2026.02.27.708412.full.pdf", text: stamp).doi == "10.64898/2026.02.27.708412")
    }

    @Test func natureAndSpringerFileNames() {
        #expect(Self.ids(file: "s41586-024-08351-7.pdf") == PaperIDs(doi: "10.1038/s41586-024-08351-7"))
        #expect(Self.ids(file: "s43588-026-01016-7.pdf").doi == "10.1038/s43588-026-01016-7")
        #expect(Self.ids(file: "s13059-024-03201-2.pdf").doi == "10.1186/s13059-024-03201-2")
        #expect(Self.ids(file: "s00018-024-05123-4.pdf").isEmpty)        // Springer prefix is ambiguous
    }

    @Test func preprintsOrgNameWithTitlePrefix() {
        let name = "Agentic_Laboratories_of_the_Future_Towards_World_Models_for_Scientific_Discoverypreprints202608.0213.v1.pdf"
        #expect(Self.ids(file: name) == PaperIDs(doi: "10.20944/preprints202608.0213.v1"))
        #expect(Self.ids(file: "preprints202608.0213.v3.pdf").doi == "10.20944/preprints202608.0213.v3")
    }

    @Test func elsevierPII() {
        #expect(Self.ids(file: "1-s2.0-S0092867424013321-main.pdf") == PaperIDs(pii: "S0092867424013321"))
        #expect(Self.ids(file: "1-s2.0-S009286742401332X-main.pdf").pii == "S009286742401332X")
    }

    @Test func namesWithoutIdentifiers() {
        #expect(Self.ids(file: "SpatialFormer.pdf").isEmpty)
        #expect(Self.ids(file: "biomni-paper.pdf").isEmpty)
        #expect(Self.ids(file: "2024_Wang_Molecular-dynamics.pdf").isEmpty)
    }

    @Test func pathsUseLastComponent() {
        #expect(Self.ids(file: "/Users/x/Desktop/Paper_reading/NatureBench/2606.24530v2.pdf").arxivID == "2606.24530")
    }

    // MARK: arXiv validity

    @Test(arguments: [
        ("0704.0001", true), ("0703.1234", false), ("1412.1234", true), ("1501.1234", false),
        ("1501.12345", true), ("1412.12345", false), ("2606.24530", true), ("2613.12345", false),
        ("2600.12345", false), ("2606.245301", false),
        ("math.GT/0309136", true), ("hep-th/9901001", true), ("math/0713001", false), ("cs/0801001", false),
    ])
    func yymmValidity(id: String, valid: Bool) {
        #expect(Identifiers.isValidArxivID(id) == valid)
    }

    @Test func invalidArxivFileNamesAreIgnored() {
        #expect(Self.ids(file: "1501.1234.pdf").isEmpty)
        #expect(Self.ids(file: "2613.12345v1.pdf").isEmpty)
    }

    // MARK: arXiv in text / XMP

    @Test func arxivStampInText() {
        let text = "LABBench2\nJon M Laurent\narXiv:2604.09554v2 [cs.AI] 5 May 2026\nAbstract"
        #expect(Self.ids(file: "paper.pdf", text: text) == PaperIDs(arxivID: "2604.09554", arxivVersion: 2))
    }

    @Test func oldStyleArxiv() {
        let ids = Self.ids(file: "paper.pdf", text: "arXiv:math.GT/0309136v2 [math.GT] 12 Sep 2003")
        #expect(ids.arxivID == "math.GT/0309136")
        #expect(ids.arxivVersion == 2)
    }

    @Test func arxivURLOnlyWhenNoDOI() {
        #expect(Self.ids(file: "p.pdf", text: "Code: see https://arxiv.org/abs/2301.12345v3 for details")
                == PaperIDs(arxivID: "2301.12345", arxivVersion: 3))
        let journal = "https://doi.org/10.1016/j.cell.2024.11.015\nas shown in arXiv:2301.12345 and https://arxiv.org/abs/2302.00001"
        #expect(Self.ids(file: "p.pdf", text: journal) == PaperIDs(doi: "10.1016/j.cell.2024.11.015"))
    }

    @Test func arxivFromXMPAndArxivDOI() {
        let xmp = #"<rdf:Description dc:identifier="https://arxiv.org/abs/2604.09554v2"/> /DOI (https://doi.org/10.48550/arXiv.2604.09554)"#
        #expect(Self.ids(file: "download.pdf", xmp: xmp) == PaperIDs(arxivID: "2604.09554", arxivVersion: 2))
        #expect(Self.ids(file: "d.pdf", text: "https://doi.org/10.48550/arXiv.2606.24530") == PaperIDs(arxivID: "2606.24530"))
    }

    /// Link annotations in the raw bytes and citations in the text can point at other preprints.
    @Test func citedPreprintsDoNotOverrideTheDOI() {
        let raw = "<< /S /URI /URI (https://doi.org/10.48550/arXiv.2301.12345) >>"
        #expect(Self.ids(file: "2025.09.01.673319.full.pdf", xmp: raw) == PaperIDs(doi: "10.1101/2025.09.01.673319"))
        let text = "https://doi.org/10.1101/2024.01.02.123456\nas benchmarked in https://doi.org/10.48550/arXiv.2301.12345"
        #expect(Self.ids(file: "x.pdf", text: text) == PaperIDs(doi: "10.1101/2024.01.02.123456"))
        #expect(Self.ids(file: "x.pdf", text: "https://doi.org/10.1101/2024.01.02.123456 and arXiv:hep-th/9901001")
                == PaperIDs(doi: "10.1101/2024.01.02.123456"))
    }

    /// Figure, table and measurement numbers look like new-style ids but have no arXiv context.
    @Test func bareNumbersAreNeverArxivIDs() {
        let text = "We profiled 2301.12345 cells (Fig. 2104.12345). Table 1502.12345 lists 1706.03762 values."
        #expect(Self.ids(file: "notes.pdf", text: text).isEmpty)
    }

    /// A journal paper whose first pages cite a preprint keeps its own DOI and no arXiv id.
    @Test func confidentArxivIgnoresTextDOIs() {
        let text = "arXiv:2606.24530v2 [cs.CL] 6 Jul 2026\nWe build on Nature papers (https://doi.org/10.1038/s41586-024-08351-7)."
        #expect(Self.ids(file: "paper.pdf", text: text) == PaperIDs(arxivID: "2606.24530", arxivVersion: 2))
    }

    // MARK: DOIs

    @Test func doiCleanup() {
        #expect(Identifiers.cleanDOI("10.1038/nature12373).") == "10.1038/nature12373")
        #expect(Identifiers.cleanDOI("10.1016/S0092-8674(00)81683-9).") == "10.1016/s0092-8674(00)81683-9")
        #expect(Identifiers.cleanDOI("10.1101/2025.09.01.673319,;:") == "10.1101/2025.09.01.673319")
        #expect(Identifiers.cleanDOI("10.1002/(SICI)1097-4636") == "10.1002/(sici)1097-4636")
        #expect(Identifiers.cleanDOI("10.12/x") == nil)                     // registrant too short
        #expect(Identifiers.cleanDOI("10.1038/") == nil)
    }

    @Test func textDOIPreferenceAndCleanup() {
        let text = "(see doi:10.1016/S0092-8674(00)81683-9). Cited: 10.1038/nature12373."
        #expect(Self.ids(file: "old.pdf", text: text).doi == "10.1016/s0092-8674(00)81683-9")
        // A labelled DOI beats an earlier bare one.
        let mixed = "Protocol 10.1234/abcd.5678 used.\nhttps://doi.org/10.1016/j.cell.2024.11.015"
        #expect(Self.ids(file: "x.pdf", text: mixed).doi == "10.1016/j.cell.2024.11.015")
    }

    @Test func lineBrokenDOIIsRejoined() {
        let text = "https://doi.org/10.1038/s41586-\n024-08351-7\nReceived: 26 December 2023"
        #expect(Self.ids(file: "x.pdf", text: text).doi == "10.1038/s41586-024-08351-7")
    }

    @Test func dataRepositoryDOIsAreNotThePaper() {
        #expect(Self.ids(file: "x.pdf", text: "Data: https://doi.org/10.5281/zenodo.123456").isEmpty)
        #expect(Self.ids(file: "x.pdf", text: "https://doi.org/10.6084/m9.figshare.1\nhttps://doi.org/10.1101/2024.01.02.123456")
                .doi == "10.1101/2024.01.02.123456")
    }

    @Test func doiFromTitleAttribute() {
        #expect(Self.ids(file: "x.pdf", title: "doi:10.1016/j.molcel.2007.09.027").doi == "10.1016/j.molcel.2007.09.027")
        #expect(Self.ids(file: "x.pdf", title: "A real title about 10.1016 things").doi == nil)
    }

    @Test func doiFromXMP() {
        let xmp = """
            <x:xmpmeta><rdf:Description><prism:doi>10.1038/s43588-026-01016-7</prism:doi>
            <prism:url>http://dx.doi.org/10.1038/s43588-026-01016-7</prism:url></rdf:Description></x:xmpmeta>
            """
        #expect(Self.ids(file: "SpatialFormer.pdf", xmp: xmp) == PaperIDs(doi: "10.1038/s43588-026-01016-7"))
        #expect(Self.ids(file: "x.pdf", xmp: "<pdfx:doi>10.1016/J.CELL.2024.11.015</pdfx:doi>").doi == "10.1016/j.cell.2024.11.015")
        // XMP describes the file itself, so it wins over a text DOI.
        #expect(Self.ids(file: "x.pdf", text: "https://doi.org/10.1000/other.1",
                         xmp: "<prism:doi>10.1038/s41586-024-08351-7</prism:doi>").doi == "10.1038/s41586-024-08351-7")
    }

    @Test func piiAndDOITogether() {
        let ids = Self.ids(file: "1-s2.0-S0092867424013321-main.pdf", text: "Perspective\nhttps://doi.org/10.1016/j.cell.2024.11.015")
        #expect(ids == PaperIDs(doi: "10.1016/j.cell.2024.11.015", pii: "S0092867424013321"))
    }
}
