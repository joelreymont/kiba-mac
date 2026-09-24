import Foundation
import KibaCore
import os

/// Development backend: a `Snapshot` decoded from the JSON file named by
/// `KIBA_FIXTURE`, changed in memory by every action. Nothing touches the
/// store, the network, or a real login.
///
/// The fixture's clock is rebased on load: every `fetchedAt` and `resetsAt`
/// moves by the same amount so the newest probe lands at launch, and ages
/// and reset countdowns read as written whatever the day.
final class FixtureBackend: Backend {
    /// Round trip of a simulated switch or probe, so the busy state shows.
    private static let latency: TimeInterval = 0.6
    private static let maxSuffix = 9

    private let state: OSAllocatedUnfairLock<Snapshot>

    init(file: URL, now: Date = Date()) throws(KibaError) {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .io("\(file.path): \(error.localizedDescription)")
        }
        let snap: Snapshot
        do {
            snap = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw .io("\(file.path) is not a snapshot: \(Self.describe(error))")
        }
        state = OSAllocatedUnfairLock(initialState: Self.rebase(snap, now: now))
    }

    func status() -> Snapshot {
        state.withLock { $0 }
    }

    /// Makes `n` the live login and probes it, as a switch does.
    func use(_ p: Provider, _ n: SlotName) async throws {
        await Self.pause()
        let now = Self.epoch()
        try state.withLock { s in
            let (pi, ai) = try Self.find(s, p, n)
            for i in s.providers[pi].accounts.indices { s.providers[pi].accounts[i].active = i == ai }
            let a = s.providers[pi].accounts[ai]
            s.providers[pi].live = LiveLogin(email: n.email, plan: a.plan)
            s.providers[pi].accounts[ai].usage?.fetchedAt = now
        }
    }

    /// Saves the live login under its email, or the first free `email #n`;
    /// returns the active slot unchanged when the live login is saved already.
    func save(_ p: Provider) throws -> SlotName? {
        try state.withLock { s in
            guard let pi = s.providers.firstIndex(where: { $0.provider == p }),
                  let live = s.providers[pi].live else { return nil }
            let accounts = s.providers[pi].accounts
            if let a = accounts.first(where: \.active) { return a.name }
            guard let base = SlotName(live.email) else { throw KibaError.badName(live.email) }
            let free = ([base] + (2...Self.maxSuffix).compactMap { SlotName("\(live.email) #\($0)") })
                .first { n in !accounts.contains { $0.name == n } }
            guard let name = free else {
                throw KibaError.capacity("more than \(Self.maxSuffix) logins under \(live.email)")
            }
            s.providers[pi].accounts.append(Account(name: name, plan: live.plan, active: true, usage: nil))
            return name
        }
    }

    func forget(_ p: Provider, _ n: SlotName) throws {
        try state.withLock { s in
            let (pi, ai) = try Self.find(s, p, n)
            s.providers[pi].accounts.remove(at: ai)
        }
    }

    /// Re-reports every recorded usage as freshly probed.
    func probeAll(_ p: Provider) async -> ProbeReport {
        await Self.pause()
        let now = Self.epoch()
        return state.withLock { s in
            var out: [(SlotName, ProbeOutcome)] = []
            guard let pi = s.providers.firstIndex(where: { $0.provider == p }) else {
                return ProbeReport(saveBackError: nil, providerError: nil, accounts: out)
            }
            for ai in s.providers[pi].accounts.indices {
                guard var u = s.providers[pi].accounts[ai].usage else { continue }
                u.fetchedAt = now
                s.providers[pi].accounts[ai].usage = u
                out.append((s.providers[pi].accounts[ai].name, .record(u, doc: Data())))
            }
            return ProbeReport(saveBackError: nil, providerError: nil, accounts: out)
        }
    }

    /// A fixture has no provider CLI to log in with, so this shows the
    /// failure path.
    func add(_ p: Provider, expected: String?) async throws -> AddResult {
        throw KibaError.noCLI(p.rawValue)
    }

    private static func find(_ s: Snapshot, _ p: Provider, _ n: SlotName) throws(KibaError) -> (Int, Int) {
        guard let pi = s.providers.firstIndex(where: { $0.provider == p }),
              let ai = s.providers[pi].accounts.firstIndex(where: { $0.name == n }) else {
            throw .noAccount(p, n.raw)
        }
        return (pi, ai)
    }

    private static func epoch() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private static func pause() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + latency) { c.resume() }
        }
    }

    private static func rebase(_ snap: Snapshot, now: Date) -> Snapshot {
        var newest = 0
        for p in snap.providers {
            for a in p.accounts { newest = max(newest, a.usage?.fetchedAt ?? 0) }
        }
        guard newest > 0 else { return snap }
        let shift = Int(now.timeIntervalSince1970) - newest
        var out = snap
        for pi in out.providers.indices {
            for ai in out.providers[pi].accounts.indices {
                guard var u = out.providers[pi].accounts[ai].usage else { continue }
                if u.fetchedAt > 0 { u.fetchedAt += shift }
                for li in u.limits.indices {
                    guard let at = Rows.parseISO(u.limits[li].resetsAt) else { continue }
                    u.limits[li].resetsAt = at.addingTimeInterval(TimeInterval(shift)).formatted(.iso8601)
                }
                out.providers[pi].accounts[ai].usage = u
            }
        }
        return out
    }

    /// `providers.0.accounts.2.name: <what is wrong>`.
    private static func describe(_ e: any Error) -> String {
        guard let d = e as? DecodingError else { return e.localizedDescription }
        let ctx: DecodingError.Context
        switch d {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            ctx = c
        @unknown default:
            return e.localizedDescription
        }
        let path = ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
    }
}
