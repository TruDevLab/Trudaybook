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
    /// Выделение в поле — видно на любом фоне окна, в светлой и тёмной теме.
    static let selectionColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.6 : 0.4)
    }

    weak var textView: NSTextView?
    /// Текст поправил человек (или вставка с отменой) — для сохранения
    /// заметки. Загрузка через `load` сюда не приходит.
    var onChange: (() -> Void)?
    /// Правка выделенного моделью — пункт «ИИ» в меню правой кнопки.
    /// `nil` — пункта нет (заметки, выключенный ИИ).
    var onRewrite: ((ModelPrompts.Rewrite) -> Void)?
    /// Выделено ли что-то — для кнопки ИИ над полем.
    @Published private(set) var hasSelection = false

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
    /// Подпись с оформлением и картинками; `old` — прежняя подпись простым
    /// текстом (`string` вставленной), по нему её и находят в конце письма.
    func setSignature(_ new: NSAttributedString, replacing old: String?) {
        guard let textView, let storage = textView.textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        func block(_ text: NSAttributedString) -> NSAttributedString {
            guard text.length > 0 else { return NSAttributedString() }
            let result = NSMutableAttributedString(string: "\n\n", attributes: attributes)
            result.append(text)
            return result
        }
        let current = storage.string as NSString
        if let old, !old.isEmpty {
            let previous = ("\n\n" + old) as NSString
            guard current.hasSuffix(previous as String) else { return }
            let range = NSRange(location: current.length - previous.length, length: previous.length)
            edit(range) { storage.replaceCharacters(in: range, with: block(new)) }
        } else if new.length > 0 {
            let range = NSRange(location: current.length, length: 0)
            edit(range) { storage.replaceCharacters(in: range, with: block(new)) }
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

    /// Шаблон ответа — в начало письма, над уже написанным и подписью,
    /// с отменой по ⌘Z: человек может вернуть всё как было.
    func insertTemplate(_ text: String) {
        guard let textView, let storage = textView.textStorage, !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        // Пустое письмо с подписью начинается с «\n\n» подписи — отступ уже есть.
        let separator = storage.length == 0 || storage.string.hasPrefix("\n") ? "" : "\n\n"
        let range = NSRange(location: 0, length: 0)
        edit(range) { storage.replaceCharacters(in: range, with: NSAttributedString(string: text + separator, attributes: attributes)) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Заменить весь текст — заметка другого дня. Без отмены: ⌘Z не должен
    /// возвращать заметку соседнего дня.
    func load(_ text: NSAttributedString) {
        guard let textView, let storage = textView.textStorage else { return }
        storage.setAttributedString(text)
        textView.undoManager?.removeAllActions(withTarget: storage)
        textView.undoManager?.removeAllActions(withTarget: textView)
        textView.typingAttributes = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Вставить собранный текст (повестку, итоги) с отменой по ⌘Z.
    func insert(_ text: NSAttributedString, at location: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = NSRange(location: min(location, storage.length), length: 0)
        edit(range) { storage.replaceCharacters(in: range, with: text) }
        textView.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
    }

    // MARK: - Правка моделью

    /// Выделенный кусок — что отдать модели и куда потом вернуть ответ.
    func selection() -> (range: NSRange, text: String)? {
        guard let view = textView else { return nil }
        let range = view.selectedRange()
        guard range.length > 0 else { return nil }
        let text = (view.string as NSString).substring(with: range)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (range, text)
    }

    /// Поставить ответ модели на место выделенного, с отменой по ⌘Z.
    /// `false` — пока модель думала, этот кусок поправили руками:
    /// не затирать сделанное человеком.
    func replace(_ range: NSRange, expected: String, with text: String) -> Bool {
        guard let view = textView, let storage = view.textStorage, NSMaxRange(range) <= storage.length,
              (storage.string as NSString).substring(with: range) == expected else { return false }
        // Шрифт и цвет — как у начала выделенного: правка не должна
        // перекрашивать письмо в чужой цвет или размер.
        var attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        if range.length > 0 {
            let first = storage.attributes(at: range.location, effectiveRange: nil)
            if let font = first[.font] as? NSFont {
                attributes[.font] = NSFontManager.shared.convert(font, toNotHaveTrait: [.boldFontMask, .italicFontMask])
            }
            if let color = first[.foregroundColor] { attributes[.foregroundColor] = color }
        }
        edit(range) { storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes)) }
        let replaced = NSRange(location: range.location, length: (text as NSString).length)
        view.setSelectedRange(replaced)
        view.scrollRangeToVisible(replaced)
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let selected = (textView?.selectedRange().length ?? 0) > 0
        if selected != hasSelection { hasSelection = selected }
    }

    /// Меню правой кнопки: «ИИ» с правками выделенного — над пунктами системы.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard onRewrite != nil, selection() != nil else { return menu }
        let submenu = NSMenu()
        for action in ModelPrompts.Rewrite.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(rewriteFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            submenu.addItem(item)
        }
        let root = NSMenuItem(title: String(localized: "ИИ"), action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        root.submenu = submenu
        menu.insertItem(root, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func rewriteFromMenu(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let action = ModelPrompts.Rewrite(rawValue: raw) else { return }
        onRewrite?(action)
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

    // MARK: - Картинка

    /// Картинка из файла — в место курсора (подпись с логотипом). Пережимается:
    /// не шире 600 точек, на экране и в письме — до 300; метаданные снимка
    /// (а в фото бывают координаты съёмки) при этом не переносятся.
    @discardableResult
    func insertImage(from url: URL) -> Bool {
        guard let view = textView, let storage = view.textStorage,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
              let image = NSImage(contentsOf: url), let encoded = Self.encodeImage(image) else { return false }
        let wrapper = FileWrapper(regularFileWithContents: encoded.data)
        wrapper.preferredFilename = "image." + encoded.ext
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let scale = min(1, 300 / max(encoded.size.width, 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: (encoded.size.width * scale).rounded(),
                                   height: (encoded.size.height * scale).rounded())
        let piece = NSMutableAttributedString(attachment: attachment)
        piece.addAttributes([.font: Self.bodyFont, .foregroundColor: NSColor.textColor], range: NSRange(location: 0, length: piece.length))
        let range = view.selectedRange()
        edit(range) { storage.replaceCharacters(in: range, with: piece) }
        view.setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
        return true
    }

    /// Картинка заново: PNG (с прозрачностью) или JPEG, до 600 точек в ширину.
    /// `size` — размер в точках экрана.
    static func encodeImage(_ image: NSImage) -> (data: Data, ext: String, size: CGSize)? {
        let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .max { $0.width < $1.width } ?? image.size
        let source = pixels.width > 0 ? pixels : image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, 600 / source.width)
        let width = Int((source.width * scale).rounded()), height = max(Int((source.height * scale).rounded()), 1)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let transparent = image.representations.contains { $0.hasAlpha }
        let data = transparent
            ? bitmap.representation(using: .png, properties: [:])
            : bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        guard let data else { return nil }
        // На экране — вдвое меньше точек: снимок экрана Retina иначе вдвое крупнее.
        let points = image.size.width > 0 ? image.size : CGSize(width: width, height: height)
        let fit = min(1, CGFloat(width) / max(points.width, 1))
        return (data, transparent ? "png" : "jpg", CGSize(width: points.width * fit, height: points.height * fit))
    }

    // MARK: - Шрифт и размер

    /// Шрифт выделенного (или того, что будет набрано); `nil` — обычный,
    /// системный. Жирный и курсив остаются.
    func setFontFamily(_ family: String?) {
        let manager = NSFontManager.shared
        convertFonts { font in
            guard let family else {
                let traits = manager.traits(of: font).intersection([.boldFontMask, .italicFontMask])
                return manager.convert(NSFont.systemFont(ofSize: font.pointSize), toHaveTrait: traits)
            }
            return manager.convert(font, toFamily: family)
        }
    }

    /// Размер выделенного — у каждого куска свой шрифт, меняется только размер.
    func setFontSize(_ size: CGFloat) {
        convertFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    private func convertFonts(_ transform: (NSFont) -> NSFont) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else {
            view.typingAttributes[.font] = transform(view.typingAttributes[.font] as? NSFont ?? Self.bodyFont)
            return
        }
        edit(range) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                storage.addAttribute(.font, value: transform(value as? NSFont ?? Self.bodyFont), range: sub)
            }
        }
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

    // MARK: - Заголовок

    static let headingFont = NSFont.systemFont(ofSize: 16, weight: .bold)

    /// Строки выделения — заголовком или обратно обычным текстом. Жирный,
    /// а не полужирный: RTF заметки хранит только «жирный», и полужирный
    /// после перезапуска стал бы обычным.
    func toggleHeading() {
        guard let view = textView, let storage = view.textStorage else { return }
        let string = view.string as NSString
        let paragraphs = string.paragraphRange(for: view.selectedRange())
        guard paragraphs.length > 0 else {
            let font = view.typingAttributes[.font] as? NSFont ?? Self.bodyFont
            view.typingAttributes[.font] = font.pointSize > Self.bodyFont.pointSize ? Self.bodyFont : Self.headingFont
            return
        }
        let first = storage.attribute(.font, at: paragraphs.location, effectiveRange: nil) as? NSFont ?? Self.bodyFont
        let makeHeading = first.pointSize <= Self.bodyFont.pointSize
        edit(paragraphs) {
            storage.addAttribute(.font, value: makeHeading ? Self.headingFont : Self.bodyFont, range: paragraphs)
        }
        view.typingAttributes[.font] = makeHeading ? Self.headingFont : Self.bodyFont
    }

    // MARK: - Списки

    enum ListKind {
        case bullet, numbered, check
    }

    /// Списки — метками в начале строк («• », «1. »): их видно и в тексте,
    /// и в текстовой копии письма, а в HTML они становятся `<ul>`/`<ol>`.
    func toggleList(numbered: Bool) {
        toggleList(numbered ? .numbered : .bullet)
    }

    /// Пункты с галочкой «☐ »/«☑ » — в заметке: дела и напоминания дня.
    /// Галочка ставится щелчком (`NoteTextView`).
    func toggleList(_ kind: ListKind) {
        guard let view = textView, let storage = view.textStorage else { return }
        let string = view.string as NSString
        let paragraphs = string.paragraphRange(for: view.selectedRange())
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            lines.append(range)
        }
        if lines.isEmpty { lines = [NSRange(location: paragraphs.location, length: 0)] }

        let allMarked = lines.allSatisfy { Self.marker(in: string.substring(with: $0), kind: kind) != nil }
        edit(paragraphs) {
            // С конца, чтобы вставки не сдвигали ещё не тронутые строки.
            for (index, line) in lines.enumerated().reversed() {
                let text = string.substring(with: line)
                let existing = Self.anyMarker(in: text)
                let attributes = storage.length > 0
                    ? storage.attributes(at: min(line.location, storage.length - 1), effectiveRange: nil)
                    : [.font: Self.bodyFont]
                if let existing {
                    storage.replaceCharacters(in: NSRange(location: line.location, length: (existing as NSString).length), with: "")
                }
                if !allMarked {
                    let marker = switch kind {
                    case .numbered: "\(index + 1). "
                    case .bullet: RichTextHTML.bullet
                    case .check: NoteMarkers.unchecked
                    }
                    storage.insert(NSAttributedString(string: marker, attributes: attributes), at: line.location)
                }
            }
        }
    }

    static func marker(in line: String, numbered: Bool) -> String? {
        marker(in: line, kind: numbered ? .numbered : .bullet)
    }

    static func marker(in line: String, kind: ListKind) -> String? {
        switch kind {
        case .numbered:
            guard let range = line.range(of: #"^\d+\. "#, options: .regularExpression) else { return nil }
            return String(line[range])
        case .bullet:
            return line.hasPrefix(RichTextHTML.bullet) ? RichTextHTML.bullet : nil
        case .check:
            if line.hasPrefix(NoteMarkers.unchecked) { return NoteMarkers.unchecked }
            return line.hasPrefix(NoteMarkers.checked) ? NoteMarkers.checked : nil
        }
    }

    static func anyMarker(in line: String) -> String? {
        marker(in: line, kind: .numbered) ?? marker(in: line, kind: .bullet) ?? marker(in: line, kind: .check)
    }

    /// Щелчок по галочке в начале строки: ☐ ↔ ☑. `false` — там не галочка.
    func toggleCheckbox(at index: Int) -> Bool {
        guard let view = textView, let storage = view.textStorage, index < storage.length else { return false }
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: index, length: 0))
        guard index == paragraph.location else { return false }
        let box = string.substring(with: NSRange(location: index, length: 1))
        let replacement: String
        switch box {
        case "☐": replacement = "☑"
        case "☑": replacement = "☐"
        default: return false
        }
        let range = NSRange(location: index, length: 1)
        let attributes = storage.attributes(at: index, effectiveRange: nil)
        edit(range) { storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes)) }
        return true
    }

    /// Return в пункте списка продолжает список; Return в пустом пункте —
    /// заканчивает его, как в Mail и Pages.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let storage = textView.textStorage else { return false }
        let string = textView.string as NSString
        let selection = textView.selectedRange()
        let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)

        guard let marker = Self.anyMarker(in: line) else { return false }
        if line == marker {
            edit(NSRange(location: paragraph.location, length: (marker as NSString).length)) {
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: (marker as NSString).length), with: "")
            }
            return true
        }
        var next = RichTextHTML.bullet
        if let number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
            next = "\(number + 1). "
        } else if marker == NoteMarkers.unchecked || marker == NoteMarkers.checked {
            // Следующее дело — ещё не сделано.
            next = NoteMarkers.unchecked
        }
        textView.insertText("\n" + next, replacementRange: selection)
        return true
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
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
    /// Белый лист: поле в светлом виде в любой теме — тёмный текст на белом.
    var onWhite = false

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
        // Системное выделение — бледно-голубое: на фоне «Небо» и поле, и
        // выделение голубые, и выделенного не видно. Цвет акцента плотнее.
        text.selectedTextAttributes = [.backgroundColor: RichTextController.selectionColor]
        text.delegate = controller
        controller.textView = text
        DispatchQueue.main.async { controller.focus() }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        // Цвет текста в поле — системный, он сам темнеет на светлом виде.
        let appearance = onWhite ? NSAppearance(named: .aqua) : nil
        if view.appearance != appearance { view.appearance = appearance }
    }
}

