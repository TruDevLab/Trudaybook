import AppKit
import SwiftUI
import TrudaybookCore

/// Правка оформленного текста ответа поверх `NSTextView`.
///
/// Правки применяются прямо к полю, а не к копии текста: у `NSTextView`
/// своя отмена (⌘Z) и свои выделения, и вторая копия рядом с ними
/// однажды разошлась бы (так уже было в Trunook).
@MainActor
final class RichTextController: NSObject, ObservableObject, NSTextViewDelegate {
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    weak var textView: NSTextView?

    var attributed: NSAttributedString {
        textView.map { NSAttributedString(attributedString: $0.attributedString()) } ?? NSAttributedString()
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Подпись в конце письма: вставить или заменить прежнюю (сменили ящик
    /// «от»). Если прежнюю подпись в тексте уже правили руками — не трогать
    /// её, а новую не добавлять: человек пишет свою.
    func setSignature(_ new: String, replacing old: String?) {
        guard let textView, let storage = textView.textStorage else { return }
        func block(_ text: String) -> String { text.isEmpty ? "" : "\n\n" + text }
        let current = storage.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        if let old, !old.isEmpty {
            let previous = block(old) as NSString
            guard current.hasSuffix(previous as String) else { return }
            let range = NSRange(location: current.length - previous.length, length: previous.length)
            edit(range) { storage.replaceCharacters(in: range, with: NSAttributedString(string: block(new), attributes: attributes)) }
        } else if !new.isEmpty {
            let range = NSRange(location: current.length, length: 0)
            edit(range) { storage.replaceCharacters(in: range, with: NSAttributedString(string: block(new), attributes: attributes)) }
        }
        // Писать — с начала, над подписью.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Начальный текст черновика — например, подготовленный помощником
    /// Trunook. Только в пустое поле: при повторном появлении окна ответа
    /// текст не должен задвоиться.
    func prefill(_ text: String) {
        guard let textView, let storage = textView.textStorage, storage.length == 0, !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    // MARK: - Цвет и выделение

    /// Цвет текста выделенного (или того, что будет набрано). `nil` — обычный:
    /// системный цвет текста, он сам светлеет в тёмной теме.
    func setTextColor(_ color: NSColor?) {
        apply(.foregroundColor, color ?? NSColor.textColor)
    }

    /// Выделение маркером. `nil` — снять.
    func setHighlight(_ color: NSColor?) {
        apply(.backgroundColor, color)
    }

    private func apply(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            if let value { view.typingAttributes[key] = value } else { view.typingAttributes.removeValue(forKey: key) }
            return
        }
        edit(range) {
            if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
        }
    }

    // MARK: - Таблица

    /// Таблица в месте курсора: ячейки — абзацы с `NSTextTableBlock`, как в
    /// TextEdit; по ним ходят стрелками, текст в ячейках правится как обычно.
    func insertTable(rows: Int, columns: Int) {
        guard let view = textView, let storage = view.textStorage else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        let result = NSMutableAttributedString()
        let location = view.selectedRange().location
        // Таблица начинается с новой строки.
        if location > 0, (storage.string as NSString).character(at: location - 1) != 0x0A {
            result.append(NSAttributedString(string: "\n", attributes: [.font: Self.bodyFont]))
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if row == 0 { block.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font = row == 0 ? NSFontManager.shared.convert(Self.bodyFont, toHaveTrait: .boldFontMask) : Self.bodyFont
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style,
                ]))
            }
        }
        // После таблицы — обычный абзац, чтобы было куда писать дальше.
        result.append(NSAttributedString(string: "\n", attributes: [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]))
        let range = NSRange(location: location, length: 0)
        edit(range) { storage.replaceCharacters(in: range, with: result) }
        view.setSelectedRange(NSRange(location: location + (result.string.hasPrefix("\n\n") ? 1 : 0), length: 0))
    }

    // MARK: - Начертания

    func toggleBold() { toggle(.boldFontMask) }
    func toggleItalic() { toggle(.italicFontMask) }

