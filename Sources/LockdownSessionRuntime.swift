//
//  LockdownSessionRuntime.swift
//  Minimuxer
//
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

enum LockdownSessionRuntimeError: Error {
    case unavailable
}

actor LockdownSessionRuntime {
    private struct SessionID: Hashable, Sendable {
        let rawValue: UInt64
    }

    private struct Session: Sendable {
        let id: SessionID
        var heartbeatReady = false
        var isRetiring = false
        var activeChildServiceOperations = 0
    }

    private enum EndpointMutation {
        case unchanged
        case replace(String?)
    }

    static let shared = LockdownSessionRuntime()

    private var enabled = false
    private var nextSessionID: UInt64 = 0
    private var transitionActive = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: Session?
    private var heartbeatTask: Task<Void, Never>?
    private var readinessWaiters: [
        UUID: CheckedContinuation<SessionID?, Never>
    ] = [:]
    private var drainWaiters: [
        SessionID: [UUID: CheckedContinuation<Void, Never>]
    ] = [:]

    private init() {}

    func configure() async {
        enabled = true
        await transition(
            startNewSession: true,
            preserveReadinessWaiters: true,
            reason: "configured",
            endpointMutation: .unchanged
        )
    }

    func updateDeviceEndpoint(_ endpoint: String?) async {
        guard enabled || session != nil || heartbeatTask != nil ||
                transitionActive else {
            await applyDeviceEndpoint(endpoint)
            return
        }
        await transition(
            startNewSession: endpoint != nil,
            preserveReadinessWaiters: true,
            reason: endpoint != nil
                ? "deviceEndpointChanged"
                : "deviceEndpointUnavailable",
            endpointMutation: .replace(endpoint)
        )
    }

    func revalidateAfterForeground() async {
        guard enabled else { return }
        await transition(
            startNewSession: true,
            preserveReadinessWaiters: true,
            reason: "foregroundRevalidation",
            endpointMutation: .unchanged
        )
    }

    func shutdown() async {
        enabled = false
        await transition(
            startNewSession: false,
            preserveReadinessWaiters: false,
            reason: "minimuxerStopped",
            endpointMutation: .unchanged
        )
    }

    func withReadyChildServiceOperation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationSessionID: SessionID

        while true {
            guard let candidateSessionID = await waitForReadySession() else {
                throw LockdownSessionRuntimeError.unavailable
            }
            try Task.checkCancellation()
            guard var current = session,
                  current.id == candidateSessionID,
                  current.heartbeatReady,
                  !current.isRetiring else {
                continue
            }
            current.activeChildServiceOperations += 1
            session = current
            operationSessionID = candidateSessionID
            break
        }

        defer {
            releaseChildServiceOperation(for: operationSessionID)
        }
        return try await operation()
    }

    private func transition(
        startNewSession: Bool,
        preserveReadinessWaiters: Bool,
        reason: String,
        endpointMutation: EndpointMutation
    ) async {
        await acquireTransitionSlot()
        defer { releaseTransitionSlot() }

        if case .replace(let endpoint) = endpointMutation,
           await DeviceEndpoint.shared.currentIP == endpoint {
            return
        }

        let previousSessionID = session?.id

        if var current = session {
            current.isRetiring = true
            current.heartbeatReady = false
            session = current
        }
        if !preserveReadinessWaiters {
            resumeReadinessWaiters(with: nil)
        }

        if let previousSessionID {
            await waitForChildServiceOperationsToDrain(
                sessionID: previousSessionID
            )
        }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        session = nil

        if case .replace(let endpoint) = endpointMutation {
            await applyDeviceEndpoint(endpoint)
        }

        guard startNewSession, enabled else {
            debugLog(
                "[minimuxer] lockdown-session: stopped " +
                "reason=\(reason)"
            )
            return
        }

        nextSessionID &+= 1
        let sessionID = SessionID(rawValue: nextSessionID)
        session = Session(id: sessionID)
        heartbeatTask = Task.detached(priority: .background) {
            await HeartbeatService.run(sessionID: sessionID.rawValue) { event in
                await LockdownSessionRuntime.shared.recordHeartbeatEvent(
                    event,
                    sessionID: sessionID
                )
            }
        }
        debugLog(
            "[minimuxer] lockdown-session: started " +
            "session=\(sessionID.rawValue) reason=\(reason)"
        )
    }

    private func acquireTransitionSlot() async {
        guard transitionActive else {
            transitionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
        }
    }

    private func releaseTransitionSlot() {
        guard !transitionWaiters.isEmpty else {
            transitionActive = false
            return
        }
        let next = transitionWaiters.removeFirst()
        next.resume()
    }

    private func applyDeviceEndpoint(_ endpoint: String?) async {
        if let endpoint {
            await DeviceEndpoint.shared.update(endpoint)
            MuxerService.notifyDeviceAttached(tunnelPeerIp: endpoint)
        } else {
            await DeviceEndpoint.shared.clear()
            MuxerService.notifyDeviceDetached()
        }
    }

    private func waitForReadySession() async -> SessionID? {
        guard enabled else { return nil }
        if let current = session, current.heartbeatReady {
            return current.id
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, self.enabled else {
                    continuation.resume(returning: nil)
                    return
                }
                if let current = self.session, current.heartbeatReady {
                    continuation.resume(returning: current.id)
                    return
                }
                readinessWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await LockdownSessionRuntime.shared.cancelReadinessWaiter(
                    id: waiterID
                )
            }
        }
    }

    private func waitForChildServiceOperationsToDrain(
        sessionID: SessionID
    ) async {
        guard let current = session,
              current.id == sessionID,
              current.activeChildServiceOperations > 0 else {
            return
        }

        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            guard let current = self.session,
                  current.id == sessionID,
                  current.activeChildServiceOperations > 0 else {
                continuation.resume()
                return
            }
            drainWaiters[sessionID, default: [:]][waiterID] = continuation
        }
    }

    private func recordHeartbeatEvent(
        _ event: HeartbeatService.Event,
        sessionID: SessionID
    ) {
        guard var current = session, current.id == sessionID else { return }

        switch event {
        case .ready:
            guard !current.isRetiring else { return }
            current.heartbeatReady = true
            session = current
            resumeReadinessWaiters(with: sessionID)
        case .disconnected:
            current.heartbeatReady = false
            session = current
        }
    }

    private func releaseChildServiceOperation(
        for sessionID: SessionID
    ) {
        guard var current = session,
              current.id == sessionID,
              current.activeChildServiceOperations > 0 else {
            return
        }
        current.activeChildServiceOperations -= 1
        session = current
        guard current.activeChildServiceOperations == 0 else { return }

        let waiters = drainWaiters.removeValue(forKey: sessionID) ?? [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func resumeReadinessWaiters(
        with sessionID: SessionID?
    ) {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: sessionID)
        }
    }

    private func cancelReadinessWaiter(id: UUID) {
        guard let waiter = readinessWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(returning: nil)
    }
}
