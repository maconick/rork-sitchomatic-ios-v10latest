import Foundation
import Observation
import SwiftUI
import UIKit

nonisolated enum TestDebugPhase: Sendable {
    case setup
    case running
    case results
}

@Observable
@MainActor
class TestDebugViewModel {
    var phase: TestDebugPhase = .setup

    var credentials: [TestDebugCredentialEntry] = [
        TestDebugCredentialEntry(email: "", password: "")
    ]
    var selectedSite: TestDebugSite = .joe
    var sessionCount: TestDebugSessionCount = .twentyFour
    var variationMode: TestDebugVariationMode = .all

    var sessions: [TestDebugSession] = []
    var currentWave: Int = 0
    var totalWaves: Int = 0
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false

    private var batchTask: Task<Void, Never>?
    private let engine = LoginAutomationEngine()
    private let logger = DebugLogger.shared
    private let generator = SettingVariationGenerator.shared
    private let proxyService = ProxyRotationService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let urlRotation = LoginURLRotationService.shared

    let waveSize: Int = 6

    var validCredentials: [TestDebugCredentialEntry] {
        credentials.filter(\.isValid)
    }

    var canStart: Bool {
        !validCredentials.isEmpty
    }

    var completedCount: Int {
        sessions.filter { $0.status.isTerminal }.count
    }

    var successCount: Int {
        sessions.filter { $0.status == .success }.count
    }

    var failedCount: Int {
        sessions.filter { $0.status == .failed || $0.status == .connectionFailure }.count
    }

    var unsureCount: Int {
        sessions.filter { $0.status == .unsure || $0.status == .timeout }.count
    }

    var progress: Double {
        guard !sessions.isEmpty else { return 0 }
        return Double(completedCount) / Double(sessions.count)
    }

    var rankedSessions: [TestDebugSession] {
        sessions.sorted { a, b in
            let aScore = statusScore(a.status)
            let bScore = statusScore(b.status)
            if aScore != bScore { return aScore > bScore }
            let aDur = a.duration ?? .infinity
            let bDur = b.duration ?? .infinity
            return aDur < bDur
        }
    }

    var winningSession: TestDebugSession? {
        rankedSessions.first { $0.status == .success }
    }

    private func statusScore(_ status: TestDebugSessionStatus) -> Int {
        switch status {
        case .success: 100
        case .unsure: 50
        case .timeout: 30
        case .failed: 10
        case .connectionFailure: 5
        case .running: 2
        case .queued: 1
        }
    }

    func addCredentialSlot() {
        guard credentials.count < 3 else { return }
        credentials.append(TestDebugCredentialEntry(email: "", password: ""))
    }

    func removeCredentialSlot(at index: Int) {
        guard credentials.count > 1 else { return }
        credentials.remove(at: index)
    }

    func updateCredential(at index: Int, email: String, password: String) {
        guard index < credentials.count else { return }
        credentials[index] = TestDebugCredentialEntry(email: email, password: password)
    }

    func startTest() {
        guard canStart else { return }

        let totalCount = sessionCount.rawValue
        sessions = generator.generateSessions(count: totalCount, mode: variationMode, site: selectedSite)
        totalWaves = Int(ceil(Double(totalCount) / Double(waveSize)))
        currentWave = 0
        isRunning = true
        isPaused = false
        isStopping = false
        phase = .running

        logger.log("TestDebug: Starting \(totalCount) sessions in \(totalWaves) waves of \(waveSize)", category: .login, level: .info)

        batchTask = Task {
            await runWaves()
        }
    }

    func pauseTest() {
        isPaused = true
        logger.log("TestDebug: Paused", category: .login, level: .warning)
    }

    func resumeTest() {
        isPaused = false
        logger.log("TestDebug: Resumed", category: .login, level: .info)
    }

    func stopTest() {
        isStopping = true
        isPaused = false
        logger.log("TestDebug: Stopping after current wave", category: .login, level: .warning)
    }

    func reset() {
        batchTask?.cancel()
        batchTask = nil
        sessions = []
        currentWave = 0
        totalWaves = 0
        isRunning = false
        isPaused = false
        isStopping = false
        phase = .setup
    }

    private func runWaves() async {
        let creds = validCredentials
        let targetSite = selectedSite.targetSite

        let proxyTarget: ProxyRotationService.ProxyTarget = selectedSite == .ignition ? .ignition : .joe
        engine.proxyTarget = proxyTarget

        for waveIndex in 0..<totalWaves {
            guard !isStopping else { break }

            while isPaused && !isStopping {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !isStopping else { break }

            currentWave = waveIndex + 1
            let startIdx = waveIndex * waveSize
            let endIdx = min(startIdx + waveSize, sessions.count)
            let waveSessions = Array(sessions[startIdx..<endIdx])

            logger.log("TestDebug: Wave \(currentWave)/\(totalWaves) — \(waveSessions.count) sessions", category: .login, level: .info)

            await withTaskGroup(of: Void.self) { group in
                for session in waveSessions {
                    let cred = creds[session.index % creds.count]

                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.runSession(session, credential: cred, targetSite: targetSite, proxyTarget: proxyTarget)
                    }
                }

                await group.waitForAll()
            }

            logger.log("TestDebug: Wave \(currentWave) complete — \(successCount) success, \(failedCount) failed, \(unsureCount) unsure so far", category: .login, level: .info)
        }

        isRunning = false
        isStopping = false
        phase = .results

        logger.log("TestDebug: All waves complete — \(successCount)/\(sessions.count) succeeded", category: .login, level: .success)
    }

    private func runSession(_ session: TestDebugSession, credential: TestDebugCredentialEntry, targetSite: LoginTargetSite, proxyTarget: ProxyRotationService.ProxyTarget) async {
        session.status = .running
        session.startedAt = Date()

        let loginCred = LoginCredential(username: credential.email, password: credential.password)
        let attempt = LoginAttempt(credential: loginCred, sessionIndex: session.index)
        attempt.startedAt = Date()

        let snapshot = session.settingsSnapshot
        var settings = snapshot.toAutomationSettings(base: AutomationSettings())
        settings = settings.normalizedTimeouts()

        engine.debugMode = false
        engine.stealthEnabled = snapshot.stealthJSInjection
        engine.automationSettings = settings

        urlRotation.isIgnitionMode = (selectedSite == .ignition)
        let testURL = urlRotation.nextURL() ?? targetSite.url

        session.logs.append(PPSRLogEntry(message: "Config: \(session.differentiator)", level: .info))
        session.logs.append(PPSRLogEntry(message: "URL: \(testURL.host ?? testURL.absoluteString)", level: .info))
        session.logs.append(PPSRLogEntry(message: "Network: \(snapshot.connectionMode.label)", level: .info))

        let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: 90)

        session.completedAt = Date()
        session.errorMessage = attempt.errorMessage

        if let img = attempt.responseSnapshot {
            session.finalScreenshot = img
        }

        switch outcome {
        case .success:
            session.status = .success
        case .noAcc, .permDisabled, .tempDisabled:
            session.status = .failed
        case .unsure, .redBannerError:
            session.status = .unsure
        case .timeout:
            session.status = .timeout
        case .connectionFailure:
            session.status = .connectionFailure
        }

        session.logs.append(PPSRLogEntry(
            message: "Result: \(session.status.rawValue) in \(session.formattedDuration)",
            level: session.status == .success ? .success : (session.status == .unsure || session.status == .timeout ? .warning : .error)
        ))
    }
}
