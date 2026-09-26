import SwiftUI

/// Замена `@State` для сборки без Xcode.
///
/// В этом SDK `@State` — макрос, а его плагин `SwiftUIMacros` поставляется
/// только с Xcode: с Command Line Tools любое `@State` валит сборку
/// («external macro implementation type 'SwiftUIMacros.StateMacro' could not
/// be found»). То же ограничение описано в Trunook.
///
/// `@StateObject` — обычная обёртка, не макрос, поэтому состояние держится
/// в маленьком объекте. Пользоваться так же: `@ViewState private var x = 0`,
/// привязка — `$x`.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
