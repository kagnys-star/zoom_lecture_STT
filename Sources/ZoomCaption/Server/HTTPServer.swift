import Foundation
import Network

private enum HTTPServerStartError: LocalizedError {
  case timedOut(UInt16)
  case cancelled(UInt16)

  var errorDescription: String? {
    switch self {
    case .timedOut(let port): return "포트 \(port) 서버 준비가 시간 안에 끝나지 않았습니다."
    case .cancelled(let port): return "포트 \(port) 서버가 준비되기 전에 취소되었습니다."
    }
  }
}

/// NWListener 의 바인드 결과는 start() 호출이 아니라 stateUpdateHandler 로 비동기 전달된다.
/// 시작 호출자에게 그 결과를 한 번만 돌려주기 위한 작은 동기화 상자다.
private final class ListenerStartup: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var result: Result<Void, Error>?

  func resolve(_ value: Result<Void, Error>) {
    let shouldSignal = lock.withLock { () -> Bool in
      guard result == nil else { return false }
      result = value
      return true
    }
    if shouldSignal { semaphore.signal() }
  }

  func wait(seconds: Double, port: UInt16) -> Result<Void, Error> {
    guard semaphore.wait(timeout: .now() + seconds) == .success else {
      return .failure(HTTPServerStartError.timedOut(port))
    }
    return lock.withLock { result ?? .failure(HTTPServerStartError.cancelled(port)) }
  }
}

struct HTTPRequest {
  var method: String
  var path: String
  var query: [String: String]
  var headers: [String: String]
  var body: Data

  func json<T: Decodable>(_ type: T.Type) -> T? {
    try? JSONDecoder().decode(type, from: body)
  }
}

struct HTTPResponse {
  var status: Int = 200
  var contentType: String = "text/plain; charset=utf-8"
  var body: Data = Data()
  var extraHeaders: [String: String] = [:]

  static func html(_ s: String) -> HTTPResponse {
    HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(s.utf8))
  }
  static func json(_ object: Any) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(contentType: "application/json; charset=utf-8", body: data)
  }
  static func text(_ s: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
    HTTPResponse(contentType: type, body: Data(s.utf8))
  }
  static func download(_ s: String, filename: String, type: String) -> HTTPResponse {
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
    return HTTPResponse(
      contentType: type,
      body: Data(s.utf8),
      extraHeaders: ["Content-Disposition": "attachment; filename*=UTF-8''\(encoded)"]
    )
  }
  static let notFound = HTTPResponse(status: 404, body: Data("not found".utf8))
}

enum Route {
  case response(HTTPResponse)
  case eventStream
}

/// localhost 전용 최소 HTTP/1.1 서버 + SSE 브로드캐스트.
final class HTTPServer: @unchecked Sendable {
  /// 요청 본문 상한 (교안 PDF 업로드)
  static let maxBodyBytes = 64 << 20

