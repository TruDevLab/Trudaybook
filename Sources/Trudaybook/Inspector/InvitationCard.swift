import SwiftUI
import TrudaybookCore

/// Приглашение на встречу в письме — как в Outlook: когда, где, кто зовёт,
/// свободно ли это время (кусочек календаря того дня) и ответ с комментарием.
struct InvitationCard: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    let invitation: Invitation
    @ViewState private var comment = ""

    var body: some View {
        let conflicts = invitation.conflicts(in: model.invitationDayEvents)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: invitation.method == .cancel ? "calendar.badge.minus" : "calendar.badge.clock")
                    .foregroundStyle(invitation.method == .cancel ? Palette.danger : Color.accentColor)
                Text(invitation.method == .cancel ? String(localized: "Встреча отменена") : String(localized: "Приглашение на встречу"))
                    .font(.headline)
                Spacer()
                if invitation.isRecurring {
                    Label("Повторяется", systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(invitation.summary)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: Space.xs) {
                Label(when, systemImage: "clock")
                if let location = invitation.location {
                    Label(location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
                }
                if let organizer = invitation.organizer {
                    Label("Организатор: \(organizer.display)", systemImage: "person")
                        .help(organizer.address ?? "")
                }
            }
            .font(.callout)

            if invitation.method == .cancel {
                CancellationActions(item: item, invitation: invitation)
            } else {
                availability(conflicts)
                InvitationDayStrip(invitation: invitation, events: model.invitationDayEvents, conflicts: conflicts)
                    .frame(height: 70)
                answer
            }
        }
        .padding(Space.xl)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Fill.accentFaint))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Fill.accent))
    }

    private var when: String {
        if invitation.isAllDay { return String(localized: "\(Format.dayTitle(invitation.start)) · весь день") }
        let sameDay = model.calendar.isDate(invitation.start, inSameDayAs: invitation.end)
        return sameDay
            ? "\(Format.dayTitle(invitation.start)) · \(Format.range(invitation.start, invitation.end))"
            : "\(Format.dayTitle(invitation.start)), \(Format.time(invitation.start)) — \(Format.dayTitle(invitation.end)), \(Format.time(invitation.end))"
    }

    @ViewBuilder
    private func availability(_ conflicts: [TimelineItem]) -> some View {
        if invitation.isAllDay {
            Label("Встреча на весь день", systemImage: "sun.max").font(.callout).foregroundStyle(.secondary)
        } else if conflicts.isEmpty {
            Label("Время свободно", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.success)
        } else {
            Label(String(localized: "Пересекается: ") + conflicts.map { "\($0.title) (\(Format.range($0.time, $0.end)))" }.joined(separator: ", "),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var answer: some View {
        if let response = model.invitationResponses[item.id] {
            Label("Ответ отправлен: \(response.subjectPrefix.lowercased())", systemImage: response.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(color(response))
        } else {
            // Безопасность: ответ уходит на адрес организатора из самого
            // приглашения. Если он не совпадает с отправителем письма —
            // говорим об этом прямо, до нажатия.
            if let organizer = invitation.organizer?.address, !(item.mail.map { sameAddress($0.from.address, organizer) } ?? false) {
                Label("Ответ уйдёт организатору \(organizer) — это не отправитель письма",
                      systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Комментарий организатору — необязательно", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Space.md) {
                ForEach(InvitationResponse.allCases) { response in
                    Button {
                        model.respond(response, comment: comment, to: item.id)
                    } label: {
                        Label(response.title, systemImage: response.symbol)
                    }
                    .buttonStyle(.bordered)
                    .tint(color(response))
                    .help(comment.isEmpty ? "\(response.title) и сообщить организатору"
                                          : "\(response.title) и отправить организатору комментарий")
                }
                if model.respondingTo == item.id { ProgressView().controlSize(.small) }
            }
            .disabled(model.respondingTo != nil)
        }
    }

    private func sameAddress(_ one: String?, _ other: String) -> Bool {
        one?.caseInsensitiveCompare(other) == .orderedSame
    }

    private func color(_ response: InvitationResponse) -> Color {
        switch response {
        case .accept: Palette.success
        case .tentative: Palette.warning
        case .decline: Palette.danger
        }
    }
}

/// Кусочек календаря дня встречи: два часа до и после, свои встречи серым
/// (пересекающиеся — оранжевым), приглашение — цветом акцента.
private struct InvitationDayStrip: View {
    @EnvironmentObject private var model: AppModel
    let invitation: Invitation
    let events: [TimelineItem]
    let conflicts: [TimelineItem]

    var body: some View {
        let dayStart = model.calendar.startOfDay(for: invitation.start)
        let hourOf = { (date: Date) in date.timeIntervalSince(dayStart) / 3600 }
        let from = max(floor(hourOf(invitation.start)) - 2, 0)
        let to = min(ceil(hourOf(invitation.end)) + 2, 24)
        let span = max(to - from, 1)
        let conflictIDs = Set(conflicts.map(\.id))
        let timed = events.filter { !$0.isAllDay }

        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (hour: Double) in CGFloat((min(max(hour, from), to) - from) / span) * width }
            ZStack(alignment: .topLeading) {
                // Часы.
                ForEach(Int(from)...Int(to), id: \.self) { hour in
                    Rectangle()
                        .fill(Fill.hover)
                        .frame(width: 1, height: 52)
                        .offset(x: x(Double(hour)))
                    Text(String(format: "%02d", hour % 24))
                        .font(.app(.tiny).monospacedDigit())
                        .foregroundStyle(.secondary)
                        // Последний час — подписью влево, чтобы не вылезал за край.
                        .offset(x: x(Double(hour)) + (Double(hour) == to ? -14 : 2), y: 54)
                }
                // Мой календарь — верхняя дорожка.
                ForEach(timed) { event in
                    let start = x(hourOf(event.time))
                    let end = x(hourOf(event.end ?? event.time.addingTimeInterval(1800)))
                    if end > start {
                        let clash = conflictIDs.contains(event.id)
                        Text(event.title)
                            .font(.app(.tiny, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, Space.xs)
                            .frame(width: end - start - 1, height: 20, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Radius.xs)
                                .fill(clash ? Palette.warning.opacity(0.35) : Fill.hover))
                            .offset(x: start, y: 2)
                            .help("\(event.title) · \(Format.range(event.time, event.end))")
                    }
                }
                // Приглашение — нижняя дорожка.
                let start = x(hourOf(invitation.start))
                let end = x(hourOf(invitation.end))
                Text(invitation.summary)
                    .font(.app(.tiny, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, Space.xs)
                    .frame(width: max(end - start - 1, 6), height: 20, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.xs).fill(Color.accentColor.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Color.accentColor, lineWidth: 1))
                    .offset(x: start, y: 28)
            }
        }
        .help("Ваш календарь в этот день; снизу — приглашение")
    }
}

/// Письмо об отмене: где эта встреча в календаре и кнопка убрать её оттуда
/// (письмо при этом уходит в архив).
private struct CancellationActions: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    let invitation: Invitation
    @ViewState private var target: TimelineItem?
    @ViewState private var lookedUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !lookedUp {
                ProgressView().controlSize(.small)
            } else if let target {
                Label(String(localized: "В календаре: \(target.title), \(Format.dayTitle(target.time)) \(Format.range(target.time, target.end))"),
                      systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if invitation.isSeriesCancellation, target.event?.isRecurring == true {
                    Label("Отменена вся серия — удалятся все её встречи", systemImage: "repeat")
                        .font(.caption).foregroundStyle(.secondary)
                }
                button(String(localized: "Удалить из календаря"), systemImage: "trash")
            } else {
                Label("В календаре этой встречи уже нет", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                button(String(localized: "В архив"), systemImage: "archivebox")
            }
        }
        .task(id: item.id) {
            lookedUp = false
            target = await model.cancelledEvent(for: invitation)
            lookedUp = true
        }
    }

    private func button(_ title: String, systemImage: String) -> some View {
        HStack {
            Button {
                model.removeCancelledMeeting(letterID: item.id, cancellation: invitation)
            } label: {
                if model.removingCancelled == item.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.danger)
            .disabled(model.removingCancelled != nil)
            Text("Письмо уйдёт в архив").font(.caption).foregroundStyle(.secondary)
        }
    }
}
