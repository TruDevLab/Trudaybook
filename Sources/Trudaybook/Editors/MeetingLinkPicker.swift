import AppKit
import SwiftUI
import TrudaybookCore

/// Ссылка на созвон для встречи — под полем «Место»: свои постоянные,
/// из своих прошлых встреч и «создать новую» на сайте сервиса.
///
/// Новую встречу приложение само создать не может: для этого нужен вход
/// в Zoom, Google или Яндекс (`MeetingLinkHistory`). Поэтому кнопка открывает
/// страницу сервиса, а когда человек скопировал там ссылку и вернулся —
/// ссылка из буфера вставляется сама. Буфер читается только после такого
/// нажатия и только если в нём ссылка на созвон.
struct MeetingLinkPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var location: String
    let close: () -> Void

    @ViewState private var recent: [MeetingLinkHistory.Entry]?
    /// Открыли страницу «новая встреча» — ждём ссылку в буфере.
    @ViewState private var awaiting: MeetingLink.Provider?
    @ViewState private var pasteboardChange = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Ссылка на созвон").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .labelHelp(String(localized: "Скрыть"))
            }
            if !model.ownMeetingLinks.isEmpty {
                section(String(localized: "Мои ссылки")) {
                    ForEach(model.ownMeetingLinks, id: \.url) { link in
                        row(link, detail: link.url.host ?? "")
                    }
                }
            }
            section(String(localized: "Из моих встреч")) {
                if let recent {
                    if recent.isEmpty {
                        Text("В ваших встречах за три месяца ссылок нет.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(recent, id: \.link.url) { entry in
                        row(entry.link, detail: detail(of: entry))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            section(String(localized: "Новая встреча")) {
                HStack(spacing: Space.sm) {
                    ForEach(MeetingLinkHistory.newMeetingPages, id: \.provider) { page in
                        Button(page.provider.rawValue) { create(page.provider, page.url) }
                            .help("Откроется сайт \(page.provider.rawValue): создайте встречу и скопируйте ссылку — она вставится сюда сама")
                    }
                }
                if let awaiting {
                    HStack(spacing: Space.sm) {
                        InlineNotice(String(localized: "Скопируйте ссылку \(awaiting.rawValue) и вернитесь в это окно — она вставится сама."),
                                     symbol: "doc.on.clipboard", tint: .secondary)
                            .font(.caption)
                        Button("Вставить из буфера") { takeFromPasteboard(force: true) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Fill.faint))
        .task { recent = await model.recentMeetingLinks() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            takeFromPasteboard(force: false)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.caption).foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ link: MeetingLink, detail: String) -> some View {
        Button {
            choose(link.url)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "video.fill").foregroundStyle(Color.accentColor).frame(width: 18)
                Text(link.provider.rawValue).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
    }

    /// «Планёрка · Чт, 24 сент. · повторяется». Разовая встреча Zoom старше
    /// месяца — с предупреждением: такие ссылки Zoom закрывает.
    private func detail(of entry: MeetingLinkHistory.Entry) -> String {
        var parts = [entry.title, Format.shortDayTitle(entry.date)]
        if entry.recurring {
            parts.append(String(localized: "повторяется"))
        } else if entry.link.provider == .zoom, model.now.timeIntervalSince(entry.date) > 30 * 86_400 {
            parts.append(String(localized: "может уже не работать"))
        }
        return parts.joined(separator: " · ")
    }

    private func choose(_ url: URL) {
        location = MeetingLinkHistory.inserting(url, into: location)
        awaiting = nil
        close()
    }

    private func create(_ provider: MeetingLink.Provider, _ url: URL) {
        pasteboardChange = NSPasteboard.general.changeCount
        awaiting = provider
        NSWorkspace.shared.open(url)
    }

    /// Ссылка из буфера — только после «Новая встреча» и только новая
    /// (скопированная после нажатия), если не просили вставить явно.
    private func takeFromPasteboard(force: Bool) {
        guard awaiting != nil else { return }
        let pasteboard = NSPasteboard.general
        guard force || pasteboard.changeCount != pasteboardChange,
              let text = pasteboard.string(forType: .string),
              let link = MeetingLinkHistory.parse(text) else { return }
        DebugLog.write("ссылка на созвон из буфера: \(link.provider.rawValue)")
        choose(link.url)
    }
}
