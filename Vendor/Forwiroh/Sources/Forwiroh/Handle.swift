import CForwiroh
import Dispatch
import Foundation

/// The lock protects ownership, never a blocking FFI call. Shutdown must be able
/// to wake command/event/packet readers before joining them and freeing the handle.
final class CoreHandle: @unchecked Sendable {
    private let pointer: OpaquePointer
    private let condition = NSCondition()
    private enum State { case open, closing, closed }
    private var state = State.open
    private var active = 0

    init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { close() }

    func call<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        condition.lock()
        guard state == .open else {
            condition.unlock()
            throw ForwirohError("Networking is stopped")
        }
        active += 1
        condition.unlock()
        defer {
            condition.lock()
            active -= 1
            condition.broadcast()
            condition.unlock()
        }
        return try body(pointer)
    }

    func close() {
        condition.lock()
        if state != .open {
            while state == .closing { condition.wait() }
            condition.unlock()
            return
        }
        state = .closing
        condition.unlock()
        forwiroh_shutdown(pointer)
        condition.lock()
        while active != 0 { condition.wait() }
        condition.unlock()
        forwiroh_free(pointer)
        condition.lock()
        state = .closed
        condition.broadcast()
        condition.unlock()
    }
}

/// Never put blocking Rust calls on the Swift cooperative executor.
func onWorker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}

func validateCString(_ value: String) throws {
    guard !value.utf8.contains(0), value.utf8.count <= 8192 else {
        throw ForwirohError("Input contains NUL or exceeds 8192 UTF-8 bytes")
    }
}

func ownedJSON(_ raw: UnsafeMutablePointer<CChar>?) throws -> JSONValue {
    guard let raw else { throw ForwirohError("Missing core response") }
    defer { forwiroh_string_free(raw) }
    return try JSONDecoder().decode(JSONValue.self, from: Data(String(cString: raw).utf8))
}

func response(_ value: JSONValue) throws -> JSONValue {
    if let error = value["error"]?.string { throw ForwirohError(error) }
    guard let data = value["data"] else { throw ForwirohError("Invalid core response") }
    return data
}
