import XCTest
import SwiftUI
@testable import CodexQuotaMonitorKit

@MainActor
final class QuotaPresentationTests: XCTestCase {
    /// 전송 성공과 한도별 관측 결과를 구분한 상세 문구 검증
    func testProbeTextDistinguishesStableAndMovingWindows() {
        let now = Date()
        let account = AccountState(id: "C1", status: .normal)
        let confirmation = ResetTimeConfirmationResult(primary: .stableObserved, secondary: .movingObserved,
            account: account, lastRefreshSucceeded: true, isCurrentAccount: true, queryCount: 4)
        let presentation = UsageWindowProbePresentationResult(
            result: UsageWindowProbeResult(accountID: "C1", status: .success, startedAt: now, completedAt: now),
            quotaRefreshSucceeded: true, resetConfirmation: confirmation)
        let section = UsageWindowProbeSection(account: account, probe: presentation)
        XCTAssertEqual(section.resultText, "전송 완료 · 5시간 고정 관측 · 주간 변동 중")
    }

    /// 후속 조회 대기 중 전송 완료와 추가 소비 없는 확인 단계 표시 검증
    func testRunningConfirmationIsNotPresentedAsSendingAgain() {
        let section = UsageWindowProbeSection(account: AccountState(id: "C1", status: .normal),
            isRunning: true, isConfirming: true)
        XCTAssertEqual(section.resultText, "전송 완료 · 시각 확인 중")
        XCTAssertEqual(section.buttonTitle, "시각 확인 중…")
        XCTAssertFalse(section.canRun)
    }

    /// 더 늦게 도착한 이전 구간 Ping 스냅샷의 최신 계정 상태 덮어쓰기 차단 검증
    func testProbeSnapshotFromOldSegmentCannotReplaceCurrentAccount() {
        let now = Date()
        var current = AccountState(id: "C1", primaryUsedPercent: 20, lastUpdated: now, status: .normal)
        current.primaryResetSegmentID = UUID()
        var previousSegment = current
        previousSegment.primaryUsedPercent = 80
        previousSegment.primaryResetSegmentID = UUID()
        previousSegment.lastUpdated = now.addingTimeInterval(1)
        let presentation = UsageWindowProbePresentationResult(
            result: UsageWindowProbeResult(accountID: "C1", status: .success, startedAt: now, completedAt: now),
            quotaRefreshSucceeded: true, refreshedAccount: previousSegment)
        XCTAssertEqual(AccountDashboardPresentation.accountForDisplay(current: current, probe: presentation), current)
    }

