import Foundation
import Security
import Testing
@testable import TrudaybookCore

@Suite("Номер версии")
struct AppVersionTests {
    private func version(_ text: String) throws -> AppVersion {
        try #require(AppVersion(text))
    }

    @Test("0.10.0 новее 0.9.0, хотя строкой это не так")
    func десятаяНовееДевятой() throws {
        #expect(try version("0.9.0") < version("0.10.0"))
        #expect("0.9.0" > "0.10.0")
    }

    @Test("Тег с «v» сравнивается с версией из бандла")
    func тегИБандл() throws {
        #expect(try version("0.1.0") < version("v0.2.0"))
        #expect(try version("v0.1.0") == version("0.1.0"))
    }

    @Test("0.2 и 0.2.0 — одна версия, четвёртая часть учитывается")
    func нулиИЧасти() throws {
        #expect(try version("0.2") == version("0.2.0"))
        #expect(try version("0.2.0") < version("0.2.0.1"))
    }

    @Test("Мусор версией не становится")
    func мусор() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("не версия") == nil)
        #expect(AppVersion("v") == nil)
    }

    @Test("Предрелиз младше выпуска, а номер сборки в скобках — не предрелиз")
    func хвосты() throws {
        #expect(try version("0.2.0-beta.1") < version("0.2.0"))
        #expect(try version("0.1.0 (2609261522)") == version("0.1.0"))
        #expect(try version("v0.2.0").text == "0.2.0")
    }
}

@Suite("Выпуск на GitHub")
struct GitHubReleaseTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let hash = "40878e06d03f113d5cb89a2278075f51f5cef3d54998516372a4e3188febc1f5"

    @Test("Выпуск разбирается целиком")
    func выпускРазбирается() throws {
        let release = try #require(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","draft":false,"prerelease":false,
         "html_url":"https://github.com/TruDevLab/Trudaybook/releases/tag/v0.2.0",
         "body":"## Установка\\n\\n`shasum -a 256`:\\n`\(hash)`\\n",
         "assets":[{"name":"Trudaybook-0.2.0.dmg","size":3557214,
           "browser_download_url":"https://github.com/TruDevLab/Trudaybook/releases/download/v0.2.0/Trudaybook-0.2.0.dmg"}]}
        """)))
        #expect(release.tag == "v0.2.0")
        #expect(release.version.text == "0.2.0")
        #expect(release.assetName == "Trudaybook-0.2.0.dmg")
        #expect(release.assetSize == 3_557_214)
        #expect(release.checksum == hash)
        #expect(release.pageURL?.lastPathComponent == "v0.2.0")
    }

    @Test("Образ находится среди чужих ассетов")
    func образСредиЧужих() throws {
        let release = try #require(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","assets":[
          {"name":"checksums.txt","size":80,"browser_download_url":"https://example.com/checksums.txt"},
          {"name":"Trudaybook-0.2.0.dmg","size":10,"browser_download_url":"https://example.com/Trudaybook-0.2.0.dmg"}]}
        """)))
        #expect(release.assetName == "Trudaybook-0.2.0.dmg")
    }

    @Test("Без образа, черновик, предрелиз и не https — не выпуск")
    func негодные() {
        #expect(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","assets":[{"name":"Notes.txt","size":80,"browser_download_url":"https://example.com/Notes.txt"}]}
        """)) == nil)
        #expect(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","draft":true,"assets":[{"name":"a.dmg","size":1,"browser_download_url":"https://example.com/a.dmg"}]}
        """)) == nil)
        #expect(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","prerelease":true,"assets":[{"name":"a.dmg","size":1,"browser_download_url":"https://example.com/a.dmg"}]}
        """)) == nil)
        #expect(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","assets":[{"name":"a.dmg","size":1,"browser_download_url":"http://example.com/a.dmg"}]}
        """)) == nil)
    }

    @Test("Пустой и негодный ответ не роняют разбор")
    func негодныйОтвет() {
        #expect(GitHubRelease.parse(data("{}")) == nil)
        #expect(GitHubRelease.parse(data("не json вовсе")) == nil)
        #expect(GitHubRelease.parse(data("[]")) == nil)
    }

    @Test("Описание без суммы оставляет выпуск годным")
    func безСуммы() throws {
        let release = try #require(GitHubRelease.parse(data("""
        {"tag_name":"v0.2.0","body":"Просто описание.",
         "assets":[{"name":"a.dmg","size":1,"browser_download_url":"https://example.com/a.dmg"}]}
        """)))
        #expect(release.checksum == nil)
    }

    @Test("Сумма находится при любой разметке, похожее на сумму — не берётся")
    func сумма() {
        #expect(GitHubRelease.checksum(inBody: "SHA-256 = \(hash)") == hash)
        #expect(GitHubRelease.checksum(inBody: hash.uppercased()) == hash)
        #expect(GitHubRelease.checksum(inBody: String(repeating: "z", count: 64)) == nil)
        #expect(GitHubRelease.checksum(inBody: String(repeating: "a", count: 128)) == nil)
        #expect(GitHubRelease.checksum(inBody: String(repeating: "a", count: 63)) == nil)
    }
}

@Suite("Когда проверять обновления")
struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(last: Date?, enabled: Bool = true, manual: Bool = false) -> Bool {
        UpdateSchedule.shouldCheck(now: now, last: last, enabled: enabled, manual: manual)
    }

    @Test("Ни разу — проверяем; сутки — пора; без пяти минут — ещё нет")
    func сроки() {
        #expect(check(last: nil))
        #expect(check(last: now.addingTimeInterval(-UpdateSchedule.interval)))
        #expect(!check(last: now.addingTimeInterval(-UpdateSchedule.interval + 300)))
    }

    @Test("Рукой — всегда, выключено — само не ходит")
    func рукойИВыключено() {
        #expect(check(last: now, manual: true))
        #expect(check(last: now, enabled: false, manual: true))
        #expect(!check(last: nil, enabled: false))
    }

    @Test("Дата из будущего не запирает проверку")
    func датаИзБудущего() {
        #expect(check(last: now.addingTimeInterval(30 * 24 * 3600)))
    }

    /// Собравший из исходников своим сертификатом не должен качать каждые
    /// сутки ту же версию ради того же отказа.
    @Test("Отвергнутую за подпись версию сама служба не качает, рукой — качает")
    func отвергнутая() throws {
        let version = try #require(AppVersion("0.2.0"))
        #expect(!UpdateSchedule.shouldDownload(version, rejected: "0.2.0", manual: false))
        #expect(UpdateSchedule.shouldDownload(version, rejected: "0.2.0", manual: true))
        #expect(UpdateSchedule.shouldDownload(version, rejected: "0.1.5", manual: false))
        #expect(UpdateSchedule.shouldDownload(version, rejected: nil, manual: false))
    }
}

@Suite("Куда ставить обновление")
struct InstallTargetTests {
    private func target(_ path: String, writable: Bool = true) -> InstallTarget {
        InstallTarget.decide(bundleURL: URL(fileURLWithPath: path), parentIsWritable: writable)
    }

    @Test("«Программы» и домашняя папка годятся")
    func годится() {
        #expect(target("/Applications/Trudaybook.app") == .ready(URL(fileURLWithPath: "/Applications/Trudaybook.app")))
        let home = "/Users/кто-то/Applications/Trudaybook.app"
        #expect(target(home) == .ready(URL(fileURLWithPath: home)))
    }

    @Test("С образа и из карантина переноса ставить нечего")
    func сОбраза() {
        #expect(target("/Volumes/Trudaybook 0.2.0/Trudaybook.app") == .refused(.notInstalled))
        #expect(target("/private/var/folders/x/AppTranslocation/ABC/d/Trudaybook.app") == .refused(.notInstalled))
    }

    @Test("Без права на запись — отказ, а не запрос пароля")
    func безПрава() {
        #expect(target("/Applications/Trudaybook.app", writable: false) == .refused(.notWritable))
    }
}

@Suite("Образ с обновлением")
struct MountedImageTests {
    private func plist(_ entities: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
        \(entities)
        </array></dict></plist>
        """.utf8)
    }

    private let volume = """
    <dict><key>content-hint</key><string>Apple_HFS</string>
    <key>dev-entry</key><string>/dev/disk4s1</string>
    <key>mount-point</key><string>/private/tmp/dmg.f3KfGl</string></dict>
    """

    private let scheme = """
    <dict><key>content-hint</key><string>GUID_partition_scheme</string>
    <key>dev-entry</key><string>/dev/disk4</string></dict>
    """

    @Test("Точка и устройство читаются, схема разделов впереди не сбивает")
    func точка() throws {
        for order in [volume + scheme, scheme + volume] {
            let image = try #require(MountedImage.parse(plist: plist(order)))
            #expect(image.mountPoint.path == "/private/tmp/dmg.f3KfGl")
            #expect(image.device == "/dev/disk4s1")
        }
    }

    @Test("Без тома — ничего")
    func безТома() {
        #expect(MountedImage.parse(plist: plist(scheme)) == nil)
        #expect(MountedImage.parse(plist: Data("не plist".utf8)) == nil)
    }
}

