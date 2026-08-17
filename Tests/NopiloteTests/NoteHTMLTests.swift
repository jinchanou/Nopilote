import XCTest
@testable import Nopilote

final class NoteHTMLTests: XCTestCase {
    func testRendersSafeSupportedBlocks() {
        let blocks = [
            DocumentBlock(kind: .heading, text: "Plan & scope", items: nil, level: 2),
            DocumentBlock(kind: .paragraph, text: "Use <safe> text", items: nil, level: nil),
            DocumentBlock(kind: .bulletList, text: nil, items: ["One", "Two"], level: nil),
            DocumentBlock(kind: .code, text: "let x = 1 < 2", items: nil, level: nil)
        ]

        let html = NoteHTML.render(title: "A \"note\"", blocks: blocks)

        XCTAssertTrue(html.contains("<h1>A &quot;note&quot;</h1>"))
        XCTAssertTrue(html.contains("<h2>Plan &amp; scope</h2>"))
        XCTAssertTrue(html.contains("Use &lt;safe&gt; text"))
        XCTAssertTrue(html.contains("<ul><li>One</li><li>Two</li></ul>"))
        XCTAssertTrue(html.contains("let x = 1 &lt; 2"))
    }

    func testDetectsComplexNotesFormatting() {
        XCTAssertTrue(NoteHTML.containsComplexFormatting("<table><tr><td>x</td></tr></table>"))
        XCTAssertTrue(NoteHTML.containsComplexFormatting("<img src='cid:1'>"))
        XCTAssertFalse(NoteHTML.containsComplexFormatting("<h1>Title</h1><ul><li>Item</li></ul>"))
    }

    func testPlainTextPreservesListOrder() {
        let blocks = [
            DocumentBlock(kind: .numberedList, text: nil, items: ["First", "Second"], level: nil)
        ]
        XCTAssertEqual(NoteHTML.plainText(title: "Title", blocks: blocks), "Title\n1. First\n2. Second")
    }

    func testRendersRichAppleNotesStructures() {
        let blocks = [
            DocumentBlock(kind: .callout, text: "Decision: ship Friday", items: nil, level: nil),
            DocumentBlock(kind: .checklist, text: nil, items: ["Draft release notes", "Send announcement"], level: nil, checked: [true, false]),
            DocumentBlock(kind: .table, text: nil, items: nil, level: nil, rows: [["Option", "Cost"], ["A", "$10"]]),
            DocumentBlock(kind: .divider, text: nil, items: nil, level: nil)
        ]

        let html = NoteHTML.render(title: "Release plan", blocks: blocks)

        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("<th"))
        XCTAssertTrue(html.contains("&#9745;"))
        XCTAssertTrue(html.contains("&#9744;"))
        XCTAssertTrue(html.contains("border-left:4px solid"))
        XCTAssertTrue(html.contains("<hr"))
    }

    func testRichStructuresAppearInPlainText() {
        let blocks = [
            DocumentBlock(kind: .checklist, text: nil, items: ["Done", "Next"], level: nil, checked: [true, false]),
            DocumentBlock(kind: .table, text: nil, items: nil, level: nil, rows: [["A", "B"], ["1", "2"]]),
            DocumentBlock(kind: .divider, text: nil, items: nil, level: nil)
        ]

        XCTAssertEqual(NoteHTML.plainText(title: "Plan", blocks: blocks), "Plan\n[x] Done\n[ ] Next\nA | B\n1 | 2\n---")
    }
}
