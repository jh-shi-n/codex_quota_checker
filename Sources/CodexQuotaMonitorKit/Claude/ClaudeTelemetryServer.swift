// 목적: 로컬 전용 OTLP HTTP/JSON 메트릭 수신
// 이용처: 공식 Claude 토큰 카운터의 앱 수집
// 사용방법: start·configure 호출, 명시적 수집 버튼에서 install 호출
// 실행 예시: ClaudeTelemetryServer.shared.start()
import Combine
import Foundation
@preconcurrency import Network

/// 루프백·폴더별 임의 경로·본문 상한으로 제한한 메트릭 수신기
@MainActor
public final class ClaudeTelemetryServer: ObservableObject {
    public static let shared = ClaudeTelemetryServer()
    @Published public private(set) var failureMessage: String?
    @Published public private(set) var listeningPort: UInt16?
    @Published public private(set) var revision = 0
    private let port: UInt16
    private var listener: NWListener?
    private var homes: [String: URL] = [:]
    private var routes: [String: URL] = [:]
    private var connections: [UUID: NWConnection] = [:]

    /// 테스트용 임의 포트 또는 앱의 고정 로컬 포트 지정
    public init(port: UInt16 = 43187) { self.port = port }

    /// 127.0.0.1에만 수신기를 시작하고 실패를 UI에 전달
    public func start() {
        guard listener == nil else { return }
        failureMessage = nil
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.listeningPort = listener.port?.rawValue; self.failureMessage = nil
                    case .failed(let error):
                        AppOperationFailure(.unexpected, "공식 토큰 수집 포트를 열지 못했습니다.", underlying: error).record()
                        self.listeningPort = nil
                        self.failureMessage = "공식 토큰 수집 포트를 열지 못했습니다. 로컬 포트 사용 상태를 확인해 주세요."
                        listener.cancel(); self.listener = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            AppOperationFailure(.unexpected, "공식 토큰 수집기를 시작하지 못했습니다.", underlying: error).record()
            failureMessage = "공식 토큰 수집기를 시작하지 못했습니다."
        }
    }

    /// 현재 등록 경로와 이미 설치한 수집 경로만 연결
    public func configure(_ configs: [AccountConfig]) {
        homes = Dictionary(uniqueKeysWithValues: configs.filter { $0.isConfigured && $0.provider == .claude }.map { ($0.id, $0.home) })
        routes = [:]
        for home in homes.values {
            if let manifest = ClaudeTelemetryConnection.read(home: home),
               let url = URL(string: manifest.endpoint), url.host == "127.0.0.1", url.port == Int(port) {
                routes[url.path] = home
            }
        }
    }

    /// 현재 슬롯의 선택 경로 반환
    public func home(accountID: String) -> URL? { homes[accountID] }

    /// 명시적 버튼 동작에서만 공식 수집 설정을 설치·복원
    public func setEnabled(_ enabled: Bool, home: URL) async throws {
        if enabled {
            start()
            let deadline = Date().addingTimeInterval(3)
            while listeningPort == nil && failureMessage == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard listeningPort != nil, failureMessage == nil else { throw ClaudeQuotaError.telemetryUnavailable }
            let endpoint = register(home: home)
            try ClaudeTelemetryConnection.install(home: home, endpoint: endpoint)
        } else {
            let path = ClaudeTelemetryConnection.read(home: home).flatMap { URL(string: $0.endpoint)?.path }
            try ClaudeTelemetryConnection.remove(home: home)
            if let path { routes[path] = nil }
        }
        revision += 1
    }

    /// 수집 연결의 추측 불가능한 경로 생성 및 테스트 등록
    public func register(home: URL) -> URL {
        let existing = ClaudeTelemetryConnection.read(home: home).flatMap { URL(string: $0.endpoint) }
        let activePort = listeningPort ?? port
        let reusable = existing.flatMap { $0.host == "127.0.0.1" && $0.port == Int(activePort) ? $0 : nil }
        let endpoint = reusable ?? URL(string: "http://127.0.0.1:\(activePort)/\(UUID().uuidString)/v1/metrics")!
        routes[endpoint.path] = home
        return endpoint
    }

    /// 종료 시 수신·기존 연결 정리
    public func stop() {
        listener?.cancel(); listener = nil; listeningPort = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    /// 연결당 10초·본문 2MB 상한 적용
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, accumulated: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if let pending = self?.connections.removeValue(forKey: id) { pending.cancel() }
        }
    }

    /// 분할 수신한 HTTP 요청의 길이·경로를 검증하고 메트릭 본문만 전달
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var input = accumulated
                if let data { input.append(data) }
                guard input.count <= 2_016_384, error == nil else { self.reply(connection, id: id, status: 400); return }
                guard let boundary = input.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete || input.count > 16384 { self.reply(connection, id: id, status: 400) }
                    else { self.receive(connection, id: id, accumulated: input) }
                    return
                }
                let header = String(decoding: input[..<boundary.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ")
                guard boundary.lowerBound <= 16384, request.count == 3, request[0] == "POST", let home = self.routes[String(request[1])],
                      let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[1].trimmingCharacters(in: .whitespaces)),
                      lines.filter({ $0.lowercased().hasPrefix("content-length:") }).count == 1,
                      (0...2_000_000).contains(length), !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else {
                    self.reply(connection, id: id, status: 400); return
                }
                let body = input[boundary.upperBound...]
                guard body.count >= length else {
                    if complete { self.reply(connection, id: id, status: 400) }
                    else { self.receive(connection, id: id, accumulated: input) }
                    return
                }
                do {
                    try await ClaudeTelemetryStore.shared.ingest(Data(body.prefix(length)), home: home)
                    self.revision += 1
                    self.reply(connection, id: id, status: 200)
                } catch { self.reply(connection, id: id, status: 400) }
            }
        }
    }

    /// OTLP 성공 응답 또는 검증 실패를 전송하고 연결 종료
    private func reply(_ connection: NWConnection, id: UUID, status: Int) {
        let data = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        connections[id] = nil
    }
}
