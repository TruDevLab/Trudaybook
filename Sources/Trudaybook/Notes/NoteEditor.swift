import AppKit
import SwiftUI
import TrudaybookCore

/// Оформленная заметка: блоки повестки — в текст, текст — в RTF и обратно.
@MainActor
enum NoteRichText {
    static let bodyFont = RichTextController.bodyFont

    private static func paragraph(before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    /// Блоки — в текст редактора. Метки списков — теми же знаками, что
    /// ставит редактор: Return после вставки продолжает список, как обычно.
    static func attributed(_ blocks: [NoteBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let text: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.textColor]
        func line(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: string + "\n", attributes: attributes))
        }
        for block in blocks {
            switch block {
            case .title(let value):
                line(value, [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.textColor])
            case .heading(let value):
                line(value, [.font: RichTextController.headingFont, .foregroundColor: NSColor.textColor])
            case .subheading(let value):
                line(value, [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.textColor])
            case .label(let value):
                line(value, [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor,
                             .paragraphStyle: paragraph(before: 2)])
            case .text(let value):
                line(value, text)
            case .detail(let value):
                line(value, [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            case .bullet(let value):
                line(NoteMarkers.bullet + value, text)
            case .numbered(let number, let value):
                line("\(number). " + value, text)
            case .check(let value, let done):
                line((done ? NoteMarkers.checked : NoteMarkers.unchecked) + value, text)
            case .spacer:
                line("", text)
            }
        }
        return result
    }

    // MARK: - Хранение

    /// RTF для базы. Системный цвет текста не пишется: RTF запомнил бы его
    /// белым (тёмная тема), и в светлой теме текст пропал бы. Прочие
    /// системные цвета RTF хранит по имени и возвращает живыми.
    static func rtf(_ text: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if let color = value as? NSColor, isTextColor(color) { copy.removeAttribute(.foregroundColor, range: range) }
        }
        return try? copy.data(from: whole, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Текст из RTF. Шрифт — системный того же размера и начертания: RTF
    /// хранит системный шрифт как Helvetica Neue.
    static func decode(_ data: Data) -> NSAttributedString? {
        guard let text = try? NSMutableAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        else { return nil }
        let whole = NSRange(location: 0, length: text.length)
        let manager = NSFontManager.shared
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            let font = value as? NSFont ?? bodyFont
            let traits = manager.traits(of: font)
            var system = traits.contains(.boldFontMask)
                ? NSFont.boldSystemFont(ofSize: font.pointSize) : NSFont.systemFont(ofSize: font.pointSize)
            if traits.contains(.italicFontMask) { system = manager.convert(system, toHaveTrait: .italicFontMask) }
            text.addAttribute(.font, value: system, range: range)
        }
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        }
        return text
    }

    /// Простой текст (заметка без оформления, из Trunook) — в текст редактора.
    static func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: bodyFont, .foregroundColor: NSColor.textColor])
    }

    /// Заметка из базы: оформленная, а без оформления — простым текстом.
    /// Оформление сбрасывается при каждой записи простого текста
    /// (`ItemStateStore.setNote`), поэтому устаревшим оно не бывает.
    static func load(text: String, rich: Data?) -> NSAttributedString {
        if let rich, let decoded = decode(rich) { return decoded }
        return plain(text)
    }

    private static func isTextColor(_ color: NSColor) -> Bool {
        color.type == .catalog && color.catalogNameComponent == NSColor.textColor.catalogNameComponent
    }
}

/// Поле заметки. Своё `NSTextView`, а не общее с ответом: щелчок по
/// галочке в начале строки ставит и снимает её, а не ставит курсор.
struct NoteEditorView: NSViewRepresentable {
    let controller: RichTextController
    var autofocus = false
    var inset = NSSize(width: 6, height: 8)
    /// Поле создано — можно загружать в него текст.
    var onAttach: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // TextKit 1 сразу: таблицы (`NSTextTable`) его всё равно требуют,
        // а галочка ищется через `layoutManager`.
        let text = NoteTextView(usingTextLayoutManager: false)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = RichTextController.bodyFont
        text.textContainerInset = inset
        text.typingAttributes = [.font: RichTextController.bodyFont, .foregroundColor: NSColor.textColor]
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.delegate = controller
        text.onCheckbox = { [weak controller] index in controller?.toggleCheckbox(at: index) ?? false }
        scroll.documentView = text
        controller.textView = text
        DispatchQueue.main.async {
            onAttach?()
            if autofocus { controller.focus() }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

final class NoteTextView: NSTextView {
    /// Щелчок по знаку в этом месте текста: `true` — это была галочка.
    var onCheckbox: ((Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty,
           let index = checkboxIndex(at: convert(event.locationInWindow, from: nil)),
           onCheckbox?(index) == true {
            return
        }
        super.mouseDown(with: event)
    }

    /// Знак под курсором — только если щёлкнули по нему самому, а не рядом.
    private func checkboxIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -1).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let character = (storage.string as NSString).substring(with: NSRange(location: index, length: 1))
        return character == "☐" || character == "☑" ? index : nil
    }
}