  private let port: NWEndpoint.Port
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "zoomcaption.http")

  private let clientsLock = NSLock()
  private var sseClients: [ObjectIdentifier: NWConnection] = [:]
  private var heartbeat: DispatchSourceTimer?

  var handler: (@Sendable (HTTPRequest) async -> Route)?

  init(port: UInt16) {
    self.port = NWEndpoint.Port(rawValue: port)!
  }

  func start() throws {
    // 루프백에만 바인딩한다. requiredLocalEndpoint 를 쓸 때는 `on:` 을 같이 주면 안 된다.
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

    let l = try NWListener(using: params)
    let startup = ListenerStartup()
    let portValue = port.rawValue
    l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    l.stateUpdateHandler = { state in
      switch state {
      case .ready:
        startup.resolve(.success(()))
      case .failed(let error):
        startup.resolve(.failure(error))
      case .cancelled:
        startup.resolve(.failure(HTTPServerStartError.cancelled(portValue)))
      default:
        break
      }
    }
    l.start(queue: queue)

    // 주소 사용 중 같은 실제 바인드 실패는 start()가 throw하지 않고 위 상태 콜백으로
    // 온다. ready를 확인한 뒤에만 bindServer()에 성공을 돌려줘야 다음 포트 재시도와
    // 중복 인스턴스 감지가 제대로 작동한다.
    switch startup.wait(seconds: 3, port: port.rawValue) {
    case .success:
      break
    case .failure(let error):
      l.cancel()
      throw error
    }
    l.stateUpdateHandler = { state in
      if case .failed(let error) = state {
        logError("웹 서버가 실행 중 실패했습니다: \(error.localizedDescription)")
      }
    }
    listener = l

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 15, repeating: 15)
    timer.setEventHandler { [weak self] in self?.broadcastRaw(": ping\n\n") }
    timer.resume()
    heartbeat = timer
  }

  func stop() {
    heartbeat?.cancel()
    listener?.cancel()
    clientsLock.withLock {
      sseClients.values.forEach { $0.cancel() }
      sseClients.removeAll()
    }
  }

  // MARK: - 연결 처리

  private func accept(_ conn: NWConnection) {
    conn.start(queue: queue)
    receive(conn, buffer: Data())
  }

  private func receive(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if error != nil || (isComplete && data == nil) { conn.cancel(); return }

      var buf = buffer
      if let data { buf.append(data) }

      guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
        if buf.count > 1 << 20 { conn.cancel(); return }
        self.receive(conn, buffer: buf)
        return
      }

      let headerData = buf[buf.startIndex..<headerEnd.lowerBound]
      guard var req = Self.parseHead(headerData) else { conn.cancel(); return }

      let contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
      guard contentLength <= Self.maxBodyBytes else {
        // 교안 PDF 업로드용 상한. 넘으면 메모리를 지키기 위해 거절한다.
        self.send(HTTPResponse(status: 413, contentType: "application/json; charset=utf-8",
                               body: Data(#"{"ok":false,"error":"파일이 너무 큽니다 (최대 64MB)"}"#.utf8)),
                  on: conn, keepAlive: false)
        return
      }
      let bodyStart = headerEnd.upperBound
      let have = buf.count - (bodyStart - buf.startIndex)
      if have < contentLength {
        self.receive(conn, buffer: buf)
        return
      }
      req.body = buf[bodyStart..<(bodyStart + contentLength)]

      Task { [weak self] in
        guard let self, let handler = self.handler else { conn.cancel(); return }
        switch await handler(req) {
        case .response(let res):
          self.send(res, on: conn, keepAlive: false)
        case .eventStream:
          self.startSSE(on: conn, lastEventID: req.headers["last-event-id"])
        }
      }
    }
  }

  private static func parseHead(_ data: Data) -> HTTPRequest? {
    guard let head = String(data: data, encoding: .utf8) else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }

    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    let method = String(requestLine[0])
    let target = String(requestLine[1])

    var path = target
    var query: [String: String] = [:]
    if let qIdx = target.firstIndex(of: "?") {
      path = String(target[..<qIdx])
      let qs = String(target[target.index(after: qIdx)...])
      for pair in qs.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
        let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
        query[key] = value
      }
    }

    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[k] = v
    }

    return HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data())
  }

  private func send(_ res: HTTPResponse, on conn: NWConnection, keepAlive: Bool) {
    var head = "HTTP/1.1 \(res.status) \(Self.reason(res.status))\r\n"
    head += "Content-Type: \(res.contentType)\r\n"
    head += "Content-Length: \(res.body.count)\r\n"
    head += "Cache-Control: no-store\r\n"
    for (k, v) in res.extraHeaders { head += "\(k): \(v)\r\n" }
    head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"

    var out = Data(head.utf8)
    out.append(res.body)
    conn.send(content: out, completion: .contentProcessed { _ in
      if !keepAlive { conn.cancel() }
    })
  }

  private static func reason(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "OK"
    }
  }

  // MARK: - SSE

  private func startSSE(on conn: NWConnection, lastEventID: String?) {
    let head = """
      HTTP/1.1 200 OK\r
      Content-Type: text/event-stream; charset=utf-8\r
      Cache-Control: no-store\r
      Connection: keep-alive\r
      \r

      """
    conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

    // 재연결이면 끊긴 사이의 이벤트를 그대로 다시 흘려준다.
    if let raw = lastEventID, !raw.isEmpty {
      if let frames = replay(lastEventID: raw) {
        if !frames.isEmpty {
          Logger.shared.log(.info, "SSE 재연결 — \(raw) 이후 \(frames.count)개를 다시 보냅니다.")
          conn.send(content: Data(frames.joined().utf8), completion: .contentProcessed { _ in })
        }
      } else {
        // 세대가 다르거나(앱 재시작) 보관함 밖이다. 이때만 전체를 다시 받으라고 시킨다.
        Logger.shared.log(.warn, "SSE 재연결 — \(raw) 는 이어 붙일 수 없어 전체 재동기화를 요청합니다.")
        conn.send(content: Data("event: resync\ndata: {\"reason\":\"이어 붙일 수 없음\"}\n\n".utf8),
                  completion: .contentProcessed { _ in })
      }
    }

    clientsLock.withLock { sseClients[ObjectIdentifier(conn)] = conn }

    conn.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled, .failed:
        self?.clientsLock.withLock { _ = self?.sseClients.removeValue(forKey: ObjectIdentifier(conn)) }
      default: break
      }
    }
  }

  /// 이벤트 일련번호와 최근 이벤트 보관함.
  ///
  /// SSE 규격에는 재전송 장치가 이미 있다. 서버가 `id:` 를 붙여 보내면 브라우저는
  /// 끊겼다 다시 붙을 때 `Last-Event-ID` 헤더에 마지막으로 받은 번호를 담아 보낸다.
  /// 그러면 서버가 그다음 것부터 다시 흘려주면 끝이다 — 화면이 스스로 전체를
  /// 다시 받을 필요가 없다.
  ///
  /// **휘발성 이벤트(volatile)는 보관하지 않는다.** 지금 받아쓰는 중인 글자라
  /// 나중에 다시 보내봐야 의미가 없고, 초당 여러 번 나와서 보관함을 순식간에 밀어낸다.
  /// 이 프로세스의 세대 식별자.
  ///
  /// 앱을 다시 켜면 번호는 1부터 시작한다. 그런데 브라우저는 여전히 옛 번호를 들고
  /// 재연결하기 때문에, 번호만 봐서는 "아직 안 온 이벤트" 인지 "다른 세대의 번호" 인지
  /// 구분할 수 없다. 세대를 같이 실어 보내면 그 판단이 확실해진다.
  let bootID = UUID().uuidString.prefix(8).lowercased()

  private let seqLock = NSLock()
  private var _seq = 0
  private var replayBuffer: [(seq: Int, frame: String)] = []
  /// 90분 수업이면 확정 이벤트가 대략 700~900개다. 넉넉히 잡는다.
  private static let replayCapacity = 2000

  var currentSeq: Int { seqLock.withLock { _seq } }

  /// - Parameter durable: 재전송 대상인지. 지금 상태를 덧칠하는 이벤트만 false.
  func broadcast(event: String, payload: Any, durable: Bool = true) {
    var body = (payload as? [String: Any]) ?? ["value": payload]

    guard durable else {
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
      broadcastRaw("event: \(event)\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n")
      return
    }

    let frame: String = seqLock.withLock {
      _seq += 1
      body["_seq"] = _seq
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
      let json = String(data: data, encoding: .utf8) ?? "{}"
      let f = "id: \(bootID)-\(_seq)\nevent: \(event)\ndata: \(json)\n\n"
      replayBuffer.append((_seq, f))
      if replayBuffer.count > Self.replayCapacity {
        replayBuffer.removeFirst(replayBuffer.count - Self.replayCapacity)
      }
      return f
    }
    broadcastRaw(frame)
  }

  /// `Last-Event-ID`("<세대>-<번호>") 이후의 이벤트를 돌려준다.
  /// 세대가 다르거나 보관함에서 밀려났으면 nil — 그때만 전체를 다시 받으라고 알린다.
  private func replay(lastEventID raw: String) -> [String]? {
    let parts = raw.split(separator: "-", maxSplits: 1)
    guard parts.count == 2, parts[0] == bootID, let id = Int(parts[1]) else { return nil }
    return seqLock.withLock {
      guard id <= _seq else { return nil }              // 우리가 낸 적 없는 번호
      guard let oldest = replayBuffer.first?.seq else { return id == _seq ? [] : nil }
      guard id >= oldest - 1 else { return nil }        // 보관함 밖으로 밀려남
      return replayBuffer.filter { $0.seq > id }.map(\.frame)
    }
  }

  private func broadcastRaw(_ s: String) {
    let data = Data(s.utf8)
    let clients = clientsLock.withLock { Array(sseClients.values) }
    for c in clients {
      c.send(content: data, completion: .contentProcessed { _ in })
    }
  }
}
