import Foundation
import Security
import TrudaybookCore

/// Проверка, что скачанное подписано тем же, чем подписаны мы сами.
///
/// Главная проверка обновления — сильнее контрольной суммы. Сумму пишет
/// человек в описание выпуска, рядом со ссылкой на образ: кто подменит образ,
/// подменит и её. Закрытый ключ сертификата лежит только на машине
/// разработчика, и доступ к учётной записи GitHub его не даёт.
///
/// Требование к подписи — ровно тот предикат, по которому macOS решает,
/// переносить ли на новый бандл выданные доступы (Календарь, Напоминания,
/// пароли в Связке ключей). Прошла проверка — доступы останутся; не прошла —
/// подмена всё равно обнулила бы их.
enum CodeSignatureCheck {
    /// Бандл против **собственного** требования: `SecCodeCopySelf` — взгляд
    /// ядра на исполняемый код, а не чтение файлов с диска. Хеш сертификата
    /// в код не зашит.
    static func matchesSelf(_ bundle: URL) -> SignatureVerdict {
        guard let requirement = ownRequirement() else {
            DebugLog.write("обновление: своё требование к подписи не прочиталось")
            return .rejected(.damaged)
        }
        var candidate: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &candidate)
        guard created == errSecSuccess, let candidate else { return SignatureVerdict(status: created) }

        // Вложенный код тоже: без флага вложенные бандлы не проверяются вовсе.
        let flags = SecCSFlags(rawValue: UInt32(
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        ))
        var failure: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(candidate, flags, requirement, &failure)
        if status != errSecSuccess {
            let reason = failure?.takeRetainedValue().localizedDescription ?? "\(status)"
            DebugLog.write("обновление: подпись отклонена — \(reason)")
        }
        return SignatureVerdict(status: status)
    }

    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var still: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &still) == errSecSuccess, let still else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(still, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}

/// Монтирование образа с обновлением.
enum DiskImage {
    /// Только на чтение и без показа в Finder. `-mountrandom /private/tmp`
    /// вместо `/Volumes/Trudaybook 0.2.0`: имя тома предсказуемо, занять его
    /// заранее может кто угодно, и с ним же столкнулся бы том `make dmg`.
    static func attach(_ image: URL) -> MountedImage? {
        run(["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
             "-mountrandom", "/private/tmp", "-plist", image.path])
            .flatMap { MountedImage.parse(plist: $0) }
    }

    /// Оставленный том — не просто мусор: следующая попытка налетит на него.
    static func detach(_ image: MountedImage) {
        if run(["detach", "-quiet", image.mountPoint.path]) != nil { return }
        guard !image.device.isEmpty else { return }
        DebugLog.write("обновление: том не отмонтировался по точке, пробуем силой")
        _ = run(["detach", "-force", "-quiet", image.device])
    }

    /// Ровно одно приложение в корне: рядом лежат ярлык «Программ»
    /// и «Как установить.txt», и гадать между двумя `.app` нельзя.
    static func application(in mountPoint: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mountPoint, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let applications = contents.filter { $0.pathExtension == "app" }
        guard applications.count == 1 else {
            DebugLog.write("обновление: на образе приложений — \(applications.count), ждали одно")
            return nil
        }
        return applications[0]
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // На macOS 27 `hdiutil attach` пишет в поток ошибок, что команда
        // устарела. Это не ошибка, и в разбор plist оно попасть не должно.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DebugLog.write("обновление: hdiutil не запустился — \(error.localizedDescription)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DebugLog.write("обновление: hdiutil \(arguments.first ?? "") ответил \(process.terminationStatus)")
            return nil
        }
        return data
    }
}

