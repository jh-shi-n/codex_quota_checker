// 목적: 서버 사용량과 당일 로컬 보완값의 잔디·주간 차트 표시
// 이용처: 계정 상세의 유일한 토큰 사용량 영역
// 사용방법: 계정 저장소와 차트 옵션 전달; 제목 옆 도움말에 집계 기준·조회 상태 표시
import Charts
import SwiftUI

/// 저장된 차트 설정 변경을 즉시 반영하는 계정 그래프 호스트
struct AccountTokenUsagePreferencesView: View {
    let account: AccountState
    @ObservedObject var preferences: PreferencesStore
    var body: some View {
        AccountTokenUsageView(account: account, store: .shared, options: preferences.tokenUsageOptions)
    }
}

/// 잔디·날짜별 상세 및 주간 막대·선그래프의 서버 데이터 표시
struct AccountTokenUsageView: View {
    let account: AccountState
    @ObservedObject var store: AccountTokenUsageStore
    var options = TokenUsageOptions()
    @State private var selectedDate: Date?
    @State private var weekOffset = 0
    @State private var isUsageHelpPresented = false

    private var snapshot: AccountTokenUsage? { store.snapshot(for: account) }
    private var localToday: TokenUsageSnapshot? { store.localTodaySnapshot(for: account) }
    private var model: AccountUsageCalendar {
        AccountUsageCalendar(snapshot: snapshot, localToday: localToday, months: options.retentionMonths)
    }
    private var week: [AccountUsageCalendar.Day] { model.week(offset: weekOffset) }

