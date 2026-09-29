import AppKit
import Carbon.HIToolbox
import Combine
import TrudaybookCore

/// ⌃⌥⌘J из любой программы — подключиться к текущей или ближайшей онлайн-встрече.
///
/// Через `RegisterEventHotKey` (Carbon): система сама ловит только это
/// сочетание и не требует разрешения «Универсального доступа». Монитор
/// всех нажатий (`NSEvent.addGlobalMonitor…`) видел бы любой набранный
/// текст, в том числе пароли, — такой путь нарочно не выбран.
@MainActor
final class MeetingHotKey {
    /// Показ в меню и настройках — те же клавиши, что регистрируются.
    static let title = "⌃⌥⌘J"
    static let menuKey = "j"
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    private static let keyCode = UInt32(kVK_ANSI_J)
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x5444_424B // 'TDBK'

    private let model: AppModel
    private let fallback: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var watch: AnyCancellable?
    /// Кому передать нажатие: обработчик Carbon — функция C без замыканий.
    nonisolated(unsafe) private static weak var current: MeetingHotKey?

    /// `fallback` — когда подключаться не к чему (показать окошко с днём).
    init(model: AppModel, fallback: @escaping () -> Void) {
        self.model = model
        self.fallback = fallback
        Self.current = self
        watch = model.$joinHotKey.sink { [weak self] enabled in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setEnabled(enabled) } }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled, hotKey == nil {
            if handler == nil {
                var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { MeetingHotKey.current?.join() }
                    }
                    return noErr
                }, 1, &type, nil, &handler)
            }
            let id = EventHotKeyID(signature: Self.signature, id: 1)
            let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
            // Сочетание заняла другая программа — сказать в журнале, не мешать запуску.
            if status != noErr { DebugLog.write("быстрое подключение: \(Self.title) занято (\(status))") }
        } else if !enabled, let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    /// Открыть ссылку текущей или ближайшей встречи сегодня; не к чему — окошко дня.
    func join() {
        Task {
            if let link = await model.nearestMeetingLink() {
                DebugLog.write("быстрое подключение: \(link.provider.rawValue)")
                NSWorkspace.shared.open(link.url)
            } else {
                NSSound.beep()
                fallback()
            }
        }
    }
}
