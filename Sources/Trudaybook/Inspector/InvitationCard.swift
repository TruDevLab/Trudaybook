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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: invitation.method == .cancel ? "calendar.badge.minus" : "calendar.badge.clock")
                    .foregroundStyle(invitation.method == .cancel ? Color.red : Color.accentColor)
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
            VStack(alignment: .leading, spacing: 4) {
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

            if invitation.method != .cancel {
                availability(conflicts)
                InvitationDayStrip(invitation: invitation, events: model.invitationDayEvents, conflicts: conflicts)
                    .frame(height: 70)
                answer
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
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
                .foregroundStyle(.green)
        } else {
            Label(String(localized: "Пересекается: ") + conflicts.map { "\($0.title) (\(Format.range($0.time, $0.end)))" }.joined(separator: ", "),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
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
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Комментарий организатору — необязательно", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
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
        case .accept: .green
        case .tentative: .orange
        case .decline: .red
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
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 52)
                        .offset(x: x(Double(hour)))
                    Text(String(format: "%02d", hour % 24))
                        .font(.system(size: 9).monospacedDigit())
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
                            .font(.system(size: 9.5, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(width: end - start - 1, height: 20, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(clash ? Color.orange.opacity(0.35) : Color.primary.opacity(0.14)))
                            .offset(x: start, y: 2)
                            .help("\(event.title) · \(Format.range(event.time, event.end))")
                    }
                }
                // Приглашение — нижняя дорожка.
                let start = x(hourOf(invitation.start))
                let end = x(hourOf(invitation.end))
                Text(invitation.summary)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: max(end - start - 1, 6), height: 20, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1))
                    .offset(x: start, y: 28)
            }
        }
        .help("Ваш календарь в этот день; снизу — приглашение")
    }
}
