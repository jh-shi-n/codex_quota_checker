// 목적: 초기 연결의 검증·취소·등록 조건과 빈 계정 처리 검증
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class AccountSetupTests: XCTestCase {
    /// 기본 폴더의 실제 연결 확인 이후에만 사용자 등록 허용 검증
    func testDefaultAccountDiscoveryVerifiesIdentityWithoutRegistering() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            XCTAssertEqual(config.home.path, "/fixture/.codex")
            return AccountState(id: config.id, email: "demo@example.com", status: .normal)
        })
        await model.discoverDefaultAccount()
        XCTAssertEqual(model.path, "/fixture/.codex")
        XCTAssertEqual(model.connectedAccount?.email, "demo@example.com")
        XCTAssertTrue(model.canFinish)
        XCTAssertFalse(model.isRegistering)
        XCTAssertNotNil(model.discoveryMessage)
    }

    /// 기본 폴더 미발견 시 네트워크 조회 없이 경로 안내 제공 검증
    func testMissingDefaultDirectoryOffersHelpWithoutRequestingQuota() async {
        let validator = AccountPathValidator(homeDirectory: URL(fileURLWithPath: "/fixture"), fileSystem: .init { _ in
            AccountPathFileMetadata(exists: false, isDirectory: false, isReadable: false)
        })
        let model = AccountSetupModel(validator: validator, checker: { config in
            XCTFail("기본 폴더 미발견 시 연결 요청 금지")
            return AccountState(id: config.id, status: .normal)
        })
        await model.discoverDefaultAccount()
        XCTAssertEqual(model.path, "")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNotNil(model.discoveryMessage)
        XCTAssertFalse(model.canFinish)
    }

    /// 자동 탐색 실패 이후 입력한 CLI 경로의 연결 확인·등록 전환 검증
    func testDiscoveryFailureCanBeRecoveredWithPastedCLIPath() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            AccountState(id: config.id, status: config.home.lastPathComponent == ".codex" ? .loginRequired : .normal)
        })
        await model.discoverDefaultAccount()
        XCTAssertEqual(model.phase, .failed)
        model.path = "/fixture/.codex-work"
        await model.checkConnection()
        XCTAssertEqual(model.registrationPath(), "/fixture/.codex-work")
        await model.discoverDefaultAccount()
        XCTAssertEqual(model.path, "/fixture/.codex-work")
    }

    /// 사용자 입력을 자동 탐색이 덮어쓰거나 조회하지 않는 조건 검증
    func testManualInputTakesPrecedenceOverDefaultDiscovery() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            XCTFail("사용자 입력 이후 자동 조회 금지")
            return AccountState(id: config.id, status: .normal)
        })
        model.path = "/fixture/custom"
        await model.discoverDefaultAccount()
        XCTAssertEqual(model.path, "/fixture/custom")
        XCTAssertEqual(model.phase, .idle)
    }

    /// 자동 조회 중 경로 변경 이후 늦은 응답의 계정·성공 안내 복원 방지 검증
    func testDefaultDiscoveryDoesNotRestoreCancelledResult() async {
        let gate = SetupCheckGate()
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            await gate.wait()
            return AccountState(id: config.id, status: .normal)
        })
        let discovery = Task { await model.discoverDefaultAccount() }
        await gate.waitUntilStarted()
        model.path = "/fixture/manual"
        await gate.release()
        await discovery.value
        XCTAssertEqual(model.path, "/fixture/manual")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.connectedAccount)
        XCTAssertNotEqual(model.discoveryMessage, "기본 계정을 찾았습니다. 연결할 계정을 확인한 뒤 ‘이 계정 연결’을 눌러 주세요.")
    }

    /// 저장·화면 반영 대기 중 중복 등록 차단과 저장 실패 이후 재시도 검증
    func testRegistrationBlocksDuplicateSubmissionAndAllowsRetryAfterFailure() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            AccountState(id: config.id, status: .normal)
        })
        model.path = "/fixture/account"
        await model.checkConnection()
        XCTAssertNotNil(model.beginRegistration())
        XCTAssertTrue(model.isRegistering)
        XCTAssertNil(model.beginRegistration())
        XCTAssertFalse(model.canCheck)
        model.reportRegistrationFailure("저장 실패")
        XCTAssertTrue(model.canFinish)
        XCTAssertNotNil(model.beginRegistration())
    }

    /// 설정 수정 금지 영어 요청의 실제 클립보드 복사 검증
    func testEnglishPathPromptCopiesWithoutRequestingSettingsChanges() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(AccountPathHelp.copyPrompt(to: pasteboard))
        let prompt = pasteboard.string(forType: .string)
        XCTAssertEqual(prompt, AccountPathHelp.prompt)
        XCTAssertTrue(AccountPathHelp.prompt.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertTrue(AccountPathHelp.prompt.contains("CODEX_HOME"))
        XCTAssertTrue(AccountPathHelp.prompt.contains("not the current working directory"))
        XCTAssertTrue(AccountPathHelp.prompt.contains("Do not modify any files or application settings."))
    }

    /// 호스트 크기 제안 없이도 안내 본문의 최소 크기 유지 검증
    func testSetupViewPreservesMinimumSize() throws {
        let renderer = ImageRenderer(content: AccountSetupView(
            model: AccountSetupModel(), onComplete: { _ in }, onLater: {}
        ))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThanOrEqual(image.width, Int(AccountSetupView.windowSize.width))
        XCTAssertGreaterThanOrEqual(image.height, Int(AccountSetupView.windowSize.height))
    }

    /// 존재하지 않는 경로의 네트워크 조회·등록 방지 검증
    func testInvalidPathNeverChecksOrRegisters() async {
        let model = AccountSetupModel(checker: { _ in
            XCTFail("Invalid path must not reach quota service")
            return AccountState(id: "C1", status: .normal)
        })
        model.path = "/missing-account-\(UUID().uuidString)"
        await model.checkConnection()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.registrationPath())
    }

    /// 정규화된 성공 경로의 등록 허용과 입력 변경 시 확인 무효화 검증
    func testSuccessfulConnectionRequiresUnchangedPath() async {
        let model = AccountSetupModel(validator: validValidator(), checker: { config in
            XCTAssertEqual(config.home.path, "/fixture/.codex")
            return AccountState(id: config.id, email: "demo@example.com", status: .normal)
        })
        model.path = " ~/.codex "
        await model.checkConnection()
        XCTAssertEqual(model.phase, .connected)
        XCTAssertEqual(model.registrationPath(), "/fixture/.codex")
        model.path = "/fixture/other"
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.registrationPath())
    }

    /// 조회 실패 종류별 안내와 등록 금지 검증
    func testFailedChecksNeverEnableRegistration() async {
        for status: AccountStatus in [.loginRequired, .codexNotFound, .timeout, .error] {
            let model = AccountSetupModel(validator: validValidator(), checker: { config in
                AccountState(id: config.id, status: status)
            })
            model.path = "/fixture/account"
            await model.checkConnection()
            XCTAssertEqual(model.phase, .failed)
            XCTAssertNotNil(model.message)
            XCTAssertNil(model.registrationPath())
        }
    }

    /// 경로 변경·창 닫기 이후 늦은 조회 결과 무시 검증
    func testCancelledCheckCannotRestoreSuccess() async {
        for editPath in [false, true] {
            let gate = SetupCheckGate()
            let model = AccountSetupModel(validator: validValidator(), checker: { config in
                await gate.wait()
                return AccountState(id: config.id, status: .normal)
            })
            model.path = "/fixture/account"
            let check = Task { await model.checkConnection() }
            await gate.waitUntilStarted()
            if editPath { model.path = "/fixture/other" } else { model.cancelCheck() }
            await gate.release()
            await check.value
            XCTAssertEqual(model.phase, .idle)
            XCTAssertNil(model.registrationPath())
        }
    }

    /// 등록 직전 사라진 폴더의 저장 차단 검증
    func testRemovedDirectoryCannotBeRegistered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AccountSetupModel(checker: { AccountState(id: $0.id, status: .normal) })
        model.path = directory.path
        await model.checkConnection()
        XCTAssertTrue(model.canFinish)
        try FileManager.default.removeItem(at: directory)
        XCTAssertNil(model.registrationPath())
        XCTAssertEqual(model.phase, .failed)
    }

    /// 빈 시작 시 조회·표시 제외 및 한 계정 등록·마지막 삭제 조건 검증
    func testEmptyStartAndSingleAccountPersistence() async {
        let suite = "AccountSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(userDefaults: defaults)
        XCTAssertFalse(preferences.hasRegisteredAccounts)
        let store = AccountStore(configs: AccountConfig.accounts(for: preferences.accountPaths)) { config in
            XCTFail("Unconfigured account must not refresh")
            return AccountState(id: config.id, status: .normal)
        }
        await store.refreshAll()
        XCTAssertTrue(preferences.visibleAccounts(store.states).isEmpty)
        let path = FileManager.default.temporaryDirectory.path
        preferences.updateAccountPaths([path, "", "", ""])
        XCTAssertTrue(preferences.hasRegisteredAccounts)
        let reloaded = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.accountPaths, [path, "", "", ""])
        XCTAssertTrue(reloaded.hasRegisteredAccounts)
        XCTAssertEqual(preferences.visibleAccounts([
            AccountState(id: "C1", status: .normal), AccountState(id: "C2", status: .notConfigured)
        ]).map(\.id), ["C1"])
        preferences.updateAccountPaths(["", "", "", ""])
        XCTAssertFalse(preferences.hasRegisteredAccounts)
    }

    /// 실제 인증 파일 접근 없는 폴더 검증 대역 생성
    private func validValidator() -> AccountPathValidator {
        AccountPathValidator(homeDirectory: URL(fileURLWithPath: "/fixture"), fileSystem: .init { _ in
            AccountPathFileMetadata(exists: true, isDirectory: true, isReadable: true)
        })
    }
}

/// 취소 이후 결과 도착 순서를 제어하는 연결 확인 대역
private actor SetupCheckGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    /// 조회 시작 알림 후 외부 해제까지 대기
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }

    /// 조회 시작까지 테스트 동기화
    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    /// 취소된 작업의 늦은 응답 전달
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
