import Foundation
@testable import DigUpKit
@testable import digup

/// These clients await background ownership without occupying Swift Testing's cooperative executor.
struct SearchServiceFixture {
    enum Failure: Error { case timedOut, inferenceMustRemainStopped }
    static var blockingWaits: Bool { ProcessInfo.processInfo.environment["DIGUP_TEST_BLOCKING_WAITS"] == "1" }
    private static func blockingDelay(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    static func delay(_ seconds: Double) async throws {
        if blockingWaits { blockingDelay(seconds) }
        else { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    }
    static func waitUntil(timeout: Double = 3, _ predicate: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await delay(0.005) }
        guard predicate() else { throw Failure.timedOut }
    }
    static func signal(_ value: DispatchSemaphore, timeout: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value.wait(timeout: .now()) == .success { return }
            try await delay(0.005)
        }
        throw Failure.timedOut
    }
    final class Mailbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var unread: [[String: Any]] = []
        private var history: [[String: Any]] = []
        private var recordedExecutor = false
        func receive(_ value: [String: Any]) {
            condition.lock(); unread.append(value); history.append(value); condition.broadcast(); condition.unlock()
        }
        private func recordExecutor() {
            condition.lock()
            let record = !recordedExecutor
            recordedExecutor = true
            condition.unlock()
            if record {
                print("FIXTURE_EXECUTOR: blockingWaits=\(SearchServiceFixture.blockingWaits) activeProcessors=\(ProcessInfo.processInfo.activeProcessorCount) thread=\(Thread.current)")
            }
        }
        private func pop(_ predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            condition.lock(); defer { condition.unlock() }
            guard let index = unread.firstIndex(where: predicate) else { return nil }
            return unread.remove(at: index)
        }
        private func blockingTake(_ predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while true {
                if let index = unread.firstIndex(where: predicate) { return unread.remove(at: index) }
                guard condition.wait(until: deadline) else { throw Failure.timedOut }
            }
        }
        func take(where predicate: @Sendable ([String: Any]) -> Bool) async throws -> [String: Any] {
            recordExecutor()
            if SearchServiceFixture.blockingWaits { return try blockingTake(predicate) }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let value = pop(predicate) { return value }
                try await SearchServiceFixture.delay(0.005)
            }
            throw Failure.timedOut
        }
        func reply(_ id: Int) async throws -> [String: Any] { try await take { $0["id"] as? Int == id } }
        func values(event: String, state: String) -> [[String: Any]] {
            condition.lock(); defer { condition.unlock() }
            return history.filter { $0["event"] as? String == event && $0["state"] as? String == state }
        }
        func events(_ state: String) -> Int { values(event: "search_index", state: state).count }
        var encoderEvents: Int {
            condition.lock(); defer { condition.unlock() }
            return history.filter { $0["event"] as? String == "encoder" }.count
        }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(root.path), isDirectory: true)
    }
    static func idle(_ service: SearchService, _ mailbox: Mailbox) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            service.admit(SearchMessage(["op": "status", "id": 90000]))
            let reply = try await mailbox.reply(90000)
            if reply["refreshing"] as? Bool == false { return reply }
            try await delay(0.005)
        }
        throw Failure.timedOut
    }
    static func seedVector(_ writer: IndexStore) throws {
        var vector = [Float16](repeating: 0, count: 768); vector[0] = 1
        let data = vector.withUnsafeBytes { Data($0) }
        try writer.db.run("UPDATE segments SET vec=? WHERE id=(SELECT min(id) FROM segments)", [.blob(data)])
    }
}
