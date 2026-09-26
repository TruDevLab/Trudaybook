import Foundation
import Testing
@testable import TrudaybookCore

/// Письмо из строк: перевод строки — CRLF, как на проводе.
private func message(_ lines: [String]) -> Data {
    Data(lines.joined(separator: "\r\n").utf8)
}

@Suite("Заголовки")
struct MIMEHeaderTests {
    @Test func encodedWordsInKOI8AndSplitUTF8() {
        #expect(MIME.decodeWords("=?koi8-r?B?79Teo9Qg2sEgy9fB0tTBzA==?=") == "Отчёт за квартал")
        // Две половины одной темы: пробел между ними не значащий.
        let split = "=?utf-8?B?0KHQvtCz0LvQsNGB0L7QstCw0L3QuNC1IA==?=\r\n =?utf-8?B?0LHRjtC00LbQtdGC0LA=?="
        #expect(MIME.decodeWords(split) == "Согласование бюджета")
        #expect(MIME.decodeWords("Re: =?utf-8?Q?=D0=9F=D1=80=D0=B8=D0=B2=D0=B5=D1=82_=D0=BC=D0=B8=D1=80?=") == "Re: Привет мир")
        #expect(MIME.decodeWords("Обычная тема") == "Обычная тема")
    }

    @Test func foldedHeadersAreJoined() {
        let headers = MIME.parseHeaders(message(["Subject: первая", "\tвторая", "To: a@x.ru", ""]))
        #expect(headers["subject"] == "первая вторая")
        #expect(headers["TO"] == "a@x.ru")
    }

