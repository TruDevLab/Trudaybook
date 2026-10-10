import SwiftUI
import TrudaybookCore

/// Свёрнутая плашка «Кратко» над письмом: раскрыли — Trunook пересказывает.
///
/// Свёрнута всегда, пока её не раскроют: пересказ — это письмо, отданное
/// модели, и делать это без просьбы человека незачем. Готовый пересказ
/// помнится до перезапуска — раскрыть второй раз можно без ожидания.
struct SummaryPlaque: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var expanded = false

    var body: some View {
        let state = model.summaries[item.id]
        VStack(alignment: .leading, spacing: Space.md) {
            Button {
                withAnimation(HoverMotion.animation) { expanded.toggle() }
                if expanded { model.summarize(item) }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.cyan)
                    Text("Кратко").font(.callout.weight(.semibold))
                    Text("· ИИ").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if case .loading = state {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? String(localized: "Свернуть пересказ")
                           : String(localized: "Пересказ письма местной моделью на этом Mac"))

            if expanded {
                content(state)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.cyan.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Palette.cyan.opacity(0.18)))
        .onAppear {
            if model.options.summary, model.options.snapshotPath != nil {
                expanded = true
                model.summarize(item)
            }
        }
        // Раскрыли раньше, чем пришло тело письма, — просим, как только оно есть.
        .onChange(of: model.body != nil) { _, loaded in
            if loaded, expanded, model.summaries[item.id] == nil { model.summarize(item) }
        }
    }

    @ViewBuilder
    private func content(_ state: SummaryState?) -> some View {
        switch state {
        case .ready(let text):
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Пересказ модели — сверяйтесь с письмом.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Пересказать заново") { model.summarize(item, again: true) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        case let .failed(code, message):
            VStack(alignment: .leading, spacing: Space.xs) {
                InlineNotice(message, symbol: code == "cloud" ? "icloud.slash" : "exclamationmark.triangle.fill")
                    .font(.callout)
                if let advice = Self.advice(code) {
                    Text(advice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.xl) {
                    if code == "disabled" {
                        Button("Открыть настройки") { SettingsWindow.show(model: model, tab: .trunook) }
                    } else {
                        Button("Попробовать снова") { model.summarize(item, again: true) }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .loading, nil:
            HStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text("Модель читает письмо… Местной модели нужно до минуты.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func advice(_ code: String) -> String? {
        switch code {
        // Нет Ollama, нет модели, выключено — это уже сказано в самой причине.
        case "server":
            String(localized: "Проверьте модель в Настройках → ИИ или выберите другую.")
        default:
            nil
        }
    }
}

extension MailLabel {
    var tint: Color {
        switch self {
        case .important: Palette.rose
        case .conversation: Palette.blue
        case .notification: Palette.amber
        case .newsletter: Palette.violet
        }
    }
}

/// Метка в строке списка: цветная капсула со словом.
struct LabelTag: View {
    let label: MailLabel
    var source: MailLabelSource?

    var body: some View {
        Tag(text: label.singular, symbol: label.symbol, tint: label.tint, size: .compact)
            .help(Self.help(source))
    }

    static func help(_ source: MailLabelSource?) -> String {
        switch source {
        case .trunook: String(localized: "Метку поставила модель. Поменять — правой кнопкой по письму.")
        case .rule: String(localized: "Метка по заголовкам письма. Поменять — правой кнопкой по письму.")
        case .user, nil: String(localized: "Метку поставили вы.")
        }
    }
}

/// Выбор метки в контекстном меню письма. Выбор человека Trunook
/// потом не переписывает.
struct LabelPicker: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        if item.kind == .mail {
            Menu("Метка") {
                ForEach(MailLabel.allCases) { label in
                    Button {
                        model.setLabel(label, for: item.id)
                    } label: {
                        Label(label.singular, systemImage: model.label(of: item) == label ? "checkmark" : label.symbol)
                    }
                }
                Divider()
                Button("Без метки") { model.setLabel(nil, for: item.id) }
            }
        }
    }
}

/// Фильтр «Не разобрано» по меткам и кнопка «Разметить».
struct LabelFilterBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    chip(nil, title: String(localized: "Все"), count: model.unresolved.count)
                    ForEach(MailLabel.allCases) { label in
                        let count = model.unresolvedCount(label: label)
                        if count > 0 || model.labelFilter == label {
                            chip(label, title: label.title, count: count)
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            status
            if model.aiEnabled {
                Button {
                    model.labelUnresolved(manual: true)
                } label: {
                    Label("Разметить", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isRunning)
                .help("Модель разметит неразобранные письма: важное, переписка, уведомления, рассылки. Модель — только на этом Mac.")
            }
        }
    }

    private var isRunning: Bool {
        if case .running = model.labeling { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch model.labeling {
        case let .running(done, total):
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("\(done) из \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.warning)
                .help(message)
        case .finished, .idle:
            EmptyView()
        }
    }

    private func chip(_ label: MailLabel?, title: String, count: Int) -> some View {
        let selected = model.labelFilter == label
        let tint = label?.tint ?? Color.accentColor
        return Button {
            withAnimation(HoverMotion.animation) { model.labelFilter = selected ? nil : label }
        } label: {
            HStack(spacing: Space.xs) {
                if let label { Image(systemName: label.symbol).font(.app(.tiny, weight: .semibold)) }
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xxs)
            .foregroundStyle(selected ? tint : .primary)
            .background(Capsule().fill(selected ? tint.opacity(0.2) : Fill.faint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
