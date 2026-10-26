/// Transfers queue-confined resources to a disposal owner. The original owner must replace its stored
/// references before scheduling release(), and must not retain another copy of the transferred contents.
/// Retaining this container on the original queue is safe: only the disposal task clears its contents.
final class SearchRetirement<Value>: @unchecked Sendable {
    private var value: Value?
    init(_ value: consuming Value) { self.value = consume value }
    func release() { value = nil }
}
