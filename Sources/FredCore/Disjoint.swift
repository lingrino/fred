/// Hands a buffer (or other non-Sendable value) to `DispatchQueue.concurrentPerform`
/// workers. The caller guarantees that iterations only read it or write disjoint
/// elements — every use site says which.
public struct Disjoint<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
