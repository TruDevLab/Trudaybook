import Foundation
import TrudaybookWidgetUI

/// Виджеты в PNG без установки: `TrudaybookWidgetPreview <папка>`.
@main
enum WidgetPreviewTool {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("использование: TrudaybookWidgetPreview <папка>")
            exit(1)
        }
        WidgetPreview.render(to: URL(fileURLWithPath: arguments[1]))
    }
}