    private func toggle(_ trait: NSFontTraitMask) {
        guard let view = textView, let storage = view.textStorage else { return }
        let manager = NSFontManager.shared
        let range = view.selectedRange()
        func converted(_ font: NSFont, remove: Bool) -> NSFont {
            remove ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
        // Без выделения — меняем то, чем будет набираться дальше.
        guard range.length > 0 else {
            let font = view.typingAttributes[.font] as? NSFont ?? Self.bodyFont
            view.typingAttributes[.font] = converted(font, remove: manager.traits(of: font).contains(trait))
            return
        }
        let first = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? Self.bodyFont
        let remove = manager.traits(of: first).contains(trait)
        edit(range) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: converted(value as? NSFont ?? Self.bodyFont, remove: remove), range: sub)
            }
        }
    }

    func toggleUnderline() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else {
            let current = view.typingAttributes[.underlineStyle] as? Int ?? 0
            view.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return
        }
        let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        edit(range) {
            if current == 0 {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
            }
        }
    }

    /// Ссылка на выделенном тексте. Пустой адрес снимает ссылку.
    func applyLink(_ address: String) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(range) {
            if trimmed.isEmpty {
                storage.removeAttribute(.link, range: range)
            } else {
                // «x.ru» человек напишет чаще, чем «https://x.ru».
                let url = URL(string: trimmed).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(string: "https://" + trimmed)
                if let url { storage.addAttribute(.link, value: url, range: range) }
            }
        }
    }

    var hasSelection: Bool { (textView?.selectedRange().length ?? 0) > 0 }

    // MARK: - Списки

    /// Списки — метками в начале строк («• », «1. »): их видно и в тексте,
    /// и в текстовой копии письма, а в HTML они становятся `<ul>`/`<ol>`.
    func toggleList(numbered: Bool) {
        guard let view = textView, let storage = view.textStorage else { return }
        let string = view.string as NSString
        let paragraphs = string.paragraphRange(for: view.selectedRange())
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        if lines.isEmpty { lines = [NSRange(location: paragraphs.location, length: 0)] }

        let allMarked = lines.allSatisfy { Self.marker(in: string.substring(with: $0), numbered: numbered) != nil }
        edit(paragraphs) {
            // С конца, чтобы вставки не сдвигали ещё не тронутые строки.
            for (index, line) in lines.enumerated().reversed() {
                let text = string.substring(with: line)
                let existing = Self.marker(in: text, numbered: true) ?? Self.marker(in: text, numbered: false)
                let attributes = storage.length > 0
                    ? storage.attributes(at: min(line.location, storage.length - 1), effectiveRange: nil)
                    : [.font: Self.bodyFont]
                if let existing {
                    storage.replaceCharacters(in: NSRange(location: line.location, length: (existing as NSString).length), with: "")
                }
                if !allMarked {
                    let marker = numbered ? "\(index + 1). " : RichTextHTML.bullet
                    storage.insert(NSAttributedString(string: marker, attributes: attributes), at: line.location)
                }
            }
        }
    }

    static func marker(in line: String, numbered: Bool) -> String? {
        if numbered {
            guard let range = line.range(of: #"^\d+\. "#, options: .regularExpression) else { return nil }
            return String(line[range])
        }
        return line.hasPrefix(RichTextHTML.bullet) ? RichTextHTML.bullet : nil
    }

    /// Return в пункте списка продолжает список; Return в пустом пункте —
    /// заканчивает его, как в Mail и Pages.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let storage = textView.textStorage else { return false }
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)

        let marker = Self.marker(in: line, numbered: true) ?? Self.marker(in: line, numbered: false)
        guard let marker else { return false }
        if line == marker {
            edit(NSRange(location: paragraph.location, length: (marker as NSString).length)) {
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: (marker as NSString).length), with: "")
            }
            return true
        }
        var next = RichTextHTML.bullet
        if let number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
            next = "\(number + 1). "
        }
        textView.insertText("\n" + next, replacementRange: selection)
        return true
    }

    private func edit(_ range: NSRange, _ change: () -> Void) {
        guard let view = textView, let storage = view.textStorage,
              view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change()
        storage.endEditing()
        view.didChangeText()
    }
}

/// Поле ввода с оформлением.
struct RichTextEditorView: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = RichTextController.bodyFont
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.typingAttributes = [.font: RichTextController.bodyFont, .foregroundColor: NSColor.textColor]
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.delegate = controller
        controller.textView = text
        DispatchQueue.main.async { controller.focus() }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
