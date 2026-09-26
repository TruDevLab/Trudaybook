// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Тесты собираются и без Xcode. У Command Line Tools макросы swift-testing
// лежат в `plugins/testing`, а не в `plugins`, где их ищет компилятор.
// Пути добавляются, только если такая раскладка на машине действительно есть:
// у того, кто собирает с Xcode, всё лежит внутри Xcode.app.
let toolsRoot = "/Library/Developer/CommandLineTools"
let usesCommandLineTools = FileManager.default.fileExists(
    atPath: "\(toolsRoot)/usr/lib/swift/host/plugins/testing"
)

let testingSwiftSettings: [SwiftSetting] = usesCommandLineTools
    ? [.unsafeFlags([
        "-plugin-path", "\(toolsRoot)/usr/lib/swift/host/plugins/testing",
        "-F", "\(toolsRoot)/Library/Developer/Frameworks",
      ])]
    : []

let testingLinkerSettings: [LinkerSetting] = usesCommandLineTools
    ? [.unsafeFlags([
        "-F", "\(toolsRoot)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(toolsRoot)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(toolsRoot)/Library/Developer/usr/lib",
      ])]
    : []

let package = Package(
    name: "Trudaybook",
    platforms: [.macOS(.v15)],
    // Внешних зависимостей нет. swift-nio-imap пробовали: сам он пишет о себе
    // «not ready for production», а его API требует склейки NIO с async.
    // Сетевой слой — URLSessionStreamTask: он умеет TLS сразу и STARTTLS
    // посреди соединения, этого хватает и IMAP, и SMTP.
    targets: [
        // Логика без интерфейса: модель, правила статусов, раскладка
        // таймлайна, хранилище, разбор MIME, источники данных. Всё, что можно
        // проверить тестом, живёт здесь.
        .target(
            name: "TrudaybookCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Сетевая почта: IMAP, SMTP, учётные записи, кэш писем. Разбор
        // протокола отделён от сети и проверяется на записанных ответах.
        .target(
            name: "TrudaybookMail",
            dependencies: ["TrudaybookCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Trudaybook",
            dependencies: ["TrudaybookCore", "TrudaybookMail"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TrudaybookTests",
            dependencies: ["TrudaybookCore", "TrudaybookMail"],
            swiftSettings: [.swiftLanguageMode(.v5)] + testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
    ]
)