/// Подмена работающего приложения новым и перезапуск.
///
/// Само себя приложение подменить не может: тот, кто зовёт `open`, обязан
/// пережить наш выход. Поэтому последний шаг делает отдельный процесс.
enum UpdateInstaller {
    /// Готовит копию рядом с целью и запускает подменщика. `nil` — подменщик
    /// пошёл, вызывающему остаётся только выйти.
    static func install(staged: URL, into target: URL) -> UpdateFailure? {
        // Подпись — вплотную перед копированием: папка заготовки доступна
        // на запись любому процессу пользователя, и бандл, пролежавший там
        // сутки, — удобное место подложить код, который мы же отнесём
        // в «Программы» и запустим с нашими доступами.
        if case let .rejected(reason) = CodeSignatureCheck.matchesSelf(staged) {
            DebugLog.write("обновление: подпись не сошлась перед самой установкой")
            return reason
        }

        let parent = target.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        // Точка в начале прячет заготовку от Finder на ту секунду, что она живёт.
        let prepared = parent.appendingPathComponent(".Trudaybook-update-\(pid).app")
        let backup = parent.appendingPathComponent(".Trudaybook-previous-\(pid).app")

        // Копия, пока приложение живо, — и есть настоящая проверка права
        // на запись. Не вышло — ничего не начиналось, приложение работает.
        // Вышло — оба переноса у подменщика идут по одному тому, мгновенным
        // `rename(2)`, а не копированием, во время которого приложения уже нет.
        try? FileManager.default.removeItem(at: prepared)
        do {
            try FileManager.default.copyItem(at: staged, to: prepared)
        } catch {
            DebugLog.write("обновление: заготовка не легла рядом с целью — \(error.localizedDescription)")
            return .notWritable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "trudaybook-update",
                             prepared.path, target.path, backup.path, String(pid)]
        do {
            try process.run()
        } catch {
            DebugLog.write("обновление: подменщик не запустился — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: prepared)
            return .installFailed
        }
        DebugLog.write("обновление: подменщик пошёл, выходим")
        return nil
    }

    /// Заготовки сорвавшейся установки. Старше часа — чтобы не тронуть ту,
    /// что прямо сейчас в работе.
    static func cleanLeftovers(near target: URL) {
        let parent = target.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for item in contents {
            let name = item.lastPathComponent
            guard name.hasPrefix(".Trudaybook-update-") || name.hasPrefix(".Trudaybook-previous-") else { continue }
            let changed = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(changed) > 3600 else { continue }
            DebugLog.write("обновление: убираем хвост прошлой попытки — \(name)")
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Тело подменщика.
    ///
    /// Файла на диске нет: текст уезжает аргументом `/bin/sh -c` — файл
    /// в `/tmp` можно подменить между записью и запуском, аргументы уже
    /// запущенного процесса нельзя. Подстановок в тексте тоже нет: пути едут
    /// позиционными аргументами и читаются только как `"$1"` в кавычках, иначе
    /// папка с `$(…)` в имени стала бы выполнением чужого кода.
    ///
    /// - `sleep 1` перед подменой: Launch Services не замечает мгновенную
    ///   (то же делает цель `install` в Makefile).
    /// - Откат встроен: старое уносится в сторону до того, как встанет новое,
    ///   и возвращается, если второй перенос не удался.
    /// - `open` без `-n`: при неудавшемся выходе иначе вышло бы две копии.
    /// - Журнал обязателен: приложения в этот миг уже нет.
    private static let script = """
    (
      exec >> "$HOME/Library/Logs/Trudaybook.log" 2>&1
      echo "[обновление] подменщик начал, цель $2"

      waited=0
      while kill -0 "$4" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 150 ]; then
          echo "[обновление] приложение не вышло за пятнадцать секунд, ничего не трогаем"
          rm -rf "$1"
          exit 1
        fi
        sleep 0.1
      done
      sleep 1

      if ! mv "$2" "$3"; then
        echo "[обновление] старое не сдвинулось, всё осталось на месте"
        rm -rf "$1"
        exit 1
      fi
      if ! mv "$1" "$2"; then
        echo "[обновление] новое не встало, возвращаем старое"
        mv "$3" "$2"
        exit 1
      fi

      rm -rf "$3"
      xattr -cr "$2" 2>/dev/null
      echo "[обновление] подменено, запускаем"
      /usr/bin/open "$2"

      sleep 3
      pgrep -x Trudaybook >/dev/null || echo "[обновление] после подмены не запустилось"
    ) &
    """
}