    @Test func addresses() {
        let people = MIME.parseAddresses(
            #""Иванов, Иван" <i@x.ru>, =?utf-8?B?0J7Qu9GM0LPQsCDQodC80LjRgNC90L7QstCw?= <olga@x.ru>, b@x.ru (Боб), plain@x.ru"#
        )
        #expect(people == [
            Person(name: "Иванов, Иван", address: "i@x.ru"),
            Person(name: "Ольга Смирнова", address: "olga@x.ru"),
            Person(name: "Боб", address: "b@x.ru"),
            Person(name: nil, address: "plain@x.ru"),
        ])
        #expect(MIME.parseAddresses("undisclosed-recipients:;").isEmpty)
        #expect(MIME.parseAddresses("Команда: a@x.ru, b@x.ru;").compactMap(\.address) == ["a@x.ru", "b@x.ru"])
    }

    @Test func dates() {
        let expected = Date(timeIntervalSince1970: 1_790_158_530) // 23.09.2026 10:15:30 UTC
        #expect(MIME.parseDate("Wed, 23 Sep 2026 13:15:30 +0300") == expected)
        #expect(MIME.parseDate("23 Sep 2026 10:15:30 +0000 (UTC)") == expected)
        #expect(MIME.parseDate("Wed,  23 Sep 2026 13:15:30 +0300 (MSK)") == expected)
        #expect(MIME.parseDate("чепуха") == nil)
    }

    @Test func parametersWithRFC2231Filename() {
        let type = MIME.parseParameterized(
            "application/pdf; name*=utf-8''%D0%94%D0%BE%D0%B3%D0%BE%D0%B2%D0%BE%D1%80%2E%70%64%66"
        )
        #expect(type.type == "application/pdf")
        #expect(type.parameters["name"] == "Договор.pdf")

        let split = MIME.parseParameterized(#"attachment; filename*0*=utf-8''%D0%94%D0%BE; filename*1*=%D0%B3.txt"#)
        #expect(split.parameters["filename"] == "Дог.txt")

        let quoted = MIME.parseParameterized(#"text/plain; charset="KOI8-R"; format=flowed"#)
        #expect(quoted.charset == "KOI8-R")
        #expect(quoted.parameters["format"] == "flowed")
    }

    @Test func messageHeaderFields() {
        let parsed = ParsedMessage(headerData: message([
            "From: =?utf-8?B?0J7Qu9GM0LPQsCDQodC80LjRgNC90L7QstCw?= <olga@x.ru>",
            "To: me@x.ru",
            "Subject: =?koi8-r?B?79Teo9Qg2sEgy9fB0tTBzA==?=",
            "Message-ID: <abc@x.ru>",
            "References: <r1@x.ru>",
            " <r2@x.ru>",
            "Date: Wed, 23 Sep 2026 13:15:30 +0300",
            "",
            "тело",
        ]))
        #expect(parsed.from == Person(name: "Ольга Смирнова", address: "olga@x.ru"))
        #expect(parsed.subject == "Отчёт за квартал")
        #expect(parsed.messageID == "abc@x.ru")
        #expect(parsed.references == ["r1@x.ru", "r2@x.ru"])
        #expect(parsed.date == Date(timeIntervalSince1970: 1_790_158_530))
    }
}

@Suite("Тело письма")
struct MIMEBodyTests {
    @Test func windows1251QuotedPrintable() {
        let body = ParsedMessage.body(of: message([
            "Content-Type: text/plain; charset=windows-1251",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "=C4=EE=E1=F0=FB=E9 =E4=E5=ED=FC! =D1=F7=B8=F2 =E2=EE =E2=EB=EE=E6=E5=ED=E8=",
            "=E8.",
        ]))
        #expect(body.text == "Добрый день! Счёт во вложении.")
        #expect(body.html == nil)
    }

    @Test func alternativeWithAttachmentAndInlineImage() {
        let body = ParsedMessage.body(of: message([
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "--outer",
            "Content-Type: multipart/related; boundary=\"rel\"",
            "",
            "--rel",
            "Content-Type: multipart/alternative; boundary=alt",
            "",
            "--alt",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Привет, мир",
            "--alt",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            "PHA+0J/RgNC40LLQtdGCLCA8Yj7QvNC40YA8L2I+PC9wPg==",
            "--alt--",
            "--rel",
            "Content-Type: image/png",
            "Content-ID: <logo@x>",
            "Content-Transfer-Encoding: base64",
            "",
            "iVBORw0KGgo=",
            "--rel--",
            "--outer",
            "Content-Type: application/pdf; name*=utf-8''%D0%94%D0%BE%D0%B3%D0%BE%D0%B2%D0%BE%D1%80%2E%70%64%66",
            "Content-Disposition: attachment",
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0=",
            "--outer--",
            "",
        ]))
        #expect(body.text == "Привет, мир")
        #expect(body.html == "<p>Привет, <b>мир</b></p>")
        #expect(body.attachments.map(\.name) == ["Договор.pdf"])
        #expect(body.attachments.first?.data == Data("%PDF-".utf8))
    }

    @Test func inlineImageIsEmbeddedIntoHTML() {
        let body = ParsedMessage.body(of: message([
            "Content-Type: multipart/related; boundary=rel",
            "",
            "--rel",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<img src=\"cid:logo@x\">",
            "--rel",
            "Content-Type: image/png",
            "Content-ID: <logo@x>",
            "Content-Transfer-Encoding: base64",
            "",
            "iVBORw0KGgo=",
            "--rel--",
        ]))
        #expect(body.html == "<img src=\"data:image/png;base64,iVBORw0KGgo=\">")
        #expect(body.attachments.isEmpty)
    }

    @Test func unknownCharsetFallsBackToUTF8ThenCP1251() {
        let cp1251 = "Привет".data(using: .windowsCP1251)!
        #expect(MIME.decode(cp1251, charset: "x-unknown") == "Привет")
        #expect(MIME.decode(Data("Привет".utf8), charset: nil) == "Привет")
    }

    @Test func boundaryInsideLineIsNotADelimiter() {
        let parts = MIMEPart.splitMultipart(Data("--b\r\nтекст --b внутри\r\n--b\r\nвторая\r\n--b--".utf8), boundary: "b")
        #expect(parts.count == 2)
        #expect(String(decoding: parts[0], as: UTF8.self) == "текст --b внутри")
    }
}
