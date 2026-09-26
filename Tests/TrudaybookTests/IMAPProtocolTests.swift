import Foundation
import Testing
@testable import TrudaybookMail

private func parse(_ text: String) throws -> IMAPResponse {
    try IMAPParser.parse(Data(text.utf8))
}

@Suite("Разбор ответов IMAP")
struct IMAPParserTests {
    @Test func taggedAndStatus() throws {
        #expect(try parse("a1 OK [READ-WRITE] SELECT completed\r\n")
                == .tagged(tag: "a1", status: "OK", code: "READ-WRITE", text: "SELECT completed"))
        #expect(try parse("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n")
                == .status(status: "OK", code: "UIDVALIDITY 3857529045", text: "UIDs valid"))
        #expect(try parse("a2 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
                == .tagged(tag: "a2", status: "NO", code: "AUTHENTICATIONFAILED", text: "Invalid credentials"))
        #expect(try parse("+ idling\r\n") == .continuation("idling"))
    }

    @Test func existsAndSearch() throws {
        #expect(try parse("* 18 EXISTS\r\n") == .data([.atom("18"), .atom("EXISTS")]))
        #expect(try parse("* SEARCH 4 9 12\r\n") == .data([.atom("SEARCH"), .atom("4"), .atom("9"), .atom("12")]))
    }

    @Test func fetchWithLiteralHeader() throws {
        let header = "Subject: Привет\r\nFrom: a@x.ru\r\n\r\n"
        let size = header.utf8.count
        let raw = "* 12 FETCH (UID 345 FLAGS (\\Seen \\Answered) INTERNALDATE \"23-Sep-2026 13:15:30 +0300\" "
            + "RFC822.SIZE 2048 BODY[HEADER.FIELDS (SUBJECT FROM)] {\(size)}\r\n\(header))\r\n"
        #expect(IMAPParser.pendingLiteral(in: Data("… BODY[HEADER] {\(size)}\r\n".utf8)) == size)

        guard case .data(let values) = try parse(raw), let fetch = IMAPFetch(values) else {
            Issue.record("не разобрался FETCH")
            return
        }
        #expect(fetch.sequence == 12)
        #expect(fetch.uid == 345)
        #expect(fetch.flags == ["\\Seen", "\\Answered"])
        #expect(fetch.size == 2048)
        #expect(fetch.internalDate == Date(timeIntervalSince1970: 1_790_158_530))
        #expect(fetch.section("BODY[HEADER") == Data(header.utf8))
    }

    @Test func listWithSpecialUseAndUTF7() throws {
        guard case .data(let values) = try parse(#"* LIST (\HasNoChildren \Sent) "/" "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-""# + "\r\n"),
              let mailbox = IMAPMailbox(values) else {
            Issue.record("не разобрался LIST")
            return
        }
        #expect(mailbox.displayName == "Отправленные")
        #expect(mailbox.has("\\sent"))
        #expect(mailbox.isSelectable)

        guard case .data(let noselect) = try parse(#"* LIST (\Noselect) "." Work.Projects"# + "\r\n"),
              let parent = IMAPMailbox(noselect) else { return }
        #expect(!parent.isSelectable)
        #expect(parent.displayName == "Projects")
    }

    @Test func nilAndQuotedEscapes() throws {
        guard case .data(let values) = try parse(#"* LIST () NIL "Say \"hi\"""# + "\r\n") else { return }
        #expect(values[2] == .nil_)
        #expect(values[3].text == "Say \"hi\"")
    }

    @Test func unbalancedListThrows() {
        #expect(throws: IMAPParseError.self) { try parse("* 1 FETCH (UID 5\r\n") }
    }
}

@Suite("Вспомогательное IMAP")
struct IMAPHelpersTests {
    @Test func modifiedUTF7RoundTrip() {
        #expect(ModifiedUTF7.encode("Архив") == "&BBAEQARFBDgEMg-")
        #expect(ModifiedUTF7.decode("&BBAEQARFBDgEMg-") == "Архив")
        #expect(ModifiedUTF7.encode("Q&A") == "Q&-A")
        #expect(ModifiedUTF7.decode("Q&-A") == "Q&A")
        #expect(ModifiedUTF7.decode("INBOX") == "INBOX")
    }

    @Test func uidSetCompressesRanges() {
        #expect(IMAPArgument.uidSet([5, 1, 2, 3, 8, 10, 11]) == "1:3,5,8,10:11")
        #expect(IMAPArgument.uidSet([7]) == "7")
    }

    @Test func quotingAndLiteralNeed() {
        #expect(IMAPArgument.quoted(#"pa"ss\w"#) == #""pa\"ss\\w""#)
        #expect(IMAPArgument.needsLiteral("пароль"))
        #expect(!IMAPArgument.needsLiteral("password"))
    }
}
