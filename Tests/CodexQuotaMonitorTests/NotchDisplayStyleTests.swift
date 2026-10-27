// 목적: 노치 디자인의 순수 계산·저장 호환·패널 배치 검증
// 이용처: Swift 패키지 회귀 테스트
// 사용방법: swift test --filter NotchDisplayStyleTests
// 실행 예시: swift test --filter NotchDisplayStyleTests
import AppKit
import XCTest
@testable import CodexQuotaMonitorKit

/// 디자인별 값 매핑과 기존 설정·레이아웃 호환 검증
@MainActor
final class NotchDisplayStyleTests: XCTestCase {
    /// 반올림 전 값에 적용하는 20·50 경계와 비정상 수치 정규화 검증
    func testColorThresholdsAndClamping() {
        for value in [-10.0, 0, 19.99, .nan, .infinity, -.infinity] {
            XCTAssertEqual(NotchQuotaPresentation.color(for: value), QuotaColors.low)
            XCTAssertGreaterThanOrEqual(NotchQuotaPresentation.progress(value), 0)
            XCTAssertLessThanOrEqual(NotchQuotaPresentation.progress(value), 1)
        }
        for value in [20.0, 35, 49.99] {
            XCTAssertEqual(NotchQuotaPresentation.color(for: value), QuotaColors.attention)
        }
        for value in [50.0, 92, 100, 150] {
            XCTAssertEqual(NotchQuotaPresentation.color(for: value), QuotaColors.normal)
        }
        XCTAssertEqual(NotchQuotaPresentation.progress(150), 1)
        XCTAssertEqual(NotchQuotaPresentation.progress(-10), 0)
        XCTAssertEqual(NotchQuotaPresentation.progress(35), 0.35)
        XCTAssertEqual(NotchQuotaPresentation.progress(nil), 0)
        XCTAssertEqual(NotchQuotaPresentation.color(for: nil), NotchQuotaPresentation.secondary)
        XCTAssertEqual(NotchQuotaPresentation.track.hex, "#3A3A3A")
        XCTAssertEqual(NotchQuotaPresentation.secondary.hex, "#9A9A9A")
    }

    /// 기존 링의 숫자 반올림 재사용 및 누락·범위 초과 처리 검증
    func testRoundedNumbersAndMissingValues() {
        let value = NotchQuotaPresentation(account: AccountState(id: "C1", primaryRemainingPercent: 35, status: .normal))
        for (input, expected) in [(19.49, "19"), (19.51, "20"), (49.99, "50"), (1000, "100"), (-1, "0"), (.nan, "0")] {
            XCTAssertEqual(value.text(input), expected)
        }
        XCTAssertEqual(value.text(nil), "—")
    }

    /// 전체 소진 시에도 새 디자인의 5시간 숫자 독립 유지 검증
    func testWindowsRemainIndependentIncludingExhaustedOverall() {
        let account = AccountState(id: "C1", primaryRemainingPercent: 92,
                                   secondaryRemainingPercent: 0, status: .normal)
        let presentation = NotchQuotaPresentation(account: account)
        XCTAssertEqual(presentation.fiveHour, 92)
        XCTAssertEqual(presentation.overall, 0)
        XCTAssertEqual(QuotaDonutPresentation(account: account).centerPercent, 0)
        let partial = NotchQuotaPresentation(account: AccountState(id: "C1", primaryRemainingPercent: 35, status: .normal))
        XCTAssertEqual(partial.fiveHour, 35)
        XCTAssertNil(partial.overall)
    }

