import AppKit
import SwiftUI
import TrudaybookCore

/// Входящий звонок — плавающее окошко в правом верхнем углу экрана,
/// поверх всех окон и рабочих столов, не отнимая фокус у того, в чём работают.
///
/// Его же узнаёт Trunook (`CallService`, список `CallApp.known`): заголовок
/// окна — кто звонит, у кнопок постоянные подписи для Универсального
/// доступа — «Принять звонок» и «Отклонить звонок». По ним Trunook
/// рисует свою плашку звонка и нажимает здесь, а когда окно закрывается —
/// убирает её. Подписи менять только вместе с Trunook.
@MainActor
enum IncomingCallWindow {
    private static var panel: NSPanel?

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? { panel?.isVisible == true ? panel : nil }

    static let size = NSSize(width: 380, height: 92)

    static func show(_ phone: PhoneService) {
        guard let call = phone.call else { return }
        close()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = phone.name(for: call)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: IncomingCallView(phone: phone))
        // Иначе вид подгоняет окно под себя вместе с местом заголовка.
        hosting.sizingOptions = []
        panel.contentView = hosting
        // Рамка — ровно по окошку: окно с заголовком добавило бы его высоту
        // пустой полосой снизу.
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12,
                              width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

private struct IncomingCallView: View {
    @ObservedObject var phone: PhoneService

    var body: some View {
        let call = phone.call
        let name = call.map(phone.name(for:)) ?? ""
        let number = call?.remoteUser ?? ""
        HStack(spacing: Space.xl) {
            Avatar(name: name == number ? nil : name, size: 44)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Входящий звонок")
                    .font(.app(.label))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.app(.large, weight: .semibold))
                    .lineLimit(1)
                if name != number {
                    Text(number)
                        .font(.app(.text))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            CircleCallButton(symbol: "phone.down.fill", tint: Palette.danger,
                             label: String(localized: "Отклонить звонок")) { phone.hangup() }
            CircleCallButton(symbol: "phone.fill", tint: Palette.success,
                             label: String(localized: "Принять звонок")) {
                phone.answer()
                phone.model?.phoneOpen = true
                LetterWindow.showMainWindow()
            }
        }
        .padding(.horizontal, Space.xxl)
        .frame(width: IncomingCallWindow.size.width, height: IncomingCallWindow.size.height)
        .background(GlassPanelBackground(cornerRadius: Radius.xl))
        // Заголовок окна скрыт, но место под него осталось бы пустой полосой.
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Щелчок мимо кнопок — показать звонок в окне Trudaybook.
        .onTapGesture {
            phone.model?.phoneOpen = true
            LetterWindow.showMainWindow()
        }
    }
}

/// Круглая кнопка окошка звонка. Подпись для Универсального доступа —
/// постоянная: по ней кнопку находит Trunook.
private struct CircleCallButton: View {
    let symbol: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(.large, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}
