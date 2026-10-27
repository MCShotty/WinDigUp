import Foundation

/// Bounded admission, one replaceable pending job per key. User work precedes background work.
/// Never wait for a rendering slot or model call on the JSON input loop.
final class SearchWorkQueue: @unchecked Sendable {
    // Closures transfer queue-confined objects from the builder to their serial owner. They are never
    // executed concurrently on this queue; database/searcher classes themselves remain non-Sendable.
    private struct Job: @unchecked Sendable {
        let key: String
        let foreground: Bool
        let run: () -> Void
        let cancel: () -> Void
    }
    private let lock = NSLock()
    private let concurrency: Int
    private let capacity: Int
    private var jobs: [Job] = []
    private var active = 0
    private var stopped = false
    init(concurrency: Int = 1, capacity: Int = 64) {
        self.concurrency = concurrency
        self.capacity = capacity
    }

    func submit(
        key: String, foreground: Bool = true, cancel: @escaping () -> Void = {},
        run: @escaping () -> Void
    ) {
        var displaced: Job?
        lock.lock()
        if let index = jobs.firstIndex(where: { $0.key == key }) { displaced = jobs.remove(at: index) }
        if !stopped, foreground, jobs.count >= capacity, let index = jobs.firstIndex(where: { !$0.foreground }) {
            displaced = jobs.remove(at: index)
        }
        let accepted = !stopped && jobs.count < capacity
        if accepted { jobs.append(Job(key: key, foreground: foreground, run: run, cancel: cancel)) }
        lock.unlock()
        displaced?.cancel()
        if !accepted { cancel() }
        start()
    }
    var pendingCount: Int { lock.withLock { jobs.count } }

    func cancelPending() {
        let cancelled = lock.withLock {
            let old = jobs
            jobs = []
            return old
        }
        cancelled.forEach { $0.cancel() }
    }
    func stop() {
        lock.withLock { stopped = true }
        cancelPending()
    }
    private func start() {
        lock.lock()
        guard active < concurrency, !jobs.isEmpty else {
            lock.unlock()
            return
        }
        let index = jobs.firstIndex(where: { $0.foreground }) ?? 0
        let job = jobs.remove(at: index)
        active += 1
        lock.unlock()
        DispatchQueue.global(qos: job.foreground ? .userInitiated : .utility).async { [self] in
            job.run()
            lock.withLock { active -= 1 }
            start()
        }
        start()
    }
}

/// JSON dictionaries cross queues by value; each receiver has sole ownership of its mutable copy.
struct SearchMessage: @unchecked Sendable {
    let fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }
}
