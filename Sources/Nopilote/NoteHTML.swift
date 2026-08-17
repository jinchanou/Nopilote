import Foundation

enum NoteHTML {
    private static let complexMarkers = [
        "<table", "<object", "<img", "<figure", "<input", "data-attachment",
        "com.apple.notes", "<attachment", "<iframe"
    ]

    static func containsComplexFormatting(_ html: String) -> Bool {
        let lowercased = html.lowercased()
        return complexMarkers.contains { lowercased.contains($0) }
    }

    static func render(title: String, blocks: [DocumentBlock]) -> String {
        var parts = ["<h1>\(escape(title))</h1>"]
        for block in blocks {
            switch block.kind {
            case .heading:
                let level = min(max(block.level ?? 2, 2), 3)
                parts.append("<h\(level)>\(inline(block.text ?? ""))</h\(level)>")
            case .paragraph:
                parts.append("<p>\(inline(block.text ?? ""))</p>")
            case .bulletList:
                parts.append(list(block.items ?? [], tag: "ul"))
            case .numberedList:
                parts.append(list(block.items ?? [], tag: "ol"))
            case .quote:
                parts.append("<blockquote>\(inline(block.text ?? ""))</blockquote>")
            case .code:
                parts.append("<pre style=\"background-color:#F2F2F7;padding:12px;border-radius:6px;white-space:pre-wrap;\"><code>\(escape(block.text ?? ""))</code></pre>")
            case .checklist:
                parts.append(checklist(block.items ?? [], checked: block.checked ?? []))
            case .table:
                parts.append(table(block.rows ?? []))
            case .divider:
                parts.append("<hr style=\"border:0;border-top:1px solid #D1D1D6;margin:12px 0;\">")
            case .callout:
                parts.append("<blockquote style=\"border-left:4px solid #0A84FF;background-color:#F2F7FF;padding:10px 14px;margin:10px 0;\">\(inline(block.text ?? ""))</blockquote>")
            }
        }
        return parts.joined(separator: "\n")
    }

    static func plainText(title: String, blocks: [DocumentBlock]) -> String {
        var lines = [title]
        for block in blocks {
            switch block.kind {
            case .heading, .paragraph, .quote, .code:
                lines.append(block.text ?? "")
            case .bulletList:
                lines.append(contentsOf: (block.items ?? []).map { "• \($0)" })
            case .numberedList:
                lines.append(contentsOf: (block.items ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" })
            case .checklist:
                lines.append(contentsOf: (block.items ?? []).enumerated().map { index, item in
                    let mark = (block.checked ?? []).indices.contains(index) && block.checked?[index] == true ? "[x]" : "[ ]"
                    return "\(mark) \(item)"
                })
            case .table:
                lines.append(contentsOf: (block.rows ?? []).map { $0.joined(separator: " | ") })
            case .divider:
                lines.append("---")
            case .callout:
                lines.append(block.text ?? "")
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func list(_ items: [String], tag: String) -> String {
        "<\(tag)>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>"
    }

    private static func checklist(_ items: [String], checked: [Bool]) -> String {
        let rows = items.enumerated().map { index, item in
            let isChecked = checked.indices.contains(index) && checked[index]
            let mark = isChecked ? "&#9745;" : "&#9744;"
            return "<li style=\"list-style-type:none;margin:4px 0;\">\(mark) \(inline(item))</li>"
        }.joined()
        return "<ul style=\"padding-left:0;\">\(rows)</ul>"
    }

    private static func table(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let header = rows[0].map { "<th style=\"background-color:#F2F2F7;font-weight:600;text-align:left;padding:8px;border:1px solid #D1D1D6;\">\(inline($0))</th>" }.joined()
        let body = rows.dropFirst().map { row in
            let cells = row.enumerated().map { index, cell in
                let colspan = index < rows[0].count ? "" : ""
                return "<td\(colspan) style=\"padding:8px;border:1px solid #D1D1D6;vertical-align:top;\">\(inline(cell))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()
        return "<table cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;width:100%;margin:10px 0;\"><thead><tr>\(header)</tr></thead><tbody>\(body)</tbody></table>"
    }

    private static func inline(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