    /// 현행 세션 목록의 작업·대기·최근 시각 순서와 하위 에이전트 보존 검증
    func testCardsSortWorkingThenWaitingThenMostRecentAndKeepInactiveAgents() {
        let sessions = [
            SessionActivityMainSession(
                threadID: "waiting",
                source: .localActivity,
                taskName: "Waiting",
                status: .waiting,
                agents: [],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 2_000_100)
            ),
            SessionActivityMainSession(
                threadID: "working",
                source: .localActivity,
                taskName: "Working",
                status: .working,
                agents: [
                    SessionActivityAgent(
                        threadID: "done-agent",
                        parentThreadID: "working",
                        taskName: "Completed subtask",
                        status: .completed,
                        displayName: "Worker"
                    ),
                ],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 1_000)
            ),
            SessionActivityMainSession(
                threadID: "recent-complete",
                source: .localActivity,
                taskName: "Recent",
                status: .completed,
                agents: [],
                isActive: true,
                lastActivityAt: Date(timeIntervalSince1970: 2_000_200)
            ),
        ]

        let ordered = SessionActivityMainSession.ordered(sessions)

        XCTAssertEqual(ordered.map(\.threadID), ["working", "waiting", "recent-complete"])
        XCTAssertEqual(ordered[0].agents.map(\.displayName), ["Worker"])
    }

    /// 현행 세션 목록의 배지 생략과 스크롤 영역 제한 검증
    func testActivitySectionIsBadgeFreeAndBoundsCardList() {
        XCTAssertNil(SessionActivitySource.cli.badgeText)
        XCTAssertNil(SessionActivitySource.codexApp.badgeText)
        XCTAssertGreaterThan(CLIActivitySection.cardListMaxHeight, 0)
        XCTAssertEqual(CLIActivitySection.cardListAxis, .vertical)
    }

    /// 취소한 Ping 결과의 일반 실패 문구 노출 방지 검증
    func testProbeCancellationIsDisplayedSeparatelyFromFailure() {
        let now = Date()
        let result = UsageWindowProbeResult(accountID: "C1", status: .cancelled, startedAt: now, completedAt: now)
        let section = UsageWindowProbeSection(
            account: AccountState(id: "C1", status: .normal),
            probe: UsageWindowProbePresentationResult(result: result)
        )
        XCTAssertEqual(section.resultText, "취소됨")
    }

    /// 일괄 강도표의 중복 값·0·음수 처리와 기존 셀별 정책 일치 검증
    func testBatchContributionIntensitiesPreserveExistingRanking() {
        let distributions: [[Int64]] = [[], [0, -1], [1], [1, 1, 1, 1], [0, 1, 1, 2, 3, 10, 10, Int64.max]]
        for distribution in distributions {
            let levels = TokenContributionIntensity.levels(for: distribution)
            for value in distribution {
                XCTAssertEqual(levels[value] ?? .none, TokenContributionIntensity.level(for: value, distribution: distribution))
            }
        }
    }

    /// 화면에 맞춰 축소한 팝오버의 실제 내부 렌더 크기 검증
    func testAccountDetailContentFitsSmallPopoverSize() throws {
        let size = TransientPopoverSizingPolicy.clampedContentSize(
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 620)
        )
        let renderer = ImageRenderer(content: AccountDetailView(
            account: AccountState(id: "C1", status: .notConfigured)
        ))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(size.width))
        XCTAssertEqual(image.height, Int(size.height))
    }

    func testSessionIDFormattingShortensDisplayButPreservesFullCopyValue() {
        let snapshot = SessionActivitySnapshot(
            accountID: "C1",
            state: .available,
            source: .localActivity,
            sessionID: "019fe59b123456",
            status: .working,
            agents: []
        )

        XCTAssertEqual(CLIActivitySection.shortSessionID(snapshot.sessionID), "019fe59b...")
        XCTAssertEqual(CLIActivitySection.copyValue(for: snapshot), "019fe59b123456")
        XCTAssertEqual(CLIActivitySection.shortSessionID(nil), "—")
    }

    func testSessionActivityCopiesCoverLoadingEmptyUnavailableAndStatus() {
        XCTAssertEqual(CLIActivitySection.loadingText, "세션 실행 기록을 불러오는 중입니다…")
        XCTAssertEqual(CLIActivitySection.emptyText, "최근 15분간 실행 기록이 없습니다.")
        XCTAssertTrue(CLIActivitySection.unavailableText.contains("SES-001"))
        XCTAssertTrue(CLIActivitySection.unavailableText.contains("세션 실행 기록을 불러올 수 없습니다."))
        XCTAssertEqual(CLIActivitySection.activityRefreshInterval, 5)
        XCTAssertEqual(CLIActivitySection.cardListMaxHeight, 440)
        XCTAssertEqual(SessionActivityStatus.working.displayText, "작업 중")
        XCTAssertEqual(SessionActivityStatus.waiting.displayText, "대기 중")
        XCTAssertEqual(SessionActivityStatus.completed.displayText, "완료")
        XCTAssertEqual(SessionActivityStatus.stopped.displayText, "중단")
        XCTAssertEqual(SessionActivityStatus.error.displayText, "오류")
        XCTAssertEqual(SessionActivityStatus.unknown.displayText, "확인 불가")

        guard let inactive = SessionActivityStatus(rawValue: "inactive") else {
            XCTFail("inactive status should be normalized")
            return
        }
        XCTAssertEqual(inactive.displayText, "활동 없음")
    }

    func testAccountDetailPopoverUsesPracticalFixedContentSizeAndBoundedActivityCards() {
        XCTAssertEqual(
            AccountDetailView.popoverContentSize,
            CGSize(width: 640, height: 760)
        )
        XCTAssertEqual(CLIActivitySection.cardListMaxHeight, 440)
    }

    func testDashboardPopoverPreferredSizeClampsToVisibleScreen() {
        XCTAssertEqual(
            TransientPopoverSizingPolicy.preferredContentSize,
            CGSize(width: 640, height: 760)
        )
        XCTAssertEqual(
            TransientPopoverSizingPolicy.clampedContentSize(
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 620)
            ),
            CGSize(width: 500, height: 620)
        )
    }

    func testContributionIntensityUsesRelativeNonzeroDistributionAndExplicitNoData() {
        XCTAssertTrue(TokenContributionGrid.notLoadedMessage.contains("업데이트"))
        let distribution: [Int64] = [0, 10, 20, 30, 40]
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 0, distribution: distribution),
            .none
        )
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 10, distribution: distribution),
            .low
        )
        XCTAssertEqual(
            TokenContributionGrid.intensity(for: 40, distribution: distribution),
            .veryHigh
        )
        XCTAssertTrue(
            TokenContributionGrid.isNoData(
                TokenUsageDailyPoint(date: Date(), totals: .zero, sessionCount: 0)
            )
        )
    }

    /// 모든 종료 요일에서 날짜·요일 일치 및 168일 유지와 이전 84일 날짜 보완 검증
    func testContributionWeekdaysFollowActualDatesForEveryEndWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let labels = ["일", "월", "화", "수", "목", "금", "토"]
        let firstEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18)))
        for offset in 0..<7 {
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: firstEnd))
            let snapshot = TokenUsageAggregator(calendar: calendar).emptySnapshot(generatedAt: end)
            XCTAssertEqual(snapshot.dailyPoints.count, 168)
            let legacyPoints = Array(snapshot.dailyPoints.suffix(84))
            let expanded = TokenContributionGrid.normalizedPoints(legacyPoints, calendar: calendar)
            XCTAssertEqual(expanded.count, 168)
            XCTAssertEqual(expanded.first?.date, snapshot.dailyPoints.first?.date)
            XCTAssertEqual(Array(expanded.suffix(84)), legacyPoints)
            XCTAssertEqual(TokenContributionGrid.columnCount, 24)
            XCTAssertEqual(TokenContributionGrid.detailPoint(in: snapshot, hoveredDate: nil, now: end, calendar: calendar).date,
                           calendar.startOfDay(for: end))
            let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: end))
            XCTAssertEqual(TokenContributionGrid.detailPoint(in: snapshot, hoveredDate: yesterday, now: end, calendar: calendar).date,
                           calendar.startOfDay(for: yesterday))
            let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: end))
            let nextPoint = TokenContributionGrid.detailPoint(in: snapshot, hoveredDate: nil, now: nextDay, calendar: calendar)
            XCTAssertEqual(nextPoint.date, calendar.startOfDay(for: nextDay))
            XCTAssertEqual(nextPoint.totals, .zero)
            let first = try XCTUnwrap(snapshot.dailyPoints.first)
            let displayed = TokenContributionGrid.weekdayLabels(startingAt: first.date, calendar: calendar)
            for (index, point) in snapshot.dailyPoints.enumerated() {
                XCTAssertEqual(displayed[index % 7], labels[calendar.component(.weekday, from: point.date) - 1])
            }
        }
    }

    /// 세션 수와 토큰 수가 다른 요약 카드의 실제 렌더링 검증
    func testTokenSummaryRendersDistinctSessionAndTokenCounts() throws {
        let now = Date()
        let snapshot = TokenUsageAggregator().aggregate(sessions: [
            TokenUsageSessionUsage(date: now, inputTokens: 100, outputTokens: 25),
            TokenUsageSessionUsage(date: now, inputTokens: 50, outputTokens: 10),
        ], generatedAt: now)
        XCTAssertEqual(snapshot.totalSessions, 2)
        XCTAssertEqual(snapshot.today.totalTokens, 185)
        let renderer = ImageRenderer(content: TokenUsageSummaryView(snapshot: snapshot).frame(width: 608))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 608)
        XCTAssertGreaterThan(image.height, 100)
    }

    /// 최대 토큰 평균의 정수 변환과 실제 요약 화면 렌더링 검증
    func testTokenSummaryRendersMaximumAverageWithoutOverflow() throws {
        let now = Date()
        let snapshot = TokenUsageAggregator().aggregate(sessions: [
            TokenUsageSessionUsage(date: now, inputTokens: Int64.max, outputTokens: Int64.max),
        ], generatedAt: now)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(snapshot.averageTokensPerSession), Int64.max)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(Double.greatestFiniteMagnitude), Int64.max)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(Double(Int64.max).nextDown), Int64.max - 1023)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(1.4), 1)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(1.5), 2)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(-1), 0)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(.nan), 0)
        XCTAssertEqual(AccountDashboardFormatting.roundedTokenAverage(.infinity), 0)
        let renderer = ImageRenderer(content: TokenUsageSummaryView(snapshot: snapshot).frame(width: 608))
        XCTAssertNotNil(renderer.cgImage)
    }

    /// 백만 경계의 한글 축약과 기존 숫자·초기화 차이 표시 검증
    func testDashboardNumberAndResetDeltaFormattingStayBounded() {
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(0), "0")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(999_999), "999,999")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(1_000_000), "1백만")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(2_000_000), "2백만")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(2_450_000), "2.4백만")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(2_560_000), "2.6백만")
        XCTAssertEqual(AccountDashboardFormatting.tokenCountText(1_000_000_000), "1,000백만")
        XCTAssertEqual(AccountDashboardFormatting.numberText(128_020), "128,020")
        XCTAssertEqual(AccountDashboardFormatting.abbreviatedNumber(1_200), "1.2K")
        XCTAssertEqual(AccountDashboardFormatting.abbreviatedNumber(10_000), "10K")

        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = before.addingTimeInterval(-60)
        let delta = AccountDashboardFormatting.resetDeltaText(before: before, after: after)
        XCTAssertTrue(delta.contains("→"))
        XCTAssertTrue(delta.contains("▼1분"))
    }

    /// 실패한 한도 조회의 기존 날짜를 신규 Reset 시각처럼 표시하지 않는 동작
    func testResetObservationKeepsFailedQuotaRefreshExplicit() {
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = before.addingTimeInterval(-60)
        let text = AccountDashboardFormatting.resetObservationText(
            before: before,
            after: after,
            quotaRefreshSucceeded: false
        )

        XCTAssertTrue(text.contains("기존"))
        XCTAssertTrue(text.contains("한도 조회 실패"))
        XCTAssertFalse(text.contains("→"))
        XCTAssertFalse(text.contains(AccountDashboardFormatting.dateText(after)))
    }

    /// 초기화 시간 고정 영역과 실행 버튼의 사용자 표시명 검증
    func testQuotaResetRefreshSectionUsesConciseKoreanCopy() {
        let idle = UsageWindowProbeSection(account: AccountState(id: "C1", status: .normal))
        let running = UsageWindowProbeSection(
            account: AccountState(id: "C1", status: .normal),
            isRunning: true
        )

        XCTAssertEqual(UsageWindowProbeSection.sectionTitle, "초기화 시간 설정")
        XCTAssertEqual(idle.buttonTitle, "시간 설정")
        XCTAssertEqual(running.buttonTitle, "전송 중…")
    }

    /// 실행 중 이전 결과의 시간·토큰을 현재 요청 값으로 오인하지 않는지 검증
    func testProbeDetailsUseCurrentStartAndHidePreviousTokensWhileSending() {
        let previous = Date(timeIntervalSince1970: 1_800_000_000)
        let current = previous.addingTimeInterval(300)
        let result = UsageWindowProbeResult(accountID: "C1", status: .success,
            startedAt: previous, completedAt: previous.addingTimeInterval(5),
            usage: UsageWindowProbeTokenUsage(inputTokens: 170, outputTokens: 4))
        let presentation = UsageWindowProbePresentationResult(result: result, quotaRefreshSucceeded: true)
        let running = UsageWindowProbeSection(account: AccountState(id: "C1", status: .normal),
            probe: presentation, isRunning: true, runningStartedAt: current)
        XCTAssertEqual(running.lastRunText, AccountDashboardFormatting.dateText(current, timeStyle: .medium))
        XCTAssertEqual(running.tokenText, "—")
        XCTAssertEqual(running.resultText, "전송 중")
        let finished = UsageWindowProbeSection(account: AccountState(id: "C1", status: .normal), probe: presentation, lastExecutionAt: current)
        XCTAssertEqual(finished.lastRunText, AccountDashboardFormatting.dateText(current, timeStyle: .medium))
        XCTAssertEqual(finished.tokenText, "174 토큰")
        XCTAssertEqual(finished.resultText, "전송 완료 · 시각 확인 중")
    }

    /// 빠른 응답에서도 진입 완료 후 퇴장하고 실패 시 중앙에 정지하는지 검증
    func testProbeFlightTransitionsAndReducedMotion() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var flight = ProbeFlightTiming(state: .sending, at: start)
        XCTAssertEqual(flight.snapshot(at: start).progress, 0)
        flight.update(state: .succeeded, at: start.addingTimeInterval(0.1))
        XCTAssertEqual(flight.snapshot(at: start.addingTimeInterval(0.35)).phase, .entering)
        XCTAssertEqual(flight.snapshot(at: start.addingTimeInterval(0.7)).progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(flight.snapshot(at: start.addingTimeInterval(1.1)).phase, .departing)
        XCTAssertEqual(flight.snapshot(at: start.addingTimeInterval(1.6)).progress, 1)
        XCTAssertFalse(flight.snapshot(at: start.addingTimeInterval(1.6)).isAnimating)
        flight.update(state: .sending, at: start.addingTimeInterval(2))
        let hovering = flight.snapshot(at: start.addingTimeInterval(3))
        XCTAssertEqual(hovering.phase, .hovering)
        XCTAssertEqual(hovering.progress, 0.5)
        flight.update(state: .failed, at: start.addingTimeInterval(3))
        let failed = flight.snapshot(at: start.addingTimeInterval(4))
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.progress, 0.5)
        XCTAssertFalse(failed.isAnimating)
        let staticFlight = ProbeFlightTiming(state: .sending, at: start)
            .snapshot(at: start, reduceMotion: true)
        XCTAssertEqual(staticFlight.progress, 0.5)
        XCTAssertFalse(staticFlight.isAnimating)
        let route = CGRect(x: 0, y: 0, width: 500, height: 76)
        XCTAssertLessThan(ProbeFlightRoute.position(at: 0, in: route).point.x, 0)
        XCTAssertEqual(ProbeFlightRoute.position(at: 0.5, in: route).point.x, 250, accuracy: 0.001)
        XCTAssertGreaterThan(ProbeFlightRoute.position(at: 1, in: route).point.x, 500)
    }

    func testDashboardDefaultUsageAndProbeNeverClaimData() async {
        let account = AccountState(id: "C1", status: .notConfigured)
        let cacheMiss = await AccountDashboardDefaults.emptyTokenUsageLookup(account.id)
        XCTAssertNil(cacheMiss)
        let snapshot = await AccountDashboardDefaults.unavailableTokenUsageRefresh(account)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.dailyPoints.count, TokenUsageSnapshot.historyDayCount)

        let result = await AccountDetailView.defaultProbeRunner(account)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failureCategory, .notConfigured)
        XCTAssertNil(result.primaryResetBefore)
        XCTAssertNil(result.primaryResetAfter)
        XCTAssertNil(result.secondaryResetBefore)
        XCTAssertNil(result.secondaryResetAfter)
        XCTAssertNil(result.quotaRefreshSucceeded)
        XCTAssertNil(result.refreshedAccount)
    }

    /// 두 Reset 구간과 갱신 계정 스냅샷 전달
    func testProbeRunnerPropagatesCompositeResetObservation() async {
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let after = before.addingTimeInterval(-60)
        let secondaryBefore = before.addingTimeInterval(7 * 86_400)
        let secondaryAfter = secondaryBefore.addingTimeInterval(-120)
        let boundedResult = UsageWindowProbeResult(
            accountID: "C2",
            status: .success,
            startedAt: before,
            completedAt: after,
            usage: UsageWindowProbeTokenUsage(
                inputTokens: 96_240,
                outputTokens: 31_780,
                totalTokens: 128_020
            )
        )
        let expected = UsageWindowProbePresentationResult(
            result: boundedResult,
            primaryResetBefore: before,
            primaryResetAfter: after,
            secondaryResetBefore: secondaryBefore,
            secondaryResetAfter: secondaryAfter,
            quotaRefreshSucceeded: true,
            refreshedAccount: AccountState(
                id: "C2",
                primaryRemainingPercent: 82,
                secondaryRemainingPercent: 60,
                primaryResetAt: after,
                secondaryResetAt: secondaryAfter,
                status: .normal
            )
        )
        let runner: UsageWindowProbeRunner = { _ in expected }

        let actual = await runner(AccountState(id: "C2", status: .normal))
        XCTAssertEqual(actual.result, boundedResult)
        XCTAssertEqual(actual.primaryResetBefore, before)
        XCTAssertEqual(actual.primaryResetAfter, after)
        XCTAssertEqual(actual.secondaryResetBefore, secondaryBefore)
        XCTAssertEqual(actual.secondaryResetAfter, secondaryAfter)
        XCTAssertEqual(actual.quotaRefreshSucceeded, true)
        XCTAssertEqual(actual.refreshedAccount?.primaryRemainingPercent, 82)
        XCTAssertEqual(actual.refreshedAccount?.secondaryRemainingPercent, 60)
    }

    /// 기존 생성 호출에서 확장 필드가 비어 있는 기본값 유지
    func testProbePresentationNewRefreshFieldsDefaultToNil() {
        let result = UsageWindowProbeResult(
            accountID: "C2",
            status: .failure,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            failureCategory: .timeout
        )
        let presentation = UsageWindowProbePresentationResult(result: result)

        XCTAssertNil(presentation.secondaryResetBefore)
        XCTAssertNil(presentation.secondaryResetAfter)
        XCTAssertNil(presentation.quotaRefreshSucceeded)
        XCTAssertNil(presentation.refreshedAccount)
        XCTAssertTrue(presentation.isCurrentAccount)

        let invalidatedPresentation = UsageWindowProbePresentationResult(
            result: result,
            isCurrentAccount: false
        )
        XCTAssertFalse(invalidatedPresentation.isCurrentAccount)
    }

    /// 새 일반 갱신이 이전 Ping 스냅샷보다 우선
    func testAccountDisplayKeepsNewerNormalRefreshAfterOlderProbe() {
        let olderUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerUpdate = olderUpdate.addingTimeInterval(60)
        let current = AccountState(
            id: "C1",
            primaryRemainingPercent: 88,
            lastUpdated: newerUpdate,
            status: .normal
        )
        let olderProbeAccount = AccountState(
            id: "C1",
            primaryRemainingPercent: 20,
            lastUpdated: olderUpdate,
            status: .normal
        )

        let displayed = AccountDashboardPresentation.accountForDisplay(
            current: current,
            probe: successfulQuotaProbe(refreshing: olderProbeAccount)
        )

        XCTAssertEqual(displayed, current)
    }

    /// Loading·오류 상태의 최신 캐시 한도 유지
    func testAccountDisplayKeepsLatestCachedSnapshotDuringLoadingAndError() {
        let olderUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerUpdate = olderUpdate.addingTimeInterval(60)
        let olderProbeAccount = AccountState(
            id: "C1",
            primaryRemainingPercent: 20,
            lastUpdated: olderUpdate,
            status: .normal
        )

        for status in [AccountStatus.loading, .error] {
            let current = AccountState(
                id: "C1",
                primaryRemainingPercent: 88,
                lastUpdated: newerUpdate,
                status: status,
                errorMessage: status == .error ? "refresh failed" : nil
            )

            let displayed = AccountDashboardPresentation.accountForDisplay(
                current: current,
                probe: successfulQuotaProbe(refreshing: olderProbeAccount)
            )

            XCTAssertEqual(displayed, current, "cached quota during \(status)")
        }
    }

    /// 동일하거나 비교할 시각이 없으면 현재 계정 스냅샷 유지
    func testAccountDisplayKeepsCurrentSnapshotWhenUpdateTimesTieOrAreMissing() {
        let updateTime = Date(timeIntervalSince1970: 1_700_000_000)
        let currentWithTime = AccountState(
            id: "C1",
            primaryRemainingPercent: 88,
            lastUpdated: updateTime,
            status: .normal
        )
        let tiedProbeAccount = AccountState(
            id: "C1",
            primaryRemainingPercent: 20,
            lastUpdated: updateTime,
            status: .normal
        )
        let currentWithoutTime = AccountState(
            id: "C1",
            primaryRemainingPercent: 76,
            status: .normal
        )
        let datedProbeAccount = AccountState(
            id: "C1",
            primaryRemainingPercent: 20,
            lastUpdated: updateTime,
            status: .normal
        )

        XCTAssertEqual(
            AccountDashboardPresentation.accountForDisplay(
                current: currentWithTime,
                probe: successfulQuotaProbe(refreshing: tiedProbeAccount)
            ),
            currentWithTime
        )
        XCTAssertEqual(
            AccountDashboardPresentation.accountForDisplay(
                current: currentWithoutTime,
                probe: successfulQuotaProbe(refreshing: datedProbeAccount)
            ),
            currentWithoutTime
        )
    }

    /// Loading 상태에서 직전 한도 값의 도넛 표시 유지
    func testLoadingAccountRetainsKnownQuotaDonutPresentation() {
        let account = AccountState(
            id: "C1",
            primaryRemainingPercent: 82,
            secondaryRemainingPercent: 60,
            status: .loading
        )
        let presentation = QuotaDonutPresentation(account: account)

        XCTAssertEqual(QuotaDonutState(account: account), .value(60))
        XCTAssertEqual(presentation.centerPercent, 82)
        XCTAssertEqual(presentation.ringPercent, 60)
        XCTAssertFalse(QuotaDonutState(account: account).isLoading)
    }

    /// 이전 한도 값이 없는 Loading 상태의 빈 도넛 표시
    func testLoadingAccountWithoutKnownQuotaRemainsLoading() {
        let account = AccountState(id: "C1", status: .loading)
        let presentation = QuotaDonutPresentation(account: account)

        XCTAssertEqual(QuotaDonutState(account: account), .loading)
        XCTAssertNil(presentation.centerPercent)
        XCTAssertNil(presentation.ringPercent)
        XCTAssertTrue(QuotaDonutState(account: account).isLoading)
    }

    func testDashboardProbeActionRequiresConfiguredIdleAccount() {
        XCTAssertTrue(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .normal),
                isRunning: false
            )
        )
        XCTAssertFalse(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .normal),
                isRunning: true
            )
        )
        XCTAssertFalse(
            AccountDashboardActionState.canRunProbe(
                account: AccountState(id: "C1", status: .notConfigured),
                isRunning: false
            )
        )
    }

    func testPopoverSizingPolicyClampsToFinitePositiveVisibleBounds() {
        let clamped = TransientPopoverSizingPolicy.clampedContentSize(
            preferred: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 250)
        )

        XCTAssertEqual(clamped, CGSize(width: 320, height: 250))
        XCTAssertTrue(clamped.width.isFinite)
        XCTAssertTrue(clamped.height.isFinite)
        XCTAssertGreaterThan(clamped.width, 0)
        XCTAssertGreaterThan(clamped.height, 0)

        let fallback = TransientPopoverSizingPolicy.clampedContentSize(
            preferred: CGSize(width: -1, height: 0),
            visibleFrame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat.infinity)
        )

        XCTAssertEqual(fallback, CGSize(width: 640, height: 760))
    }

    func testMainActiveFallbackAndStatusMappingsRemainVisible() {
        XCTAssertEqual(SessionActivityStatus.map(raw: "running"), .working)
        XCTAssertEqual(SessionActivityStatus.map(raw: "waiting_on_user_input"), .waiting)
        XCTAssertEqual(SessionActivityStatus.map(raw: "completed"), .completed)

        let activeUnknown = SessionActivityMainSession(
            threadID: "active",
            source: .cli,
            taskName: "Active session",
            status: .unknown,
            agents: [],
            isActive: true
        )
        let inactiveUnknown = SessionActivityMainSession(
            threadID: "inactive",
            source: .cli,
            taskName: "Inactive session",
            status: .unknown,
            agents: [],
            isActive: false
        )

        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: activeUnknown)),
            "작업 중"
        )
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: inactiveUnknown)),
            "확인 불가"
        )

        guard let inactiveStatus = SessionActivityStatus(rawValue: "inactive") else {
            XCTFail("inactive status should be normalized")
            return
        }
        let inactive = SessionActivityMainSession(
            threadID: "inactive-descendants",
            source: .cli,
            taskName: "Stale descendants",
            status: inactiveStatus,
            agents: [
                SessionActivityAgent(
                    threadID: "stale-agent",
                    parentThreadID: "inactive-descendants",
                    taskName: "Stale task",
                    status: inactiveStatus
                ),
            ],
            isActive: true
        )
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(for: SessionActivityPresentationItem(session: inactive)),
            "활동 없음"
        )
    }

    func testSessionRowLabelDistinguishesLastKnownFromCurrentActivity() {
        XCTAssertEqual(
            CLIActivitySection.sessionRowLabel(for: .localActivity),
            "최근 세션"
        )
        XCTAssertEqual(
            CLIActivitySection.sessionRowLabel(for: .lastKnown),
            "마지막 확인 세션"
        )
    }

    func testShimmerIsWorkingOnlyAndDisabledForReduceMotion() {
        XCTAssertTrue(ShimmerText.shouldAnimate(status: .working, reduceMotion: false))
        XCTAssertFalse(ShimmerText.shouldAnimate(status: .waiting, reduceMotion: false))
        XCTAssertFalse(ShimmerText.shouldAnimate(status: .working, reduceMotion: true))
        XCTAssertEqual(ShimmerText.animationDuration, 1.5)
    }

    func testSessionActivityLoaderCanReturnInjectedFakeSnapshot() async {
        let account = AccountState(id: "C2", status: .normal)
        let expected = SessionActivitySnapshot(
            accountID: "C2",
            state: .available,
            source: .localActivity,
            sessionID: "fake-session",
            status: .working,
            agents: [
                SessionActivityAgent(
                    threadID: "internal-id",
                    parentThreadID: nil,
                    taskName: "Settings window fix",
                    status: .working
                ),
            ]
        )

        let actual = await CLIActivitySection.loadSnapshot(
            account: account,
            loader: { _ in expected }
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(CLIActivitySection.displayName(for: expected.agents[0]), "Settings window fix")
    }

    func testActivityRefreshLoopLoadsSequentialSnapshotsUntilInjectedSleeperStops() async {
        let recorder = ActivityRefreshRecorder(
            snapshots: [
                .empty(accountID: "C1"),
                SessionActivitySnapshot(
                    accountID: "C1",
                    state: .available,
                    source: .localActivity,
                    sessionID: "root",
                    status: .working,
                    agents: []
                ),
            ]
        )

        await CLIActivitySection.refreshSnapshots(
            account: AccountState(id: "C1", status: .normal),
            interval: 2,
            loader: { _ in await recorder.nextSnapshot() },
            sleep: { interval in
                await recorder.recordSleep(interval)
                if await recorder.sleepCount > 1 {
                    throw CancellationError()
                }
            },
            onSnapshot: { snapshot in
                await recorder.recordDelivered(snapshot)
            }
        )

        let loadedCount = await recorder.loadedCount
        let deliveredCount = await recorder.deliveredCount
        let sleepIntervals = await recorder.sleepIntervals
        let maxConcurrentLoads = await recorder.maxConcurrentLoads
        XCTAssertEqual(loadedCount, 2)
        XCTAssertEqual(deliveredCount, 2)
        XCTAssertEqual(sleepIntervals, [2, 2])
        XCTAssertEqual(maxConcurrentLoads, 1)
    }

    func testRetainedRowsWinOverEmptyAndUnavailableCopies() {
        let active = SessionActivityMainSession(
            threadID: "root",
            source: .cli,
            taskName: "Main task",
            status: .working,
            agents: []
        )
        let empty = SessionActivitySnapshot.empty(accountID: "C1")
        let unavailable = SessionActivitySnapshot.unavailable(accountID: "C1")

        XCTAssertTrue(CLIActivitySection.shouldRenderRetainedSessions(snapshot: empty, retainedSessionCount: 1))
        XCTAssertTrue(CLIActivitySection.shouldRenderRetainedSessions(snapshot: unavailable, retainedSessionCount: 1))
        XCTAssertFalse(CLIActivitySection.shouldRenderRetainedSessions(snapshot: empty, retainedSessionCount: 0))
        XCTAssertEqual(
            CLIActivitySection.mainStatusText(
                for: SessionActivityPresentationItem(session: active)
            ),
            "작업 중"
        )
    }

    func testDuplicateIncomingRootIDsRenderExactlyOneDeterministicItem() {
        let model = SessionActivityPresentationModel()
        let first = makeMainSession(id: "duplicate-root", taskName: "First task")
        let second = makeMainSession(id: "duplicate-root", taskName: "Second task")

        model.update(sessions: [first, second])

        XCTAssertEqual(model.sessions.map(\.id), ["duplicate-root"])
        XCTAssertEqual(model.sessions.first?.taskName, "First task")
    }

    func testDepartingRootDimsImmediatelyAndSchedulesExactlyFiveSecondRemoval() async {
        let gate = PresentationSleepGate()
        let model = SessionActivityPresentationModel(
            sleep: { seconds in await gate.sleep(seconds) }
        )
        let active = makeMainSession(id: "root", taskName: "Main task")

        model.update(sessions: [active])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(model.sessions[0].isDeparting)

        model.update(sessions: [])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(model.sessions[0].isDeparting)
        XCTAssertEqual(model.sessions[0].opacity, 0.45)

        await gate.waitUntilEntered()
        let requestedDurations = await gate.requestedDurations
        XCTAssertEqual(requestedDurations, [5])

        await gate.release()
        await waitForPresentationRemoval(model)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testReappearingRootCancelsPendingRemovalAndRestoresOpacity() async {
        let gate = PresentationSleepGate()
        let model = SessionActivityPresentationModel(
            sleep: { seconds in await gate.sleep(seconds) }
        )
        let active = makeMainSession(id: "root", taskName: "Main task")

        model.update(sessions: [active])
        model.update(sessions: [])
        await gate.waitUntilEntered()

        model.update(sessions: [active])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertFalse(model.sessions[0].isDeparting)
        XCTAssertEqual(model.sessions[0].opacity, 1)

        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.sessions.map(\.id), ["root"])
    }

    private func makeMainSession(id: String, taskName: String) -> SessionActivityMainSession {
        SessionActivityMainSession(
            threadID: id,
            source: .cli,
            taskName: taskName,
            status: .working,
            agents: []
        )
    }

    /// 실제 제거 완료를 최대 2초까지 확인하는 비동기 대기
    private func waitForPresentationRemoval(
        _ model: SessionActivityPresentationModel
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if model.sessions.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testQuotaLevelBoundariesUseRemainingPercentage() {
        let cases: [(Double, QuotaLevel, String)] = [
            (0, .critical, "#FF3B30"),
            (1, .critical, "#FF3B30"),
            (9, .critical, "#FF3B30"),
            (10, .low, "#FF5E57"),
            (29, .low, "#FF5E57"),
            (30, .attention, "#FFB800"),
            (59, .attention, "#FFB800"),
            (60, .normal, "#30D158"),
            (99, .normal, "#30D158"),
            (100, .normal, "#30D158"),
        ]

        for (remaining, expectedLevel, expectedHex) in cases {
            XCTAssertEqual(QuotaColors.level(for: remaining), expectedLevel, "remaining \(remaining)")
            XCTAssertEqual(QuotaColors.color(for: remaining).hex, expectedHex, "remaining \(remaining)")
        }
    }

    func testQuotaPercentagesAreClampedBeforeSemanticClassification() {
        XCTAssertEqual(QuotaColors.level(for: -10), .critical)
        XCTAssertEqual(QuotaColors.level(for: 140), .normal)
        XCTAssertEqual(QuotaColors.clampedPercent(-1), 0)
        XCTAssertEqual(QuotaColors.clampedPercent(101), 100)
    }

    func testNonFinitePercentagesFollowTheExplicitZeroCriticalPolicy() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(QuotaColors.clampedPercent(value), 0)
            XCTAssertEqual(QuotaColors.level(for: value), .critical)
            XCTAssertEqual(QuotaColors.color(for: value).hex, "#FF3B30")
        }

        let account = AccountState(
            id: "C1",
            remainingPercent: .nan,
            status: .normal
        )
        XCTAssertEqual(QuotaDonutState(account: account), .value(0))
    }

    func testAdaptiveTrackColorsRemainExactForBothAppearances() {
        XCTAssertEqual(QuotaColors.trackColor(for: .dark).hex, "#2C2C2E")
        XCTAssertEqual(QuotaColors.trackColor(for: .light).hex, "#E5E5EA")
    }

    /// 최초 조회·갱신 중·갱신 완료 시 노치 소진 구간의 고정 색상 검증
    func testNotchDonutTrackKeepsDarkColorAcrossAppearanceAndRefresh() throws {
        for status in [AccountStatus.loading, .normal] {
            let account = AccountState(
                id: "C1",
                primaryRemainingPercent: 80,
                secondaryRemainingPercent: 50,
                status: status
            )
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: QuotaRingGraphic(
                    account: account,
                    diameter: 80,
                    showAccountLabel: false,
                    fixedAppearance: .dark
                ).environment(\.colorScheme, scheme))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                var pixel = [UInt8](repeating: 0, count: 4)
                try pixel.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(
                        data: bytes.baseAddress,
                        width: 1,
                        height: 1,
                        bitsPerComponent: 8,
                        bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: -40, width: 80, height: 80))
                }
                XCTAssertEqual(pixel, [0x2C, 0x2C, 0x2E, 0xFF], "\(status), \(scheme)")
            }
        }
    }

    func testExhaustedOverallQuotaUsesWhiteDonutTrack() {
        let account = AccountState(
            id: "C1",
            primaryRemainingPercent: 100,
            secondaryRemainingPercent: 0,
            status: .normal
        )
        let presentation = QuotaDonutPresentation(account: account)

        XCTAssertEqual(presentation.trackColor(for: .dark), QuotaColors.white)
        XCTAssertEqual(presentation.trackColor(for: .dark).hex, "#FFFFFF")
    }

    func testDonutCenterTextUsesWhiteOnDarkNotchBackground() {
        XCTAssertEqual(QuotaDonutMetrics.centerTextColor(for: .dark).hex, "#FFFFFF")
        XCTAssertEqual(QuotaDonutMetrics.centerTextColor(for: .light).hex, "#000000")
    }

    func testDonutDiameterFollowsMenuBarHeightWithinTwentyToTwentyTwoPoints() {
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 18), 20)
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 24), 22)
        XCTAssertEqual(QuotaDonutMetrics.diameter(forMenuBarHeight: 40), 22)
        XCTAssertEqual(QuotaDonutMetrics.ringWidth, 3.5)
    }

    func testAccountStatusSymbolsAreStableForNonNormalStates() {
        XCTAssertEqual(QuotaDonutState.loading.centerSymbol, nil)
        XCTAssertEqual(QuotaDonutState.loginRequired.centerSymbol, "!")
        XCTAssertEqual(QuotaDonutState.error.centerSymbol, "×")
    }

    func testUnconfiguredAccountHasExplicitNotConfiguredPresentationWithoutQuota() {
        let state = QuotaDonutState(account: AccountState(id: "C1", remainingPercent: 84, status: .notConfigured))

        XCTAssertEqual(state, .notConfigured)
        XCTAssertNil(state.percent)
        XCTAssertNil(state.centerSymbol)
        XCTAssertFalse(state.showsErrorRing)
        XCTAssertEqual(AccountDetailView.statusText(for: .notConfigured), "Not configured")
    }

    func testTimeoutKeepsRemainingValueAndUsesOnlyCriticalRingPresentation() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 84,
            status: .timeout,
            errorMessage: "Codex request timed out"
        )

        let state = QuotaDonutState(account: account)

        XCTAssertEqual(state, .timedOut(84))
        XCTAssertEqual(state.percent, 84)
        XCTAssertNil(state.centerSymbol)
        XCTAssertEqual(state.ringColor, QuotaColors.critical)
        XCTAssertTrue(state.showsErrorRing)
    }

    func testRecoverableErrorKeepsRemainingValueAndTurnsOnlyTheRingRed() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 84,
            status: .error,
            errorMessage: "Codex app-server exited unexpectedly"
        )

        let state = QuotaDonutState(account: account)

        XCTAssertEqual(state, .transientError(84))
        XCTAssertEqual(state.percent, 84)
        XCTAssertNil(state.centerSymbol)
        XCTAssertEqual(state.ringColor, QuotaColors.critical)
        XCTAssertTrue(state.showsErrorRing)
    }

    func testDefinitiveAccountStatesDoNotReuseQuotaValuesInTheDonut() {
        for status in [AccountStatus.loginRequired, .codexNotFound] {
            let account = AccountState(id: "C1", remainingPercent: 84, status: status)
            let state = QuotaDonutState(account: account)

            XCTAssertNil(state.percent)
            XCTAssertFalse(state == .transientError(84))
        }
    }

    func testLoadingAnimationStateStartsOnceAndResetsOnNormalTransition() {
        var state = QuotaLoadingAnimationState()
        XCTAssertEqual(state.transition(isLoading: false), .none)
        XCTAssertEqual(state.transition(isLoading: true), .start)
        XCTAssertEqual(state.transition(isLoading: true), .none)
        XCTAssertEqual(state.startCount, 1)
        XCTAssertEqual(state.transition(isLoading: false), .stop)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.transition(isLoading: true), .start)
        XCTAssertEqual(state.startCount, 2)
    }

    func testClusterFootprintHasNoImplicitPadding() {
        XCTAssertEqual(
            QuotaClusterMetrics.footprint(itemCount: 2, diameter: 22, spacing: 5),
            CGSize(width: 49, height: 22)
        )
        XCTAssertEqual(SettingsView.refreshIntervalOptions, [1, 5, 10, 30])
        XCTAssertEqual(SettingsView.minimumRefreshIntervalMinutes, 1)
        XCTAssertEqual(SettingsView.maximumRefreshIntervalMinutes, 60)
        XCTAssertEqual(SettingsView.accountPathCount, 4)
    }

    func testRefreshIntervalDraftDoesNotCommitEmptyTextAndCanonicalizesValues() {
        var draft = SettingsView.RefreshIntervalDraft(value: 5)
        draft.replace(text: "")
        XCTAssertNil(draft.commit())

        draft.replace(text: "7")
        XCTAssertEqual(draft.commit(), 7)
        XCTAssertEqual(draft.text, "7")

        draft.replace(text: "1441")
        XCTAssertEqual(draft.commit(), 60)
        XCTAssertEqual(draft.text, "60")

        draft.replace(text: "0")
        XCTAssertEqual(draft.commit(), 5)
        XCTAssertEqual(draft.text, "5")
    }

    func testRefreshIntervalDraftDoesNotCommitPartialOrNonNumericText() {
        var draft = SettingsView.RefreshIntervalDraft(value: 5)

        for partial in ["-", "1x", "   ", ""] {
            draft.replace(text: partial)
            XCTAssertNil(draft.commit(), "partial input (partial.debugDescription) must remain a draft")
            XCTAssertEqual(draft.text, partial)
        }
    }

    func testAccountLabelsAreOptInAcrossCompactPresentationAndSettingsBindings() {
        let account = AccountState(
            id: "C1",
            remainingPercent: 80,
            status: .normal
        )

        let compactDonut = QuotaDonutView(account: account)
        XCTAssertFalse(compactDonut.showAccountLabels)

        let labeledDonut = QuotaDonutView(account: account, showAccountLabels: true)
        XCTAssertTrue(labeledDonut.showAccountLabels)

        let compactCluster = QuotaClusterView(accounts: [account], side: .left)
        XCTAssertFalse(compactCluster.showAccountLabels)

        let labeledCluster = QuotaClusterView(
            accounts: [account],
            side: .left,
            showAccountLabels: true
        )
        XCTAssertTrue(labeledCluster.showAccountLabels)

        let settings = SettingsView(
            refreshIntervalMinutes: .constant(5),
            accountPaths: .constant(["", "", "", ""]),
            launchAtLogin: .constant(false),
            showAccountLabels: .constant(true)
        )
        XCTAssertTrue(settings.showAccountLabels)
    }

    func testCompactValueTextUsesDigitsOnlyForEveryBoundaryWidth() {
        let cases: [(Double, String)] = [
            (0, "0"),
            (9, "9"),
            (99, "99"),
            (100, "100")
        ]

        for (value, expected) in cases {
            let text = QuotaDonutMetrics.compactValueText(value)
            XCTAssertEqual(text, expected, "compact value (value)")
            XCTAssertFalse(text.contains("%"))
        }
    }

    /// 설정의 한글 새로고침 및 자동 실행 표시명 검증
    func testSettingsContentContractKeepsRefreshAndLaunchControlsNamed() {
        XCTAssertEqual(SettingsView.refreshSectionTitle, "새로고침")
        XCTAssertEqual(SettingsView.launchAtLoginLabel, "로그인 시 자동 실행")
        XCTAssertEqual(SettingsView.refreshIntervalOptions, [1, 5, 10, 30])
    }

    func testSettingsPresentationFallsBackOnlyWhenActionIsUnhandledAndReusesFallback() {
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: true, hasFallbackWindow: false),
            .focusSettingsScene
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: false, hasFallbackWindow: false),
            .createFallback
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: false, hasFallbackWindow: true),
            .focusExistingFallback
        )
        XCTAssertEqual(
            SettingsWindowPresentationPolicy.route(actionHandled: true, hasFallbackWindow: true),
            .focusExistingFallback
        )
    }

    func testLogicalAccountSpacingIsEightPointsAndAddsOnlyThreeToTwoAccountWidth() {
        XCTAssertEqual(QuotaDonutMetrics.accountSpacing, 8)

        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )
        let fivePointContent = layout.contentFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let logicalContent = layout.contentFrame(side: .left, itemCount: 2, diameter: 22)
        let fivePointPanel = layout.panelFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let logicalPanel = layout.panelFrame(side: .left, itemCount: 2, diameter: 22)

        XCTAssertEqual(logicalContent.width - fivePointContent.width, 3, accuracy: 0.0001)
        XCTAssertEqual(logicalPanel.width - fivePointPanel.width, 3, accuracy: 0.0001)
        XCTAssertEqual(logicalPanel.width - logicalContent.width, QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
    }

    func testEightPointSpacingStillContainsBothRingsInNarrowAreas() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 50, height: 24),
            auxiliaryTopRightArea: CGRect(x: 250, y: 876, width: 50, height: 24)
        )

        for side in [NotchSide.left, .right] {
            let area = side == .left ? layout.leftArea : layout.rightArea
            let diameter = layout.resolvedDiameter(side: side, itemCount: 2, diameter: 22)
            let content = layout.contentFrame(side: side, itemCount: 2, diameter: 22)
            let items = layout.itemFrames(side: side, itemCount: 2, diameter: 22)
            let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)

            XCTAssertLessThan(diameter, 22)
            XCTAssertEqual(items.count, 2)
            XCTAssertTrue(area.contains(content))
            XCTAssertTrue(items.allSatisfy {
                area.contains($0.insetBy(dx: -inset, dy: -inset))
            })
        }
    }

    /// 양방향 끝 이동·동일 위치·무효 입력에서 슬롯 순열 보존 검증
    func testAccountOrderDropAdjustsInsertionBoundaries() {
        let order = ["C1", "C2", "C3", "C4"]
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C1", toInsertionIndex: 4), ["C2", "C3", "C4", "C1"])
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C4", toInsertionIndex: 0), ["C4", "C1", "C2", "C3"])
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C2", toInsertionIndex: 3), ["C1", "C3", "C2", "C4"])
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C3", toInsertionIndex: 1), ["C1", "C3", "C2", "C4"])
        for destination in [0, 1] {
            XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C1", toInsertionIndex: destination), order)
        }
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "unknown", toInsertionIndex: 2), order)
        XCTAssertEqual(AccountOrderEditor.moving(order, slotID: "C1", toInsertionIndex: 5), order)
    }

    /// 제목을 알림에 표시하고 원본 세션 번호를 노출하지 않는지 검증
    func testNotchActivityToastUsesSafeTwoLineCopyAndSessionTitle() {
        let transition = SessionActivityTransition(
            accountID: "C4",
            side: .right,
            sessionID: "019fe59b123456",
            agentLabel: "Worker",
            taskName: "Settings window fix",
            status: .working,
            sessionTitle: "버튼 동작 개선"
        )
        let toast = SessionActivityToast(
            content: .transition(transition),
            durationSeconds: 5
        )

        let copy = NotchActivityToastCopy.make(for: toast)
        XCTAssertEqual(copy.firstLine, "C4 · 버튼 동작 개선")
        XCTAssertEqual(NotchActivityToastCopy.make(for: toast, names: ["C4": "업무 계정"]).firstLine,
                       "업무 계정 · 버튼 동작 개선")
        XCTAssertEqual(toast.transition?.accountID, "C4")
        XCTAssertEqual(copy.secondLine, "Worker · Settings window fix · 작업 중")
        XCTAssertEqual(copy.lines.count, 2)
        XCTAssertFalse(copy.lines.joined(separator: " ").contains(transition.sessionID!))
    }

    /// 비활성·완료·중단 에이전트 알림의 긴 작업 설명 제외 검증
    func testFinishedAgentToastOmitsTaskDescription() {
        let statuses: [(SessionActivityStatus, String)] = [
            (.inactive, "활동 없음"), (.completed, "완료"), (.stopped, "중단"),
        ]
        for (status, label) in statuses {
            let toast = SessionActivityToast(content: .transition(SessionActivityTransition(
                accountID: "C1", side: .left, sessionID: "parent-session",
                agentLabel: "Worker", taskName: String(repeating: "긴 작업 설명 ", count: 30),
                status: status, sessionTitle: "부모 세션"
            )), durationSeconds: 3)
            let copy = NotchActivityToastCopy.make(for: toast)
            XCTAssertEqual(copy.firstLine, "C1 · 부모 세션")
            XCTAssertEqual(copy.secondLine, "Worker · \(label)")
        }
    }

    /// 긴 제목·에이전트명에서도 알림 최대 폭 제한 및 짧은 알림 폭 보존 검증
    func testToastWidthCapsLongCopyAndPreservesShortCopy() {
        let longToast = SessionActivityToast(content: .transition(SessionActivityTransition(
            accountID: "C1", side: .right, sessionID: "parent-session",
            agentLabel: String(repeating: "Worker", count: 20), taskName: "Task",
            status: .inactive, sessionTitle: String(repeating: "긴 세션 제목 ", count: 30)
        )), durationSeconds: 3)
        XCTAssertEqual(NotchActivityToastMetrics.requiredWidth(for: longToast), 240)
        XCTAssertEqual(NotchActivityToastMetrics.requiredWidth(for: nil), 0)
        let shortToast = SessionActivityToast(content: .overflow(count: 1), durationSeconds: 3)
        XCTAssertLessThan(NotchActivityToastMetrics.requiredWidth(for: shortToast), 240)
    }

    /// 모든 상태 문구·기본 에이전트명·추가 알림의 한글 표시 검증
    func testActivityNotificationsUseKoreanSystemCopy() {
        let statuses: [(SessionActivityStatus, String?)] = [
            (.working, "에이전트 · 작업 중"), (.waiting, "에이전트 · 대기 중"),
            (.inactive, "에이전트 · 활동 없음"), (.completed, "에이전트 · 완료"),
            (.stopped, "에이전트 · 중단"), (.error, "에이전트 · 오류"),
            (.unknown, "에이전트"),
        ]
        for (status, expected) in statuses {
            let toast = SessionActivityToast(content: .transition(SessionActivityTransition(
                accountID: "C1", side: .left, sessionID: "session",
                agentLabel: "Agent", taskName: "Agent", status: status,
                sessionTitle: "My custom session"
            )), durationSeconds: 3)
            let copy = NotchActivityToastCopy.make(for: toast)
            XCTAssertEqual(copy.firstLine, "C1 · My custom session")
            XCTAssertEqual(copy.secondLine, expected)
        }
        let overflow = SessionActivityToast(content: .overflow(count: 5), durationSeconds: 3)
        XCTAssertEqual(overflow.displayText, "추가 활동 알림 5건")
        XCTAssertEqual(NotchActivityToastCopy.make(for: overflow).firstLine, overflow.displayText)
    }

    /// 알 수 없는 제목은 번호로 대체하지 않고 알림 문구에서도 제외하는지 검증
    func testUnknownSessionTitleDoesNotFallBackToSessionID() {
        let transition = SessionActivityTransition(accountID: "C1", side: .left, sessionID: "private-session-id",
            agentLabel: "unknown", taskName: " Unknown ", status: .working, sessionTitle: "Unknown")
        let copy = NotchActivityToastCopy.make(for: SessionActivityToast(content: .transition(transition), durationSeconds: 3))
        XCTAssertEqual(copy.firstLine, "C1")
        XCTAssertEqual(copy.secondLine, "작업 중")
        XCTAssertFalse(copy.lines.joined().contains("private-session-id"))
        XCTAssertFalse(copy.lines.joined().lowercased().contains("unknown"))
    }

    func testNotchActivityToastUsesFallbacksAndCountOnlyOverflowCopy() {
        let transition = SessionActivityTransition(
            accountID: "C1",
            side: .left,
            sessionID: nil,
            agentLabel: nil,
            taskName: nil,
            status: .unknown
        )
        let fallback = NotchActivityToastCopy.make(
            for: SessionActivityToast(content: .transition(transition), durationSeconds: 5)
        )
        XCTAssertEqual(fallback.firstLine, "C1")
        XCTAssertNil(fallback.secondLine)

        let overflow = NotchActivityToastCopy.make(
            for: SessionActivityToast(content: .overflow(count: 3), durationSeconds: 5)
        )
        XCTAssertEqual(overflow.lines, ["추가 활동 알림 3건"])
        XCTAssertFalse(overflow.lines.joined(separator: " ").contains("Session"))
        XCTAssertFalse(overflow.lines.joined(separator: " ").contains("Worker"))
    }

    func testNotchActivityToastAnimationUsesSharedDurations() {
        XCTAssertEqual(NotchActivityToastView.entryAnimationDuration, 0.32)
        XCTAssertEqual(NotchActivityToastView.exitAnimationDuration, 0.28)
        XCTAssertEqual(
            NotchActivityToastPresentation.animationDuration(isPresented: true),
            0.32
        )
        XCTAssertEqual(
            NotchActivityToastPresentation.animationDuration(isPresented: false),
            0.28
        )
        XCTAssertEqual(NotchActivityPresentationModel.entryAnimationDuration,
                       NotchActivityToastPresentation.entryAnimationDuration)
        XCTAssertEqual(NotchActivityPresentationModel.exitAnimationDuration,
                       NotchActivityToastPresentation.exitAnimationDuration)
    }

    func testNotchActivityToastWidthIsFiniteAndOverflowRemainsCompact() {
        let transition = SessionActivityTransition(
            accountID: "C2",
            side: .left,
            sessionID: "short-session",
            agentLabel: "Agent",
            taskName: "A bounded task",
            status: .working
        )
        let regular = SessionActivityToast(content: .transition(transition), durationSeconds: 5)
        let overflow = SessionActivityToast(content: .overflow(count: 4), durationSeconds: 5)

        XCTAssertGreaterThan(NotchActivityToastMetrics.requiredWidth(for: regular), 0)
        XCTAssertLessThan(
            NotchActivityToastMetrics.requiredWidth(for: overflow),
            NotchActivityToastMetrics.requiredWidth(for: regular)
        )
        XCTAssertTrue(
            NotchActivityToastMetrics.requiredWidth(for: regular).isFinite
                && NotchActivityToastMetrics.requiredWidth(for: overflow).isFinite
        )
    }

    func testActivityToastPresentationLifecycleUsesEntryExitAndFinalRemovalOrdering() async {
        let clock = ManualPresentationSleeper()
        let model = NotchActivityPresentationModel(sleep: { duration in
            await clock.sleep(duration)
        })
        let first = makeActivityToast(
            accountID: "C1",
            side: .left,
            sessionID: "first",
            taskName: "First"
        )
        let second = makeActivityToast(
            accountID: "C1",
            side: .left,
            sessionID: "second",
            taskName: "Second"
        )

        model.setToast(first, width: 80)
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(
            model.events,
            [.entry(id: first.id, duration: NotchActivityToastView.entryAnimationDuration)]
        )

        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .entering)
        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .visible)

        model.setToast(second, width: 96)
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.displayedWidth, 80)
        XCTAssertEqual(model.phase, .exiting)
        XCTAssertEqual(
            model.events,
            [
                .entry(id: first.id, duration: 0.32),
                .exit(id: first.id, duration: 0.28),
            ]
        )

        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, first.id)
        XCTAssertEqual(model.phase, .exiting)

        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, second.id)
        XCTAssertEqual(model.displayedWidth, 96)
        XCTAssertEqual(model.phase, .entering)
        XCTAssertEqual(
            model.events,
            [
                .entry(id: first.id, duration: 0.32),
                .exit(id: first.id, duration: 0.28),
                .entry(id: second.id, duration: 0.32),
            ]
        )

        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertEqual(model.phase, .visible)

        model.setToast(nil)
        XCTAssertEqual(model.displayedToast?.id, second.id)
        XCTAssertEqual(model.displayedWidth, 96)
        XCTAssertEqual(model.phase, .exiting)
        await yieldToPresentationTask()
        await clock.releaseNext()
        await yieldToPresentationTask()
        XCTAssertNil(model.displayedToast)
        XCTAssertNil(model.displayedWidth)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(
            model.events.last,
            .removed(id: second.id)
        )
    }

    func testActivityToastPresentationGenerationDropsRapidStaleTargets() async {
        let model = NotchActivityPresentationModel(sleep: { _ in })
        let first = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "first",
            taskName: "First"
        )
        let stale = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "stale",
            taskName: "Stale"
        )
        let final = makeActivityToast(
            accountID: "C2",
            side: .right,
            sessionID: "final",
            taskName: "Final"
        )

        model.setToast(first)
        model.setToast(stale)
        model.setToast(final)
        await yieldToPresentationTask()
        XCTAssertEqual(model.displayedToast?.id, final.id)
        XCTAssertFalse(model.events.contains { event in
            if case let .entry(id, _) = event { return id == stale.id }
            return false
        })
    }

    /// 계정 스냅샷을 담은 성공한 Ping 갱신 결과 구성
    private func successfulQuotaProbe(
        refreshing account: AccountState
    ) -> UsageWindowProbePresentationResult {
        let completedAt = account.lastUpdated ?? Date(timeIntervalSince1970: 0)
        return UsageWindowProbePresentationResult(
            result: UsageWindowProbeResult(
                accountID: account.id,
                status: .success,
                startedAt: completedAt,
                completedAt: completedAt
            ),
            quotaRefreshSucceeded: true,
            refreshedAccount: account
        )
    }

    private func makeActivityToast(
        accountID: String,
        side: AccountPosition,
        sessionID: String,
        taskName: String
    ) -> SessionActivityToast {
        SessionActivityToast(
            content: .transition(
                SessionActivityTransition(
                    accountID: accountID,
                    side: side,
                    sessionID: sessionID,
                    agentLabel: "Worker",
                    taskName: taskName,
                    status: .working
                )
            ),
            durationSeconds: 5
        )
    }

    private func yieldToPresentationTask() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

