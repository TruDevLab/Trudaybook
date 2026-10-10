import AppKit
import SwiftUI
import TrudaybookCore

/// Раздел «Телефон»: учётная запись SIP, звонок, связь с Trunook.
struct PhoneSettingsView: View {
    @ObservedObject var phone: PhoneService
    @ViewState private var draft = SIPAccount()
    @ViewState private var password = ""
    @ViewState private var passwordChanged = false
    @ViewState private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            SettingsCard(title: String(localized: "Телефон SIP"), icon: "phone.fill") {
                HStack(spacing: Space.lg) {
                    Toggle("Звонить и принимать звонки в Trudaybook", isOn: $phone.enabled)
                        .toggleStyle(.switch)
                    Spacer()
                    RegistrationBadge(state: phone.registration, enabled: phone.enabled, user: phone.account.username)
                }
                SettingsHint(String(localized: "Кнопка «Телефон» в панели действий открывает набор номера, недавние звонки и сохранённые номера справа, на месте письма или встречи."))
            }

            SettingsCard(title: String(localized: "Учётная запись"), icon: "person.crop.circle") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                    GridRow {
                        Text("АТС").foregroundStyle(.secondary)
                        TextField("pbx.company.ru или 10.0.0.5:5060", text: $draft.server)
                    }
                    GridRow {
                        Text("Добавочный").foregroundStyle(.secondary)
                        TextField("101 — номер или логин", text: $draft.username)
                    }
                    GridRow {
                        Text("Пароль").foregroundStyle(.secondary)
                        SecureField(phone.hasPassword && !passwordChanged ? String(localized: "сохранён в Связке ключей") : String(localized: "пароль SIP"),
                                    text: $password)
                            .onChange(of: password) { passwordChanged = true }
                    }
                    GridRow {
                        Text("Имя").foregroundStyle(.secondary)
                        TextField("как вас покажут тому, кому звоните", text: $draft.displayName)
                    }
                    GridRow {
                        Text("Соединение").foregroundStyle(.secondary)
                        Picker("", selection: $draft.transport) {
                            Text("UDP").tag(SIPTransportKind.udp)
                            Text("TCP").tag(SIPTransportKind.tcp)
                            Text("TLS").tag(SIPTransportKind.tls)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .textFieldStyle(.roundedBorder)

                if draft.transport == .tls {
                    Toggle("Шифровать разговор (SRTP)", isOn: $draft.srtp)
                        .toggleStyle(.checkbox)
                    SettingsHint(String(localized: "Сертификат сервера проверяется как обычно; самоподписанный macOS не примет."))
                } else {
                    InlineNotice(String(localized: "Без TLS пароль не уходит, но номера и сам разговор идут по сети открыто. В офисной сети так обычно и бывает; для звонков через интернет выберите TLS."),
                                 symbol: "lock.open", tint: Palette.warning)
                        .font(.callout)
                }

                CollapsibleSettingsCard(title: String(localized: "Дополнительно"), icon: "slider.horizontal.3") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                        GridRow {
                            Text("Логин").foregroundStyle(.secondary)
                            TextField("если для входа не добавочный", text: $draft.authUsername)
                        }
                        GridRow {
                            Text("Прокси").foregroundStyle(.secondary)
                            TextField("исходящий прокси: host:port", text: $draft.proxy)
                        }
                        GridRow {
                            Text("Регистрация").foregroundStyle(.secondary)
                            Picker("", selection: $draft.expires) {
                                ForEach([60, 120, 300, 600, 1800, 3600], id: \.self) { seconds in
                                    Text(seconds < 120 ? String(localized: "раз в \(seconds) с") : String(localized: "раз в \(seconds / 60) мин"))
                                        .tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    if changed {
                        Text("Есть несохранённые изменения").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(phone.isRegistered && !changed ? String(localized: "Переподключить") : String(localized: "Сохранить и подключить")) {
                        let enable = !phone.enabled
                        phone.update(draft, password: passwordChanged ? password : nil)
                        password = ""
                        passwordChanged = false
                        if enable { phone.enabled = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isComplete)
                }
            }

            SettingsCard(title: String(localized: "Звонок"), icon: "bell.and.waves.left.and.right") {
                HStack(spacing: Space.md) {
                    Toggle("Звук входящего", isOn: $phone.ringSound)
                    Picker("", selection: $phone.ringtone) {
                        ForEach(PhoneTones.Ringtone.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!phone.ringSound)
                    Button { phone.previewRingtone() } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                        .disabled(!phone.ringSound)
                        .labelHelp(String(localized: "Послушать"))
                }
                SettingsHint(String(localized: "Входящий звонок показывается окошком в правом верхнем углу экрана — поверх всех окон."))
                Toggle("Подавлять эхо", isOn: $phone.echoCancellation)
                SettingsHint(String(localized: "Нужно, когда говорите без наушников: иначе собеседник слышит себя из ваших динамиков."))
            }
            .toggleStyle(.checkbox)

            SettingsCard(title: "Trunook", icon: "rectangle.topthird.inset.filled") {
                PhoneTrunookStatus()
            }

            SettingsCard(title: String(localized: "Журнал"), icon: "clock.arrow.circlepath") {
                HStack {
                    Text("Звонков в журнале: \(phone.book.calls.count), сохранённых номеров: \(phone.book.contacts.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Очистить журнал") { phone.clearHistory() }
                        .disabled(phone.book.calls.isEmpty)
                }
                SettingsHint(String(localized: "Журнал и номера хранятся только на этом Mac."))
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = phone.account
        }
    }

    private var changed: Bool { draft != phone.account || passwordChanged }
}

/// Покажет ли Trunook звонки Trudaybook в вырезе.
private struct PhoneTrunookStatus: View {
    @ViewState private var calls = PhoneTrunookStatus.callsEnabled

    /// Выключатель «Входящие звонки» в настройках Trunook.
    static var callsEnabled: Bool {
        UserDefaults(suiteName: TrunookLink.bundleID)?.bool(forKey: "callsEnabled") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if TrunookLink.appURL == nil {
                Label("Trunook не установлен — звонки покажет только окошко Trudaybook.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if calls {
                Label("Входящие покажутся и в вырезе Trunook — с кнопками «Ответить» и «Отклонить».", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
            } else {
                Label("Чтобы звонок был виден в вырезе, включите в Trunook: Настройки → Уведомления → Входящие звонки.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Palette.warning)
            }
            SettingsHint(String(localized: "Trunook видит окошко звонка через Универсальный доступ: кто звонит, читает из его заголовка, а «Принять» и «Отклонить» нажимает в нём сам. Разговор ему не передаётся. Нужен Trunook, который знает Trudaybook."))
            HStack {
                TrunookAppButton()
                Button("Проверить ещё раз") { calls = Self.callsEnabled }
                    .controlSize(.small)
                Spacer()
            }
        }
        .font(.callout)
    }
}