    /// 집계 기준과 하단에서 분리한 조회 상태·오류 안내 구성
    private var usageHelp: String {
        var lines = [
            "오늘 사용량: 서버 값을 우선하고, 없으면 연결 계정의 로컬 세션 기록으로 보완",
            "이전 날짜 사용량: 서버가 제공한 일별 사용량 기준",
            "누적·일 최대 토큰: 서버 집계 기준",
            "날짜는 UTC 기준이며, 미제공 내역은 0과 구분합니다."
        ]
        if model.day(at: nil).isLocal, let localToday {
            lines.append("로컬 조회 \(AccountDashboardFormatting.dateText(localToday.generatedAt, dateStyle: .short, timeStyle: .short))")
        } else if model.day(at: nil).tokens == nil {
            lines.append(store.isLoading(for: account) ? "오늘의 로컬 사용량을 불러오는 중입니다." : "오늘의 로컬 사용량을 확인하지 못했습니다.")
        }
        if snapshot?.days == nil {
            lines.append("서버에서 일별 내역을 제공하지 않았습니다.")
        } else if snapshot?.days?.isEmpty == true {
            lines.append("서버가 반환한 일별 내역이 없습니다.")
        }
        if store.hasFailed(for: account) {
            lines.append(snapshot == nil ? "서버 사용량 조회 실패 · CLI 버전·로그인 방식에 따라 제공되지 않을 수 있습니다." : "서버 갱신 실패 · 마지막 정상 결과 표시 중")
        }
        if let error = store.persistenceError { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("계정 토큰 사용량").font(.headline.weight(.semibold))
                Button { isUsageHelpPresented.toggle() } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.appIcon)
                .help(usageHelp)
                .accessibilityIdentifier("account-token-usage-info-button")
                .accessibilityLabel("토큰 사용량 안내")
                .accessibilityValue(usageHelp)
                .popover(isPresented: $isUsageHelpPresented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("토큰 사용량 안내")
                                .font(.headline)
                            Text(usageHelp)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                    .frame(width: 320, height: 360)
                }
                if !options.weeklyChartEnabled { Text("(최근 24주)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if snapshot != nil || localToday != nil {
                if options.weeklyChartEnabled { weeklyChart } else { heatmap }
                HStack(spacing: 18) {
                    metric("누적 토큰", snapshot?.lifetimeTokens)
                    metric("일 최대 토큰", snapshot?.peakDailyTokens)
                }
                if let snapshot {
                    Text("서버 조회 \(AccountDashboardFormatting.dateText(snapshot.fetchedAt, dateStyle: .short, timeStyle: .short))")
                    .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(store.isLoading(for: account) ? "계정 토큰 사용량을 불러오는 중…" : "우상단 새로고침을 눌러 계정 토큰 사용량을 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            }
        }
        .environment(\.calendar, AccountUsageCalendar.calendar)
        .environment(\.timeZone, AccountUsageCalendar.calendar.timeZone)
        .task(id: "\(account.id)-\(account.configurationGeneration)-\(account.email ?? "")") {
            await store.refresh(for: account)?.value
        }
        .onChange(of: "\(account.id)-\(account.configurationGeneration)-\(account.email ?? "")") { _, _ in
            selectedDate = nil
            weekOffset = 0
            isUsageHelpPresented = false
        }
        .onDisappear { isUsageHelpPresented = false }
        .onChange(of: options) { _, _ in selectedDate = nil; weekOffset = 0 }
    }

    private var heatmap: some View {
        let days = model.heatmap
        let levels = TokenContributionIntensity.levels(for: days.compactMap(\.tokens))
        return ContributionColumnsLayout {
            GeometryReader { geometry in
                let width = max(1, (geometry.size.width - 19) / 24)
                let row = max(1, (geometry.size.height - 53) / 7)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(spacing: 3) {
                            Color.clear.frame(width: 13, height: 13)
                            ForEach(0..<7, id: \.self) { index in
                                let weekday = AccountUsageCalendar.calendar.component(.weekday, from: days[index].date) - 1
                                Text(["일", "월", "화", "수", "목", "금", "토"][weekday])
                                    .font(.caption2).foregroundStyle(.secondary).frame(width: 13, height: row)
                            }
                        }
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<24, id: \.self) { column in
                                let month = AccountUsageCalendar.calendar.component(.month, from: days[column * 7].date)
                                let previous = AccountUsageCalendar.calendar.component(.month, from: days[max(0, column - 1) * 7].date)
                                VStack(spacing: 3) {
                                    Text(column == 0 || month != previous ? "\(month)월" : "")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize().frame(width: width, height: 13, alignment: .leading)
                                    ForEach(0..<7, id: \.self) { index in
                                        cell(days[column * 7 + index], levels: levels, size: min(row, max(1, width - 2)))
                                            .frame(height: row)
                                    }
                                }.frame(width: width)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [2]))
                            .frame(width: 10, height: 10)
                        Text("미제공").font(.caption2).foregroundStyle(.secondary)
                        Text("적음").font(.caption2).foregroundStyle(.secondary)
                        ForEach(TokenContributionIntensity.allCases, id: \.rawValue) { level in
                            RoundedRectangle(cornerRadius: 2).fill(TokenContributionGrid.color(for: level)).frame(width: 10, height: 10)
                        }
                        Text("많음").font(.caption2).foregroundStyle(.secondary)
                    }.frame(height: 11)
                }
            }
            detail(model.day(at: selectedDate)).frame(minHeight: 145)
        }
    }

    /// 잔디 색상·미제공 구분 및 마지막으로 가리킨 날짜 유지
    private func cell(_ day: AccountUsageCalendar.Day, levels: [Int64: TokenContributionIntensity], size: CGFloat) -> some View {
        Button { selectedDate = day.date } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(day.tokens.map { TokenContributionGrid.color(for: levels[$0] ?? .none) } ?? Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(day.tokens == nil ? 0.25 : 0.12),
                                style: StrokeStyle(lineWidth: 0.5, dash: day.tokens == nil ? [2] : []))
                }.frame(width: size, height: size)
        }
        .buttonStyle(.appGraphic)
        .help("\(AccountUsageCalendar.label(day.date)) · \(value(day))")
        .accessibilityLabel("\(AccountUsageCalendar.label(day.date)) · \(value(day))")
        .onHover { hovering in
            if hovering { selectedDate = day.date }
        }
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.appIcon).disabled(weekOffset <= model.minimumWeekOffset).accessibilityLabel("이전 주")
                Text("\(AccountUsageCalendar.label(week[0].date)) – \(AccountUsageCalendar.label(week[6].date))")
                    .font(.caption).monospacedDigit()
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.appIcon).disabled(weekOffset >= 0).accessibilityLabel("다음 주")
                Spacer()
                let known = week.compactMap(\.tokens)
                Text(known.isEmpty ? "주간 내역 미제공" : "제공된 \(known.count)일 합계 \(AccountDashboardFormatting.tokenCountText(known.reduce(0, TokenUsageArithmetic.saturatingAdd)))")
                    .font(.caption.weight(.semibold))
            }
            Chart {
                ForEach(week) { day in
                    if let tokens = day.tokens {
                        if options.chartStyle == .bar {
                            BarMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", tokens))
                                .foregroundStyle(Color.accentColor)
                                .annotation(position: .top, spacing: 6,
                                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    if let selectedDate, model.day(at: selectedDate).date == day.date {
                                        tooltip(day)
                                    }
                                }
                        } else {
                            LineMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", tokens), series: .value("연속 구간", day.segment))
                                .interpolationMethod(.linear).foregroundStyle(Color.accentColor)
                            PointMark(x: .value("날짜", day.date, unit: .day), y: .value("토큰", tokens))
                                .foregroundStyle(Color.accentColor)
                                .annotation(position: .top, spacing: 6,
                                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    if let selectedDate, model.day(at: selectedDate).date == day.date {
                                        tooltip(day)
                                    }
                                }
                        }
                    }
                }
            }
            .chartXScale(domain: week[0].date.addingTimeInterval(-43_200)...week[6].date.addingTimeInterval(43_200))
            .chartYScale(domain: 0...max(5, Double(week.compactMap(\.tokens).max() ?? 0)))
            .chartXAxis { AxisMarks(values: week.map(\.date)) { item in
                AxisValueLabel { if let date = item.as(Date.self) { Text("\(AccountUsageCalendar.calendar.component(.day, from: date))일") } }
            } }
            .chartYAxis { AxisMarks { item in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let tokens = item.as(Int64.self) {
                        Text(AccountDashboardFormatting.tokenCountText(tokens))
                    }
                }
            } }
            .chartXSelection(value: $selectedDate)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            if let frame = proxy.plotFrame {
                                let bounds = geometry[frame]
                                selectedDate = bounds.contains(location) ? proxy.value(atX: location.x - bounds.minX, as: Date.self) : nil
                            }
                        case .ended: selectedDate = nil
                        }
                    }
                }
            }
            .frame(height: 145)
        }
    }

    /// 선택한 막대·점에 인접한 날짜와 토큰량 표시
    private func tooltip(_ day: AccountUsageCalendar.Day) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AccountUsageCalendar.label(day.date)).foregroundStyle(.secondary)
            Text(value(day)).fontWeight(.semibold)
        }
        .font(.caption).monospacedDigit().fixedSize()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    /// 날짜 선택의 계정 합계만 표시; 입력·출력·캐시·세션 추정 제외
    private func detail(_ day: AccountUsageCalendar.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AccountUsageCalendar.label(day.date)).font(.caption.weight(.semibold))
            Text("계정 토큰 합계").font(.caption).foregroundStyle(.secondary)
            Text(value(day)).font(.callout.monospacedDigit())
            Text(day.isLocal ? "연결 계정의 로컬 사용량" : (day.tokens == nil ? "이 날짜의 서버 수치가 없습니다." : "서버 제공 사용량"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 0.5) }
    }

    /// 미제공·미래 날짜와 실제 0 토큰의 표시 구분
    private func value(_ day: AccountUsageCalendar.Day) -> String {
        day.tokens.map { "\(AccountDashboardFormatting.tokenCountText($0)) 토큰\(day.isLocal ? " · 로컬" : "")" } ?? (day.isFuture ? "예정 날짜" : "미제공")
    }

    /// 서버 요약의 선택적 토큰 수치 표시
    private func metric(_ title: String, _ value: Int64?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Text(value.map(AccountDashboardFormatting.tokenCountText) ?? "미제공").monospacedDigit()
                .help(value.map { "\(AccountDashboardFormatting.numberText($0)) 토큰" } ?? "미제공")
        }.font(.caption)
    }

    /// 설정 범위 내 주간 이동과 선택 날짜 초기화
    private func moveWeek(_ direction: Int) {
        weekOffset = min(0, max(model.minimumWeekOffset, weekOffset + direction))
        selectedDate = nil
    }
}