/// 제거 지연 요청의 실제 진입과 명시적 해제를 제어하는 테스트 경계
private actor PresentationSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [TimeInterval] = []

    /// 요청 시간을 보존하고 테스트의 해제까지 대기
    func sleep(_ duration: TimeInterval) async {
        requestedDurations.append(duration)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    /// 스케줄링 횟수 대신 실제 대기 진입을 최대 2초까지 확인
    func waitUntilEntered() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if !continuations.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("제거 지연 작업의 대기 진입 시간 초과")
    }

    /// 진입한 제거 지연 작업 전체 해제
    func release() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ManualPresentationSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: TimeInterval) async {
        _ = duration
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor ActivityRefreshRecorder {
    private var snapshots: [SessionActivitySnapshot]
    private var loaded = 0
    private var delivered = 0
    private var concurrentLoads = 0
    private(set) var maxConcurrentLoads = 0
    private(set) var sleepIntervals: [TimeInterval] = []

    init(snapshots: [SessionActivitySnapshot]) {
        self.snapshots = snapshots
    }

    func nextSnapshot() -> SessionActivitySnapshot {
        loaded += 1
        concurrentLoads += 1
        maxConcurrentLoads = max(maxConcurrentLoads, concurrentLoads)
        defer { concurrentLoads -= 1 }
        return snapshots.isEmpty ? .unavailable(accountID: "C1") : snapshots.removeFirst()
    }

    func recordSleep(_ interval: TimeInterval) {
        sleepIntervals.append(interval)
    }

    func recordDelivered(_ snapshot: SessionActivitySnapshot) {
        _ = snapshot
        delivered += 1
    }

    var sleepCount: Int { sleepIntervals.count }
    var loadedCount: Int { loaded }
    var deliveredCount: Int { delivered }
}
