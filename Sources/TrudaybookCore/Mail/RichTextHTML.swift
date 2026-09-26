import AppKit

/// Оформленный текст из редактора ответа → простой чистый HTML для письма.
///
/// Не `NSAttributedString.data(documentType: .html)`: тот выдаёт документ
/// со стилями по классам (`p.p1 {…}`), которые почтовые программы режут,
/// и письмо приходит без оформления. Здесь — только `<b>`, `<i>`, `<u>`,
/// `<a>`, списки, абзацы, таблицы и цвет строчными стилями (`style="color:…"`):
/// это понимают все, включая Outlook и Gmail.
public enum RichTextHTML {
    /// Метка пункта маркированного списка в редакторе.
    public static let bullet = "• "

    public static func html(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var blocks: [String] = []
        var list: (tag: String, items: [String])?

        func flushList() {
            guard let current = list else { return }
            blocks.append("<\(current.tag)>" + current.items.map { "<li>\($0)</li>" }.joined() + "</\(current.tag)>")
            list = nil
        }

        var lines: [NSRange] = []
        var start = 0
        for index in 0..<string.length where string.character(at: index) == 0x0A {
            lines.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        lines.append(NSRange(location: start, length: string.length - start))
        // Пустые строки в конце — не абзацы, а следы нажатия Return.
        while let last = lines.last, last.length == 0, lines.count > 1 { lines.removeLast() }

        // Таблица: ячейки — абзацы с `NSTextTableBlock` одной `NSTextTable`.
        var table: (object: NSTextTable, cells: [[Int: String]])?
        func flushTable() {
            guard let current = table else { return }
            let columns = current.object.numberOfColumns
            let rows = current.cells.map { row in
                "<tr>" + (0..<columns).map { column in
                    "<td style=\"border:1px solid #BBBBBB;padding:4px 8px;vertical-align:top\">\(row[column] ?? "")</td>"
                }.joined() + "</tr>"
            }
            blocks.append("<table style=\"border-collapse:collapse;margin:6px 0\">" + rows.joined() + "</table>")
            table = nil
        }

        for line in lines {
            let content = string.substring(with: line)
            let style = line.location < text.length
                ? text.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle
                : nil
            if let block = style?.textBlocks.first as? NSTextTableBlock {
                flushList()
                if table?.object !== block.table { flushTable(); table = (block.table, []) }
                while table!.cells.count <= block.startingRow { table!.cells.append([:]) }
                let inner = inline(text, in: line)
                let previous = table!.cells[block.startingRow][block.startingColumn]
                table!.cells[block.startingRow][block.startingColumn] = previous.map { $0 + "<br>" + inner } ?? inner
                continue
            }
            flushTable()
            var tag: String?
            var markerLength = 0
            if content.hasPrefix(bullet) {
                tag = "ul"
                markerLength = (bullet as NSString).length
            } else if let match = content.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                tag = "ol"
                markerLength = (String(content[match]) as NSString).length
            }
            let inner = inline(text, in: NSRange(location: line.location + markerLength, length: line.length - markerLength))

            if let tag {
                if list?.tag != tag { flushList() }
                if list == nil { list = (tag, []) }
                list?.items.append(inner)
            } else {
                flushList()
                blocks.append(inner.isEmpty ? "<div><br></div>" : "<div>\(inner)</div>")
            }
        }
        flushList()
        flushTable()
        return blocks.joined()
    }

    /// Кусок строки с начертаниями и ссылками.
    static func inline(_ text: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            var piece = escape((text.string as NSString).substring(with: runRange))
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            let underlined = (attributes[.underlineStyle] as? Int ?? 0) != 0

            // Ссылка и так подчёркнута — второе подчёркивание ей ни к чему.
            if underlined, link == nil { piece = "<u>\(piece)</u>" }
            if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
            if traits.contains(.bold) { piece = "<b>\(piece)</b>" }
            if let link { piece = "<a href=\"\(escape(link))\">\(piece)</a>" }
            // Цвет и выделение — строчным стилем. Системный цвет текста
            // (он меняется с темой) — не цвет, а «обычный».
            var css: [String] = []
            if let color = attributes[.foregroundColor] as? NSColor, link == nil, let hex = hex(color) {
                css.append("color:\(hex)")
            }
            if let color = attributes[.backgroundColor] as? NSColor, let hex = hex(color) {
                css.append("background-color:\(hex)")
            }
            if !css.isEmpty { piece = "<span style=\"\(css.joined(separator: ";"))\">\(piece)</span>" }
            out += piece
        }
        return out
    }

    /// `#RRGGBB`; `nil` — у системных цветов (цвет текста, фон), их не пишем.
    static func hex(_ color: NSColor) -> String? {
        guard color.type != .catalog, let rgb = color.usingColorSpace(.sRGB), rgb.alphaComponent > 0.05 else { return nil }
        let value = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value(rgb.redComponent), value(rgb.greenComponent), value(rgb.blueComponent))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
