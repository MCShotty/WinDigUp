import Foundation
@testable import DigUpKit
@testable import digup

/// Shared non-neural search fixtures; no dependency on the streaming index service.
struct SearchServiceFixture {
    enum Failure: Error { case timedOut, inferenceMustRemainStopped }
    final class Mailbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var unread: [[String: Any]] = []
        private var history: [[String: Any]] = []
        func receive(_ value: [String: Any]) {
            condition.lock(); unread.append(value); history.append(value); condition.broadcast(); condition.unlock()
        }
        func take(where predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while true {
                if let index = unread.firstIndex(where: predicate) { return unread.remove(at: index) }
                guard condition.wait(until: deadline) else { throw Failure.timedOut }
            }
        }
        func reply(_ id: Int) throws -> [String: Any] { try take { $0["id"] as? Int == id } }
        func events(_ state: String) -> Int {
            condition.lock(); defer { condition.unlock() }
            return history.filter { $0["event"] as? String == "search_index" && $0["state"] as? String == state }.count
        }
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
    static func idle(_ service: SearchService, _ mailbox: Mailbox) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            service.admit(SearchMessage(["op": "status", "id": 90000]))
            let reply = try mailbox.reply(90000)
            if reply["refreshing"] as? Bool == false { return reply }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw Failure.timedOut
    }

}
