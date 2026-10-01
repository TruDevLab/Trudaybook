import AppKit
import Security
import TrudaybookCore

/// «Подключиться»: встреча Zoom или Teams — сразу в их приложении, мимо
/// браузера с его «Открыть zoom.us?».
///
/// Ссылка в схеме приложения несёт номер и пароль встречи, а схему
/// (`zoommtg:`, `msteams:`) может объявить своей любая программа. Поэтому
/// ссылка уходит только той, что подписана самим сервисом (требование из
/// `MeetingLink.NativeApp`); нет такой — как раньше, в браузер.
@MainActor
enum MeetingOpener {
    static func open(_ link: MeetingLink) {
        if let native = link.nativeApp, let app = trustedHandler(for: native) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // Именно проверенной программе, а не «кому система отдаст схему».
            NSWorkspace.shared.open([native.url], withApplicationAt: app, configuration: configuration) { _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    DebugLog.write("встреча: приложение \(link.provider.rawValue) не открылось — в браузер")
                    NSWorkspace.shared.open(link.url)
                }
            }
            DebugLog.write("встреча: в приложении \(link.provider.rawValue)")
            return
        }
        NSWorkspace.shared.open(link.url)
    }

    /// Программа для схемы — если она подписана тем, кем должна.
    /// Ресурсы пакета не перепроверяем (это секунды на каждое нажатие):
    /// важно, чей исполняемый файл, а целостность пакета стережёт macOS.
    private static func trustedHandler(for native: MeetingLink.NativeApp) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: native.url) else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(native.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            DebugLog.write("встреча: схему держит программа без подписи сервиса — в браузер")
            return nil
        }
        return app
    }
}
