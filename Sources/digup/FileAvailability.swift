import Foundation

/// Availability is advisory. A blocked filesystem probe cannot own a search queue or grow more threads.
final class FileAvailability: @unchecked Sendable {
    struct Observation: Sendable {
        let state: String
        let stale: Bool
        let ageMilliseconds: Double?
        var unavailable: Bool { state == "unavailable" && !stale }
        var fields: [String: Any] {
            var value: [String: Any] = ["availability": state, "availability_stale": stale]
            if let ageMilliseconds { value["availability_checked_ms_ago"] = ageMilliseconds }
            return value
        }
    }
    private struct Entry {
        let available: Bool
        let checked: Double
        var touched: Double
    }
    private let lock = NSLock()
    private let workers = DispatchQueue(label: "digup.search.availability", qos: .utility, attributes: .concurrent)
    private let probe: @Sendable (String) -> Bool
    private let clock: @Sendable () -> Double
    private let concurrency: Int, capacity: Int, cacheLimit: Int
    private let availableTTL: Double, unavailableTTL: Double
    private var entries: [String: Entry] = [:]
    private var pending: [String] = []
    private var queued: Set<String> = []
    private var running: Set<String> = []
    private var epoch: UInt64 = 0
    private var stopped = false
    private var completed = 0
    private var durations: [Double] = []

    init(concurrency: Int = 2, capacity: Int = 256, cacheLimit: Int = 4096,
         availableTTL: Double = 5, unavailableTTL: Double = 2,
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         probe: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.concurrency = min(max(concurrency, 1), 2)
        self.capacity = min(max(capacity, 1), 256)
        self.cacheLimit = min(max(cacheLimit, 1), 4096)
        self.availableTTL = max(0, availableTTL)
        self.unavailableTTL = max(0, unavailableTTL)
        self.clock = clock
        self.probe = probe
    }

    func observation(_ path: String) -> Observation {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var age: Double?
        var stale = false
        if var entry = entries[path] {
            entry.touched = now
            entries[path] = entry
            age = max(0, now - entry.checked)
            stale = age! >= (entry.available ? availableTTL : unavailableTTL)
            if !stale {
                return Observation(state: entry.available ? "available" : "unavailable",
                                   stale: false, ageMilliseconds: age! * 1000)
            }
        }
        if !stopped && !queued.contains(path) && !running.contains(path) && pending.count < capacity {
            queued.insert(path)
            pending.append(path)
            startLocked()
        }
        return Observation(state: "unknown", stale: stale, ageMilliseconds: age.map { $0 * 1000 })
    }

    func clear() {
        lock.withLock {
            epoch &+= 1
            entries.removeAll()
            pending.removeAll()
            queued.removeAll()
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            epoch &+= 1
            pending.removeAll()
            queued.removeAll()
            entries.removeAll()
        }
    }

    var snapshot: [String: Any] {
        lock.withLock {
            let sorted = durations.sorted()
            var result: [String: Any] = [
                "schema_version": 1, "active": running.count, "queued": pending.count,
                "cached": entries.count, "completed": completed, "limit": concurrency,
                "queue_limit": capacity, "cache_limit": cacheLimit,
            ]
            if !sorted.isEmpty {
                result["probe_p95_ms"] = sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
                result["probe_max_ms"] = sorted.last!
            }
            return result
        }
    }

    private func startLocked() {
        while !stopped && running.count < concurrency && !pending.isEmpty {
            let path = pending.removeFirst()
            queued.remove(path)
            running.insert(path)
            let generation = epoch
            workers.async { [self] in
                let began = clock()
                let available = probe(path)
                let finished = clock()
                lock.lock()
                running.remove(path)
                completed += 1
                durations.append(max(0, finished - began) * 1000)
                if durations.count > 128 { durations.removeFirst(durations.count - 128) }
                if !stopped && epoch == generation {
                    if entries[path] == nil && entries.count >= cacheLimit,
                       let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key {
                        entries.removeValue(forKey: oldest)
                    }
                    entries[path] = Entry(available: available, checked: finished, touched: finished)
                }
                startLocked()
                lock.unlock()
            }
        }
    }
}
