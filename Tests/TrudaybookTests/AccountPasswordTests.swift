import Foundation
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

@Suite struct AccountPasswordTests {
    private let gmail = MailPreset.gmail.account(email: "me@gmail.com", name: "Я")
    private let exchange = MailAccount(email: "me@corp.test", displayName: "Я", imapHost: "mail.corp.test",
                                       imapUser: "me", smtpHost: "mail.corp.test", smtpPort: 587,
                                       smtpSecurity: .startTLS, smtpUser: "me", kind: .exchange)

    @Test func appPasswordLosesAllSpaces() {
        // Так копируется пароль из окна Google: неразрывные пробелы и перевод строки.
        #expect(MailAccounts.cleanPassword("abcd\u{00A0}efgh ijkl\u{2009}mnop\n", for: gmail) == "abcdefghijklmnop")
        #expect(MailAccounts.cleanPassword("\u{200B}abcdefghijklmnop", for: gmail) == "abcdefghijklmnop")
    }

    @Test func ordinaryPasswordKeepsItsSpaces() {
        #expect(MailAccounts.cleanPassword(" my pass word \n", for: exchange) == " my pass word ")
    }

    @Test func gmailRefusalsAreExplained() {
        let appPassword = MailAccounts.describe(MailNetworkError.authentication(
            "[ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)"))
        #expect(appPassword.contains("apppasswords"))
        let tooMany = MailAccounts.describe(MailNetworkError.authentication("[ALERT] Too many simultaneous connections. (Failure)"))
        #expect(tooMany.contains("15"))
        let other = MailAccounts.describe(MailNetworkError.authentication("[AUTHENTICATIONFAILED] Invalid credentials (Failure)"))
        #expect(other.contains("логин и пароль"))
    }
}