    /// 조회 중 캐시 유지와 인증 불가 상태의 이전 값 숨김 검증
    func testAccountStatesReuseExistingStatusClassification() {
        for status: AccountStatus in [.loading, .timeout, .error] {
            let value = NotchQuotaPresentation(account: AccountState(id: "C1", remainingPercent: 35, status: status))
            XCTAssertEqual(value.fiveHour, 35)
            XCTAssertEqual(value.overall, 35)
        }
        for status: AccountStatus in [.notConfigured, .loginRequired, .codexNotFound] {
            let value = NotchQuotaPresentation(account: AccountState(id: "C1", remainingPercent: 35, status: status))
            XCTAssertNil(value.fiveHour)
            XCTAssertNil(value.overall)
        }
        XCTAssertEqual(NotchQuotaPresentation(account: .loading(id: "C1")).text(nil), "…")
        XCTAssertEqual(NotchQuotaPresentation(account: AccountState(id: "C1", status: .loginRequired)).text(nil), "!")
    }

    /// 네 가지 선택의 재시작 복원과 이전 설정 필드 누락·미지원 문자열의 링 복원 검증
    func testPersistenceAndBackwardCompatibility() throws {
        let suite = "NotchDisplayStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store.notchDisplayStyle, .ring)
        for style in NotchDisplayStyle.allCases {
            store.updateNotchDisplayStyle(style)
            XCTAssertEqual(PreferencesStore(userDefaults: defaults).notchDisplayStyle, style)
        }
        let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.Keys.settingsBundle))
        let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for raw in [nil, "futureStyle"] as [String?] {
            var modified = bundle
            var settings = try XCTUnwrap(modified["settings"] as? [String: Any])
            settings["notchDisplayStyle"] = raw
            modified["settings"] = settings
            defaults.set(try JSONSerialization.data(withJSONObject: modified), forKey: PreferencesStore.Keys.settingsBundle)
            let restored = PreferencesStore(userDefaults: defaults)
            XCTAssertEqual(restored.notchDisplayStyle, .ring)
            XCTAssertNil(restored.persistenceError)
        }
    }

    /// 손상된 기존 설정 원본 보존과 디자인 저장 차단 검증
    func testCorruptSettingsBlockStyleMutation() throws {
        let suite = "NotchDisplayStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("broken".utf8)
        defaults.set(bytes, forKey: PreferencesStore.Keys.settingsBundle)
        let store = PreferencesStore(userDefaults: defaults)
        store.updateNotchDisplayStyle(.verticalBars)
        XCTAssertEqual(store.notchDisplayStyle, .ring)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(defaults.data(forKey: PreferencesStore.Keys.settingsBundle), bytes)
    }

    /// 설정 파일 저장 실패 시 메모리와 영속 선택의 직전 정상값 복원 검증
    func testWriteFailureRollsBackStyle() throws {
        let suite = "NotchDisplayStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let config = AppConfigurationFile(fileURL: folder.appendingPathComponent("config.json"))
        let store = PreferencesStore(userDefaults: defaults, configurationFile: config)
        store.updateNotchDisplayStyle(.horizontalBars)
        try Data("broken".utf8).write(to: config.fileURL)
        store.updateNotchDisplayStyle(.stackedNumbers)
        XCTAssertEqual(store.notchDisplayStyle, .horizontalBars)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(PreferencesStore(userDefaults: defaults).notchDisplayStyle, .horizontalBars)
    }

    /// 실제 고정폭 글꼴의 100·두 자리 숫자·상태 기호가 숫자 영역에 포함되는지 검증
    func testVerticalNumberFontFitsWithoutTruncation() {
        for text in ["0", "12", "35", "99", "100", "!", "×", "—", "…"] {
            let font = NSFont.monospacedSystemFont(ofSize: QuotaVerticalBarsMetrics.fontSize(for: text), weight: .semibold)
            let width = (text as NSString).size(withAttributes: [
                .font: font, .kern: QuotaVerticalBarsMetrics.tracking,
            ]).width
            XCTAssertLessThanOrEqual(width, QuotaVerticalBarsMetrics.numberWidth, text)
        }
    }

    /// 2단 숫자의 실제 글꼴로 100 포함 모든 숫자·상태 기호의 너비 검증
    func testStackedNumbersFitWithoutTruncation() {
        let fonts = [
            NSFont.monospacedSystemFont(ofSize: QuotaStackedNumbersMetrics.primaryFontSize, weight: .semibold),
            NSFont.monospacedSystemFont(ofSize: QuotaStackedNumbersMetrics.secondaryFontSize, weight: .regular),
        ]
        for text in ["0", "12", "35", "99", "100", "!", "×", "—", "…"] {
            for font in fonts {
                XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: font]).width, 22, text)
            }
        }
    }

    /// 링 한 칸 크기·여백·계정 간격의 모든 디자인 공통 적용 검증
    func testStylesUseSameRingSlot() {
        for diameter: CGFloat in [20, 22] {
            for count in [1, 2, 4] {
                let ring = QuotaClusterMetrics.visualFootprint(itemCount: count, diameter: diameter)
                for style in NotchDisplayStyle.allCases {
                    XCTAssertEqual(QuotaClusterMetrics.footprint(itemCount: count, style: style, diameter: diameter),
                                   QuotaClusterMetrics.footprint(itemCount: count, diameter: diameter))
                    XCTAssertEqual(QuotaClusterMetrics.visualFootprint(itemCount: count, style: style, diameter: diameter), ring)
                }
            }
        }
    }

    /// 가로·세로 긴 그래픽의 링 한 칸 포함과 원래 비율 유지 검증
    func testGraphicFitsRingSlotWithoutDistortion() {
        for style in NotchDisplayStyle.allCases {
            for diameter: CGFloat in [0, 20, 22] {
                let size = style.fittedSize(forDiameter: diameter)
                XCTAssertLessThanOrEqual(size.width, diameter)
                XCTAssertLessThanOrEqual(size.height, diameter)
                XCTAssertEqual(max(size.width, size.height), diameter, accuracy: 0.001)
                if diameter > 0 {
                    XCTAssertEqual(size.width / size.height, style.size.width / style.size.height, accuracy: 0.001)
                }
            }
            for diameter: CGFloat in [-1, .nan, .infinity] {
                XCTAssertEqual(style.fittedSize(forDiameter: diameter), .zero)
            }
        }
    }

    /// 좁은 좌우 안전 영역에서 모든 스타일의 호버 포함 배치와 알림 앵커 유지 검증
    func testStylesFitBothSidesAndPreserveToastAnchors() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 90, height: 24),
            auxiliaryTopRightArea: CGRect(x: 210, y: 876, width: 90, height: 24))
        for style in NotchDisplayStyle.allCases {
            for side in [NotchSide.left, .right] {
                let height = layout.resolvedDiameter(side: side, itemCount: 2, style: style, diameter: QuotaDonutMetrics.maximumDiameter)
                let visual = QuotaClusterMetrics.visualFootprint(itemCount: 2, style: style, diameter: height)
                XCTAssertLessThanOrEqual(visual.width, 90.0001)
                XCTAssertLessThanOrEqual(visual.height, 24.0001)
                XCTAssertEqual(height, layout.resolvedDiameter(side: side, itemCount: 2, diameter: QuotaDonutMetrics.maximumDiameter))
                XCTAssertEqual(layout.panelFrame(side: side, itemCount: 2, style: style, diameter: height),
                               layout.panelFrame(side: side, itemCount: 2, diameter: height))
                let content = layout.contentFrame(side: side, itemCount: 2, style: style, diameter: height)
                let frames = layout.itemFrames(side: side, itemCount: 2, style: style, diameter: height)
                XCTAssertEqual(frames.count, 2)
                for frame in frames { XCTAssertTrue(content.contains(frame)) }
                let base = layout.panelFrame(side: side, itemCount: 2, style: style, diameter: height)
                let toast = layout.panelFrame(side: side, itemCount: 2, style: style, diameter: height, toastWidth: 10)
                XCTAssertEqual(side == .left ? base.maxX : base.minX, side == .left ? toast.maxX : toast.minX)
            }
        }
    }
}
