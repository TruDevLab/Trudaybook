import Foundation

/// Узел XML — ровно столько, сколько нужно для ответов EWS.
///
/// Имена — без приставки пространства имён (`t:Message` → `Message`):
/// в ответах Exchange приставки бывают разными, а совпадений имён между
/// пространствами, которые нам важны, нет.
struct XMLTreeNode: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [XMLTreeNode]
    var text: String

    /// Первый прямой потомок с таким именем.
    func child(_ name: String) -> XMLTreeNode? {
        children.first { $0.name == name }
    }

    func all(_ name: String) -> [XMLTreeNode] {
        children.filter { $0.name == name }
    }

    /// Путь по прямым потомкам: `node["Mailbox", "EmailAddress"]`.
    subscript(_ path: String...) -> XMLTreeNode? {
        var node: XMLTreeNode? = self
        for step in path { node = node?.child(step) }
        return node
    }

    /// Первый потомок на любой глубине.
    func first(_ name: String) -> XMLTreeNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    static func parse(_ data: Data) throws -> XMLTreeNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? String(localized: "пустой документ")
            throw MailNetworkError.protocolError(String(localized: "XML не разобран: \(reason)"))
        }
        return root
    }

    static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLTreeNode] = []
        var root: XMLTreeNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            var plain: [String: String] = [:]
            for (key, value) in attributes where !key.hasPrefix("xmlns") {
                plain[XMLTreeNode.localName(key)] = value
            }
            stack.append(XMLTreeNode(name: XMLTreeNode.localName(elementName), attributes: plain, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let finished = stack.popLast() else { return }
            if stack.isEmpty {
                root = finished
            } else {
                stack[stack.count - 1].children.append(finished)
            }
        }
    }
}

/// Экранирование текста и атрибутов для запросов.
enum XMLEscape {
    static func text(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
