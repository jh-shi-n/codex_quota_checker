// 목적: 설정 통합의 기존 저장 호환성과 편집 초안 보존 검증
// 이용처: 표시 방식·계정 목록·외부 설정 변경의 회귀 검사
// 사용방법: swift test --filter SettingsConsolidationTests
// 실행 예시: 잔디·막대·선 왕복 및 외부 계정 연결과 입력 초안의 동시 변경
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 표시 정책 변경과 계정 편집의 저장 경계 검증
@MainActor
final class SettingsConsolidationTests: XCTestCase {
    /// 이전 옵션 복원과 표시 방식 변경에서 형태·날짜 범위 유지 검증
    func testDisplayModeKeepsLegacyEncodingAndPreservesChartStyle() throws {
        for (enabled, style, expected) in [
            (false, TokenChartStyle.line, TokenUsageDisplayMode.heatmap),
            (true, .bar, .weeklyBar), (true, .line, .weeklyLine)
        ] {
            var options = TokenUsageOptions(weeklyChartEnabled: enabled, chartStyle: style, retentionMonths: 6)
            XCTAssertEqual(options.displayMode, expected)
            options.displayMode = .weeklyLine
            options.displayMode = .heatmap
            XCTAssertFalse(options.weeklyChartEnabled)
            XCTAssertEqual(options.chartStyle, .line)
            options.displayMode = .weeklyBar
            XCTAssertEqual(options.chartStyle, .bar)
            XCTAssertEqual(options.retentionMonths, 6)
            let restored = try JSONDecoder().decode(TokenUsageOptions.self, from: JSONEncoder().encode(options))
            XCTAssertEqual(restored.displayMode, .weeklyBar)
            XCTAssertEqual(restored, options)
        }
    }

    /// 외부 이름 변경에서 수정 중인 슬롯 보존 및 미편집 슬롯 동기화 검증
    func testExternalNamesUpdateOnlyUntouchedDrafts() {
        let merged = SettingsView.mergingNameDrafts(
            ["C1": "입력 중 ", "C2": "기존 이름"],
            previous: ["C1": "원래 이름", "C2": "기존 이름"],
            current: ["C1": "외부 변경", "C2": "새 이름", "C3": "추가 계정"]
        )
        XCTAssertEqual(merged, ["C1": "입력 중 ", "C2": "새 이름", "C3": "추가 계정"])
        XCTAssertEqual(SettingsView.mergingNameDrafts(["C1": ""], previous: [:], current: ["C1": "연결 계정"]), ["C1": "연결 계정"])
    }

    /// 경로 편집 중 외부 계정 추가에서 미저장 경로와 저장 기준 유지 검증
    func testExternalPathChangesPreserveEditedSlotsAndUpdateValidationBaseline() {
        var draft = SettingsView.AccountPathsDraft(paths: ["/old", "", "", ""])
        draft.replace(at: 0, text: "/editing")
        draft.synchronize(paths: ["/external", "/connected", "", ""])
        XCTAssertEqual(draft.paths, ["/editing", "/connected", "", ""])
        draft.replace(at: 0, text: "/external")
        draft.synchronize(paths: ["/new", "/connected", "", ""])
        XCTAssertEqual(draft.paths, ["/new", "/connected", "", ""])
    }

    /// 슬롯 순서 변경과 무관한 이름·표시 여부·경로 연결 유지 검증
    func testReorderingDoesNotMoveAccountSettingsBetweenSlots() throws {
        let suite = "SettingsConsolidationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults)
        store.updateAccountDisplayNames(["C1": "업무", "C3": "개인"])
        store.updateEnabledAccountIDs(["C1", "C3"])
        store.updateAccountDisplayOrder(AccountOrderEditor.moving(store.accountDisplayOrder, slotID: "C3", toInsertionIndex: 0))
        let states = [AccountState(id: "C1", status: .normal), AccountState(id: "C3", status: .normal)]
        XCTAssertEqual(store.visibleAccounts(states).map(\.id), ["C3", "C1"])
        XCTAssertEqual(store.displayName(for: "C1"), "업무")
        XCTAssertEqual(store.displayName(for: "C3"), "개인")
        store.updateEnabledAccountIDs([])
        XCTAssertTrue(store.visibleAccounts(states).isEmpty)
        store.updateEnabledAccountIDs(["C1", "C3"])
        XCTAssertEqual(store.visibleAccounts(states).map(\.id), ["C3", "C1"])
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).accountDisplayNames, store.accountDisplayNames)
    }
}
