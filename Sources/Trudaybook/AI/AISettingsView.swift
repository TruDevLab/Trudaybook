import SwiftUI
import TrudaybookCore

/// Настройки → ИИ: Ollama (поставить, запустить), какой моделью отвечать
/// (рекомендованные — скачать одной кнопкой) и что ИИ делает в приложении.
///
/// Перенесено из Trunook: там это жило в его настройках, а Trudaybook
/// просил его модель. Теперь модель — своя, и настраивается здесь.
struct AISettingsView: View {
    @ObservedObject var ai: LocalAI

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            engineCard
            modelsCard
            featuresCard
        }
        // Пока движка нет или он поднимается — смотреть чаще: человек мог
        // поставить или запустить Ollama сам, не нажимая у нас.
        .task {
            while !Task.isCancelled {
                await ai.refresh()
                try? await Task.sleep(for: .seconds(ai.isRunning ? 15 : 3))
            }
        }
    }

    // MARK: - Ollama

    private var engineCard: some View {
        SettingsCard(title: "Ollama", icon: "cpu") {
            switch ai.engine {
            case .checking:
                HStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Проверяю Ollama…").foregroundStyle(.secondary)
                }
            case .notInstalled:
                Text("Ollama не установлена.")
                HStack(spacing: Space.md) {
                    Button("Установить Ollama") { ai.installOllama() }
                        .buttonStyle(.borderedProminent)
                    Link("ollama.com", destination: OllamaInstaller.page)
                }
                SettingsHint(String(localized: "Бесплатный движок моделей: всё считается на этом Mac, письма в интернет не уходят. Скачается образ с ollama.com и ляжет в «Программы»."))
            case .installing(let step):
                installing(step)
            case .cliOnly:
                Text("Ollama из Homebrew не запущена.")
                SettingsHint(String(localized: "Выполните «ollama serve» или «brew services start ollama» в Терминале."))
            case .stopped:
                Text("Ollama установлена, но не запущена.")
                Button("Запустить Ollama") { ai.startOllama() }
                SettingsHint(String(localized: "Когда модель нужна, Trudaybook запускает Ollama сам."))
            case .starting:
                HStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Запускаю Ollama…").foregroundStyle(.secondary)
                }
            case .running(let version):
                Label(version.isEmpty ? String(localized: "Ollama работает") : String(localized: "Ollama работает · \(version)"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
            }
        }
    }

    @ViewBuilder
    private func installing(_ step: OllamaInstaller.Step) -> some View {
        switch step {
        case .downloading(let share):
            HStack(spacing: Space.md) {
                ProgressView(value: share).frame(maxWidth: 260)
                Text("Скачиваю \(Int(share * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button("Отменить") { ai.cancelInstall() }
            }
        case .verifying:
            HStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text("Проверяю подпись…").foregroundStyle(.secondary)
            }
        case .copying:
            HStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text("Кладу в «Программы»…").foregroundStyle(.secondary)
            }
        case .failed(let reason):
            InlineNotice(reason)
            HStack(spacing: Space.md) {
                Button("Ещё раз") { ai.installOllama() }
                Link("ollama.com", destination: OllamaInstaller.page)
            }
        }
    }

    // MARK: - Модели

    private var machine: (ram: Int64, disk: Int64) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return (Int64(ProcessInfo.processInfo.physicalMemory), Int64(free))
    }

    private var modelsCard: some View {
        let machine = machine
        let advised = ai.recommended
        return SettingsCard(title: String(localized: "Модель"), icon: "square.stack.3d.up") {
            ForEach(Ollama.catalogue) { offer in
                offerRow(offer, advised: advised.tag == offer.tag, fit: Ollama.fit(offer, ram: machine.ram, freeDisk: machine.disk))
                if offer.id != Ollama.catalogue.last?.id { Divider() }
            }
            if let problem = ai.pullProblem {
                InlineNotice(String(localized: "Модель не скачалась: \(problem)"))
            }
            if !ai.localModels.isEmpty {
                Divider()
                HStack {
                    Text("Отвечает")
                    Spacer(minLength: Space.xl)
                    Picker("", selection: $ai.selectedModel) {
                        Text("Подобрать самим").tag(String?.none)
                        ForEach(ai.localModels) { model in
                            Text(model.name).tag(Optional(model.name))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsHint(ai.activeModel.map { String(localized: "Сейчас отвечает \($0). Облачные модели Ollama не предлагаются: с ними письма ушли бы в интернет.") }
                             ?? String(localized: "Скачайте одну из моделей выше."))
            }
        }
        .disabled(!ai.isRunning && ai.engine != .stopped)
    }

    private func offerRow(_ offer: Ollama.Offer, advised: Bool, fit: Ollama.Fit) -> some View {
        let installed = ai.installed.contains { Ollama.same($0.name, offer.tag) }
        let selected = ai.activeModel.map { Ollama.same($0, offer.tag) } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(Self.title(offer.tier)).fontWeight(.semibold)
                    Text(offer.tag).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if selected {
                        Tag(text: String(localized: "Отвечает"), tint: Palette.success, size: .compact)
                    } else if advised {
                        Tag(text: String(localized: "Рекомендуем"), tint: Color.accentColor, size: .compact)
                    }
                }
                Text(Self.detail(offer.tier)).font(.caption).foregroundStyle(.secondary)
                if !installed, let warning = Self.warning(fit) {
                    Text(warning).font(.caption).foregroundStyle(Palette.warning)
                }
            }
            Spacer(minLength: Space.md)
            Text(ByteCountFormatter.string(fromByteCount: offer.bytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            action(offer, installed: installed, selected: selected, fit: fit)
                .frame(minWidth: 110, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func action(_ offer: Ollama.Offer, installed: Bool, selected: Bool, fit: Ollama.Fit) -> some View {
        if let pulling = ai.pulling, Ollama.same(pulling.tag, offer.tag) {
            ProgressView(value: pulling.share).frame(width: 110)
        } else if installed {
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Palette.success)
            } else {
                // Скачанную даём выбрать и тогда, когда порог не сошёлся:
                // человек знает про свою машину больше нас.
                Button("Выбрать") { ai.selectedModel = offer.tag }
            }
        } else if case .needsRAM = fit {
            Text("не по силам").font(.caption).foregroundStyle(.tertiary)
        } else {
            Button("Скачать") { ai.pull(offer.tag) }
                .disabled(ai.pulling != nil)
        }
    }

    static func title(_ tier: Ollama.Offer.Tier) -> String {
        switch tier {
        case .light: String(localized: "Лёгкая")
        case .medium: String(localized: "Средняя")
        case .powerful: String(localized: "Мощная")
        }
    }

    static func detail(_ tier: Ollama.Offer.Tier) -> String {
        switch tier {
        case .light: String(localized: "Отвечает сразу, но в длинных письмах ошибается чаще.")
        case .medium: String(localized: "Справляется со всем: пересказ, метки, повестка, чат.")
        case .powerful: String(localized: "Пишет по-русски чище всех. Нужен запас памяти.")
        }
    }

    static func warning(_ fit: Ollama.Fit) -> String? {
        switch fit {
        case .fits: return nil
        case .needsRAM(let ram):
            return String(localized: "Нужно \(ByteCountFormatter.string(fromByteCount: ram, countStyle: .memory)) памяти")
        case .needsDisk(let short):
            return String(localized: "Не хватает \(ByteCountFormatter.string(fromByteCount: short, countStyle: .file)) на диске")
        }
    }

    // MARK: - Что делает ИИ

    private var featuresCard: some View {
        SettingsCard(title: String(localized: "ИИ в Trudaybook"), icon: "sparkles") {
            Toggle("Пересказ, метки, шаблон ответа, повестка и чат", isOn: $ai.enabled)
            Toggle("Размечать новые письма сами", isOn: $ai.autoLabel)
                .padding(.leading, Space.section)
                .disabled(!ai.enabled)
            SettingsHint(String(localized: "Отвечает только модель на этом Mac — письма и заметки в интернет не уходят. Отправить письмо или создать встречу ИИ может только после вашего подтверждения."))
        }
        .toggleStyle(.checkbox)
    }
}