@Suite("Подпись и строка состояния обновления")
struct UpdateVerdictAndStatusTests {
    @Test("Успех, нет подписи, чужой сертификат, незнакомое — разные исходы")
    func подпись() {
        #expect(SignatureVerdict(status: errSecSuccess) == .valid)
        #expect(SignatureVerdict(status: errSecCSUnsigned) == .rejected(.unsigned))
        #expect(SignatureVerdict(status: errSecCSReqFailed) == .rejected(.wrongCertificate))
        #expect(SignatureVerdict(status: errSecCSSignatureFailed) == .rejected(.damaged))
        #expect(SignatureVerdict(status: -12345) == .rejected(.damaged))
    }

    private func release() throws -> GitHubRelease {
        try #require(GitHubRelease.parse(Data("""
        {"tag_name":"v0.2.0","assets":[{"name":"a.dmg","size":1,"browser_download_url":"https://example.com/a.dmg"}]}
        """.utf8)))
    }

    @Test("Готовому — установка, в работе — кнопка выключена, после отказа — повтор")
    func кнопки() throws {
        let ready = UpdateStatusLine.line(for: .ready(try release(), staged: URL(fileURLWithPath: "/tmp/Trudaybook.app")))
        #expect(ready.action == .install)
        #expect(ready.text.contains("0.2.0"))
        #expect(UpdateStatusLine.line(for: .checking).action == .busy)
        #expect(UpdateStatusLine.line(for: .installing).action == .busy)
        let loading = UpdateStatusLine.line(for: .downloading(try release(), progress: 0.42))
        #expect(loading.action == .busy)
        #expect(loading.text.contains("42"))
        #expect(UpdateStatusLine.line(for: .failed(.network)).action == .check)
    }

    @Test("У каждой причины отказа есть текст")
    func тексты() {
        for reason in UpdateFailure.allCases {
            #expect(!reason.message.isEmpty)
        }
        #expect(UpdateFailure.wrongCertificate.advice != nil)
    }
}