/// Кнопки оформления — общие у ответа и у заметки. У жирного, курсива
/// и подчёркивания — привычные ⌘B, ⌘I, ⌘U.
struct RichFormatControls: View {
    let editor: RichTextController
    /// Заголовок и дела с галочкой — в заметке; в письме их нет.
    var noteTools = false
    /// Картинка из файла — в подписи (логотип).
    var images = false

    var body: some View {
        RichFormatButton(symbol: "bold", help: String(localized: "Жирный (⌘B)"), key: "b") { editor.toggleBold() }
        RichFormatButton(symbol: "italic", help: String(localized: "Курсив (⌘I)"), key: "i") { editor.toggleItalic() }
        RichFormatButton(symbol: "underline", help: String(localized: "Подчёркнутый (⌘U)"), key: "u") { editor.toggleUnderline() }
        if noteTools {
            RichFormatButton(symbol: "textformat.size", help: String(localized: "Заголовок")) { editor.toggleHeading() }
        }
        Divider().frame(height: 16).padding(.horizontal, Space.xs)
        RichFormatButton(symbol: "list.bullet", help: String(localized: "Маркированный список")) { editor.toggleList(.bullet) }
        RichFormatButton(symbol: "list.number", help: String(localized: "Нумерованный список")) { editor.toggleList(.numbered) }
        if noteTools {
            RichFormatButton(symbol: "checklist", help: String(localized: "Список дел с галочками")) { editor.toggleList(.check) }
        }
        Divider().frame(height: 16).padding(.horizontal, Space.xs)
        // Шрифт и размер: шрифты — те, что есть почти у всех получателей.
        Menu {
            Button("Обычный") { editor.setFontFamily(nil) }
            Divider()
            ForEach(RichTextHTML.fontStacks, id: \.family) { font in
                Button(font.family) { editor.setFontFamily(font.family) }
            }
        } label: {
            Image(systemName: "textformat").frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Шрифт"))
        Menu {
            ForEach(TextPalette.fontSizes, id: \.self) { size in
                Button(size == RichTextHTML.bodySize ? String(localized: "\(Int(size)) — обычный") : "\(Int(size))") {
                    editor.setFontSize(size)
                }
            }
        } label: {
            Image(systemName: "textformat.size.larger").frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Размер шрифта"))
        Divider().frame(height: 16).padding(.horizontal, Space.xs)
        // Цвет текста, цвет фона (маркер), таблица.
        Menu {
            ForEach(TextPalette.text, id: \.name) { choice in
                Button { editor.setTextColor(choice.color) } label: {
                    Label { Text(choice.name) } icon: { ColorDot.image(choice.rgb) }
                }
            }
            Divider()
            Button("Обычный цвет") { editor.setTextColor(nil) }
        } label: {
            Image(systemName: "character.textbox").frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Цвет текста"))
        Menu {
            ForEach(TextPalette.highlight, id: \.name) { choice in
                Button { editor.setHighlight(choice.color) } label: {
                    Label { Text(choice.name) } icon: { ColorDot.image(choice.rgb) }
                }
            }
            Divider()
            Button("Без цвета фона") { editor.setHighlight(nil) }
        } label: {
            Image(systemName: "highlighter").frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Цвет фона текста (маркер)"))
        Menu {
            ForEach(TextPalette.tableSizes, id: \.self) { size in
                Button("\(size.columns) × \(size.rows)") { editor.insertTable(rows: size.rows, columns: size.columns) }
            }
        } label: {
            Image(systemName: "tablecells").frame(width: 26, height: 22)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Вставить таблицу (столбцы × строки)"))
        if images {
            RichFormatButton(symbol: "photo", help: String(localized: "Вставить картинку (логотип) — до 300 точек в ширину")) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url, !editor.insertImage(from: url) {
                    NSSound.beep()
                }
            }
        }
    }
}

extension ModelPrompts.Rewrite {
    var title: String {
        switch self {
        case .fix: String(localized: "Исправить ошибки")
        case .improve: String(localized: "Улучшить написание")
        case .structure: String(localized: "Улучшить формат и структуру")
        case .shorter: String(localized: "Сократить")
        case .formal: String(localized: "Деловой тон")
        case .friendly: String(localized: "Дружелюбный тон")
        }
    }

    var symbol: String {
        switch self {
        case .fix: "textformat.abc"
        case .improve: "wand.and.stars"
        case .structure: "list.bullet.indent"
        case .shorter: "text.badge.minus"
        case .formal: "briefcase"
        case .friendly: "face.smiling"
        }
    }
}

struct RichFormatButton: View {
    let symbol: String
    let help: String
    var key: KeyEquivalent?
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        // Без стекла — кнопки лежат на стеклянной панели; под курсором — заливка.
        let button = Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovered ? Fill.hover : .clear))
                .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .labelHelp(help)
        if let key {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }
}
