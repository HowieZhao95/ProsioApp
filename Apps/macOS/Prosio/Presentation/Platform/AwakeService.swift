import Foundation
import IOKit.pwr_mgt
import Observation

@MainActor protocol PresentationPowerManaging {
    func acquire() throws -> [IOPMAssertionID]
    func release(_ ids: [IOPMAssertionID])
}

@MainActor final class SystemPresentationPower: PresentationPowerManaging {
    struct AssertionError: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "系统拒绝保活请求（\(code)），请重试。" }
    }
    func acquire() throws -> [IOPMAssertionID] {
        var ids: [IOPMAssertionID] = []
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Prosio presentation" as CFString, &id)
            guard result == kIOReturnSuccess else { release(ids); throw AssertionError(code: result) }
            ids.append(id)
        }
        return ids
    }
    func release(_ ids: [IOPMAssertionID]) { for id in ids { IOPMAssertionRelease(id) } }
}

@Observable @MainActor
final class AwakeService {
    enum Source: Hashable { case manual, session }
    struct Lease { let deadline: TimeInterval? }
    private(set) var leases: [Source: Lease] = [:]
    private(set) var isActive = false
    private(set) var error: String?
    @ObservationIgnored private let power: any PresentationPowerManaging
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private var assertions: [IOPMAssertionID] = []

    init(power: any PresentationPowerManaging = SystemPresentationPower(), now: @escaping () -> TimeInterval = PresentationClock.now) {
        self.power = power; self.now = now
    }
    func start(_ source: Source, duration: TimeInterval?) {
        if let duration, !duration.isFinite || duration <= 0 {
            error = "请选择有效的保活时长。"; return
        }
        tick()
        if !isActive {
            do { assertions = try power.acquire(); isActive = true }
            catch { self.error = error.localizedDescription; return }
        }
        error = nil
        leases[source] = Lease(deadline: duration.map { now() + $0 })
    }
    func stop(_ source: Source) { leases[source] = nil; releaseIfEmpty() }
    func extendManual(by duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        tick()
        guard let lease = leases[.manual], let deadline = lease.deadline else { return }
        // Append to the existing deadline, never restart from now.
        leases[.manual] = Lease(deadline: deadline + duration)
    }
    func remaining(_ source: Source) -> TimeInterval? {
        leases[source]?.deadline.map { max(0, $0 - now()) }
    }
    func tick() {
        let time = now()
        leases = leases.filter { $0.value.deadline.map { $0 > time } ?? true }
        releaseIfEmpty()
    }
    func stopAll() { leases.removeAll(); releaseIfEmpty(); error = nil }
    private func releaseIfEmpty() {
        guard leases.isEmpty else { return }
        power.release(assertions); assertions.removeAll(); isActive = false
    }
}
