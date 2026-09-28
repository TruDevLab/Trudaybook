import SwiftUI
import TrudaybookWidgetUI
import WidgetKit

/// Расширение виджетов. Точка входа процесса — `_NSExtensionMain` (флаг
/// линковщика в Package.swift): она поднимает среду расширения и зовёт
/// этот `main`. Сам вид — в `TrudaybookWidgetUI`.
@main
struct TrudaybookWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        MailWidget()
    }
}
