// 목적: 슬롯별 표시 여부·이름 초안·순서의 통합 편집
// 이용처: 설정의 단일 계정 목록과 기존 순서 전용 호스트
// 사용방법: 표시·이름 바인딩 전달 시 편집 행, 생략 시 순서 전용 행 구성
// 실행 예시: AccountOrderEditor(order: $order, names: names)
import SwiftUI

/// 슬롯 ID를 보존하며 드롭 확정 시에만 순서를 반영하는 계정 편집기
@MainActor
public struct AccountOrderEditor: View {
    @Binding private var order: [String]
    private let names: [String: String]
    private let enabledAccountIDs: Binding<[String]>?
    private let nameDrafts: Binding<[String: String]>?
    private let onCommitNames: () -> Void
    @State private var draggedSlot: String?
    @State private var insertion: Int?
    @GestureState private var isDragging = false
    @Namespace private var coordinateSpace
    private static let slots = ["C1", "C2", "C3", "C4"]

    /// 기존 순서 편집과 통합 목록의 선택적 표시·이름 바인딩 연결
    public init(order: Binding<[String]>, names: [String: String] = [:],
                enabledAccountIDs: Binding<[String]>? = nil,
                nameDrafts: Binding<[String: String]>? = nil,
                onCommitNames: @escaping () -> Void = {}) {
        _order = order
        self.names = names
        self.enabledAccountIDs = enabledAccountIDs
        self.nameDrafts = nameDrafts
        self.onCommitNames = onCommitNames
    }

    /// 누락 슬롯을 보완한 안정적인 계정 표시 순서 제공
    private var displayedOrder: [String] {
        (order + Self.slots).reduce(into: []) { result, slot in
            if Self.slots.contains(slot), !result.contains(slot) { result.append(slot) }
        }
    }

    /// 계정 행과 목록 기준 드래그 좌표계 구성
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedOrder.enumerated()), id: \.element) { index, slot in
                GeometryReader { geometry in
                    row(slot, index: index, width: geometry.size.width)
                }
                .frame(height: 36)
            }
        }
        .coordinateSpace(name: coordinateSpace)
        .onDisappear { draggedSlot = nil; insertion = nil }
        .onChange(of: isDragging) { _, active in
            if !active { draggedSlot = nil; insertion = nil }
        }
    }

    /// 원본 배열의 삽입 경계를 제거 후 인덱스로 보정하는 순수 이동 함수
    nonisolated public static func moving(
        _ order: [String], slotID: String, toInsertionIndex insertionIndex: Int
    ) -> [String] {
        guard (0...order.count).contains(insertionIndex),
              let source = order.firstIndex(of: slotID) else { return order }
        var result = order
        result.remove(at: source)
        result.insert(slotID, at: insertionIndex - (source < insertionIndex ? 1 : 0))
        return result
    }

    /// 이름 입력·체크 조작과 행 드래그의 충돌 방지
    @ViewBuilder
    private func row(_ slot: String, index: Int, width: CGFloat) -> some View {
        if nameDrafts != nil {
            rowContent(slot, index: index, width: width)
        } else {
            rowContent(slot, index: index, width: width)
                .gesture(dragGesture(slot, width: width))
        }
    }

    /// 표시 체크·슬롯명·이름 입력과 별도 순서 손잡이 구성
    private func rowContent(_ slot: String, index: Int, width: CGFloat) -> some View {
        let label = SettingsAccountLabel.slot(slot)
        let name = AccountDisplayName.resolved(names[slot] ?? "", slotID: slot)
        return HStack(spacing: 8) {
            if let enabledAccountIDs {
                Toggle("\(label) 표시", isOn: Binding(
                    get: { enabledAccountIDs.wrappedValue.contains(slot) },
                    set: { enabled in
                        var ids = enabledAccountIDs.wrappedValue.filter { $0 != slot }
                        if enabled { ids.append(slot) }
                        enabledAccountIDs.wrappedValue = ids
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(label) 표시")
                .accessibilityIdentifier("account-visible-\(slot)")
            }
            Text(label).monospaced().fontWeight(.medium)
            if let nameDrafts {
                TextField("계정 이름 (최대 14자)", text: Binding(
                    get: { nameDrafts.wrappedValue[slot] ?? "" },
                    set: { nameDrafts.wrappedValue[slot] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommitNames)
                .accessibilityLabel("\(label) 사용자 이름")
                .accessibilityIdentifier("account-name-\(slot)")
            } else {
                if name != slot { Text(name).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
                .gesture(dragGesture(slot, width: width))
                .accessibilityLabel("\(label) 순서")
                .accessibilityValue("\(index + 1) / 4")
                .accessibilityAction(named: Text("위로 이동")) { move(slot, offset: -1) }
                .accessibilityAction(named: Text("아래로 이동")) { move(slot, offset: 1) }
                .help("손잡이를 드래그하면 계정 순서가 바뀝니다.")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if insertion == index { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            if index == 3, insertion == 4 { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .opacity(draggedSlot == slot ? 0.55 : 1)
        .accessibilityElement(children: nameDrafts == nil ? .ignore : .contain)
        .accessibilityLabel(name == slot ? label : "\(label), \(name)")
        .accessibilityValue("\(index + 1) / 4")
        .accessibilityAction(named: Text("위로 이동")) { move(slot, offset: -1) }
        .accessibilityAction(named: Text("아래로 이동")) { move(slot, offset: 1) }
    }

    /// 목록 좌표로 삽입 위치 계산 및 목록 밖 드롭의 변경 취소
    private func dragGesture(_ slot: String, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                draggedSlot = slot
                insertion = min(displayedOrder.count, max(0, Int((value.location.y / 36).rounded())))
            }
            .onEnded { value in
                let y = value.location.y
                if value.location.x >= 0, value.location.x <= width,
                   y >= 0, y <= CGFloat(displayedOrder.count * 36),
                   draggedSlot == slot, let insertion {
                    order = Self.moving(displayedOrder, slotID: slot, toInsertionIndex: insertion)
                }
                draggedSlot = nil
                insertion = nil
            }
    }

    /// 접근성 이동 요청의 경계 검사와 즉시 반영
    private func move(_ slot: String, offset: Int) {
        let current = displayedOrder
        guard let index = current.firstIndex(of: slot),
              current.indices.contains(index + offset) else { return }
        draggedSlot = nil
        insertion = nil
        order = Self.moving(current, slotID: slot, toInsertionIndex: index + (offset > 0 ? 2 : -1))
    }
}
