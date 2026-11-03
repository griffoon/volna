import Foundation
import Observation

/// Ynison: Yandex's live "what plays where" sync between the account's devices.
/// We join as a remote controller (like the reference Python client): we see other devices,
/// what they play and where, can pause/skip them, and can pull their track onto this phone.
///
/// Wire format: two websockets. The redirector hands out a host + ticket, then the state socket
/// streams `PutYnisonStateResponse` frames as protobuf-JSON (camelCase, int64 as strings).
@MainActor
@Observable
final class Ynison {
    struct Device: Identifiable, Equatable {
        let id: String
        let title: String
        let type: String
        let appName: String
        let isOffline: Bool
    }

    struct Playable: Equatable {
        let trackID: String
        let albumID: String?
        let title: String
        let coverURL: String?

        var ref: String { albumID.map { "\(trackID):\($0)" } ?? trackID }
    }

    struct Snapshot: Equatable {
        var devices: [Device] = []
        var activeDeviceID: String?
        var queue: [Playable] = []
        var currentIndex = -1
        var paused = true
        var progressMs: Double = 0
        var durationMs: Double = 0
        /// When the frame arrived, to extrapolate progress while playing.
        var receivedAt = Date()

        var current: Playable? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
        var activeDevice: Device? { devices.first { $0.id == activeDeviceID } }

        func progress(at date: Date = Date()) -> Double {
            guard !paused else { return progressMs / 1000 }
            return min(durationMs, progressMs + date.timeIntervalSince(receivedAt) * 1000) / 1000
        }
    }

    enum Status: Equatable {
        case idle, connecting, connected
        case failed(String)
    }

    static let shared = Ynison()

    private(set) var status: Status = .idle
    private(set) var snapshot = Snapshot()

    /// Last raw player state, cloned when sending commands so nothing we don't model is lost.
    private var rawPlayerState: [String: Any] = [:]
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private let urlSession = URLSession(configuration: .default)

    private static let deviceTitle = "Волна (iPhone)"
    private static let redirectURL = URL(string: "wss://ynison.music.yandex.ru/redirector.YnisonRedirectService/GetRedirectToYnison")!
    private static let statePath = "ynison_state.YnisonStateService/PutYnisonState"
    private static let pingEvery: Duration = .seconds(20)
    private static let retryAfter: Duration = .seconds(10)

    /// Stable per install, so reconnects don't add new devices to the account.
    private static var deviceID: String {
        let key = "ynisonDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let fresh = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(12))
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: Lifecycle

    func start(token: String) {
        guard runTask == nil || self.token != token else { return }
        stop()
        self.token = token
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: Self.retryAfter)
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .idle
        snapshot = Snapshot()
    }

    private func runOnce() async {
        guard let token else { return }
        status = .connecting
        do {
            let redirect = try await fetchRedirect(token: token)
            guard let url = URL(string: "wss://\(redirect.host)/\(Self.statePath)") else { throw YMError.badResponse }
            let task = urlSession.webSocketTask(with: request(url: url, token: token, redirect: redirect))
            socket = task
            task.resume()
            try await send(fullStateRequest())
            status = .connected
            let pinger = Task { [weak task] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pingEvery)
                    task?.sendPing { _ in }
                }
            }
            defer { pinger.cancel() }
            while !Task.isCancelled {
                let message = try await task.receive()
                if case .string(let text) = message { handle(frame: text) }
            }
        } catch {
            if !Task.isCancelled { status = .failed(error.localizedDescription) }
        }
        socket = nil
    }

    // MARK: Handshake

    private struct Redirect {
        let host: String
        let ticket: String
        let sessionID: String
    }

    private func fetchRedirect(token: String) async throws -> Redirect {
        let task = urlSession.webSocketTask(with: request(url: Self.redirectURL, token: token, redirect: nil))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        guard case .string(let text) = try await task.receive(),
              let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw YMError.badResponse }
        if let error = json["error"] as? [String: Any] { throw Self.serverError(error) }
        guard let host = Self.string(json, "host"),
              let ticket = Self.string(json, "redirectTicket", "redirect_ticket"),
              let session = Self.string(json, "sessionId", "session_id")
        else { throw YMError.badResponse }
        return Redirect(host: host, ticket: ticket, sessionID: session)
    }

    /// Auth goes in a header; device identity rides in the websocket subprotocol list.
    private func request(url: URL, token: String, redirect: Redirect?) -> URLRequest {
        var info: [String: Any] = [
            "Ynison-Device-Id": Self.deviceID,
            "Ynison-Device-Info": Self.jsonString(["app_name": Self.deviceTitle, "type": "1"]),
        ]
        if let redirect {
            info["Ynison-Redirect-Ticket"] = redirect.ticket
            info["Ynison-Session-Id"] = redirect.sessionID
        }
        let encoded = Self.jsonString(info).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var request = URLRequest(url: url)
        request.setValue("https://music.yandex.ru", forHTTPHeaderField: "Origin")
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer, v2, \(encoded)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    // MARK: Frames

    private func handle(frame text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let error = json["error"] as? [String: Any] {
            status = .failed(Self.serverError(error).localizedDescription)
            return
        }
        var next = snapshot
        next.receivedAt = Date()
        if let devices = json["devices"] as? [[String: Any]] {
            next.devices = devices.compactMap { device in
                let info = device["info"] as? [String: Any] ?? [:]
                guard let id = Self.string(info, "deviceId", "device_id"), id != Self.deviceID else { return nil }
                return Device(id: id, title: Self.string(info, "title") ?? "Устройство",
                              type: Self.string(info, "type") ?? "", appName: Self.string(info, "appName", "app_name") ?? "",
                              isOffline: device["isOffline"] as? Bool ?? false)
            }
        }
        next.activeDeviceID = Self.string(json, "activeDeviceIdOptional", "active_device_id_optional")
        if let state = (json["playerState"] ?? json["player_state"]) as? [String: Any] {
            rawPlayerState = state
            let queue = (state["playerQueue"] ?? state["player_queue"]) as? [String: Any] ?? [:]
            let list = (queue["playableList"] ?? queue["playable_list"]) as? [[String: Any]] ?? []
            next.queue = list.compactMap { item in
                guard let id = Self.string(item, "playableId", "playable_id") else { return nil }
                return Playable(trackID: id, albumID: Self.string(item, "albumIdOptional", "album_id_optional"),
                                title: Self.string(item, "title") ?? "",
                                coverURL: Self.string(item, "coverUrlOptional", "cover_url_optional"))
            }
            next.currentIndex = Self.int(queue, "currentPlayableIndex", "current_playable_index") ?? -1
            let status = state["status"] as? [String: Any] ?? [:]
            next.paused = status["paused"] as? Bool ?? true
            next.progressMs = Self.double(status, "progressMs", "progress_ms") ?? 0
            next.durationMs = Self.double(status, "durationMs", "duration_ms") ?? 0
        }
        snapshot = next
    }

    // MARK: Commands (sent as a remote controller)

    func setPaused(_ paused: Bool) async {
        let status: [String: Any] = [
            "progressMs": String(Int(snapshot.progress() * 1000)),
            "durationMs": String(Int(snapshot.durationMs)),
            "paused": paused,
            "playbackSpeed": 1,
            "version": version(),
        ]
        try? await send(wrap(["updatePlayingStatus": ["playingStatus": status]]))
    }

    /// Moves the other device's queue by `delta` tracks.
    func skip(_ delta: Int) async {
        let target = snapshot.currentIndex + delta
        guard snapshot.queue.indices.contains(target) else { return }
        var queue = (rawPlayerState["playerQueue"] ?? rawPlayerState["player_queue"]) as? [String: Any] ?? [:]
        queue.removeValue(forKey: "current_playable_index")
        queue["currentPlayableIndex"] = target
        queue["version"] = version()
        let status: [String: Any] = [
            "progressMs": "0", "durationMs": "0", "paused": snapshot.paused, "playbackSpeed": 1, "version": version(),
        ]
        try? await send(wrap(["updatePlayerState": ["playerState": ["playerQueue": queue, "status": status]]]))
    }

    private func fullStateRequest() -> [String: Any] {
        let zero: [String: Any] = ["deviceId": Self.deviceID, "version": "0", "timestampMs": "0"]
        return [
            "updateFullState": [
                "playerState": [
                    "playerQueue": [
                        "currentPlayableIndex": -1, "entityId": "", "entityType": "VARIOUS",
                        "entityContext": "BASED_ON_ENTITY_BY_DEFAULT", "fromOptional": "",
                        "options": ["repeatMode": "NONE"], "version": zero,
                    ],
                    "status": ["paused": true, "playbackSpeed": 1, "progressMs": "0", "durationMs": "0", "version": zero],
                ],
                "device": [
                    "capabilities": ["canBePlayer": false, "canBeRemoteController": true, "volumeGranularity": 0],
                    "info": ["deviceId": Self.deviceID, "type": "WEB", "title": Self.deviceTitle, "appName": "yandex-music"],
                    "volumeInfo": ["volume": 0],
                ],
                "isCurrentlyActive": false,
            ],
            "rid": UUID().uuidString.lowercased(),
            "playerActionTimestampMs": "0",
            "activityInterceptionType": "DO_NOT_INTERCEPT_BY_DEFAULT",
        ]
    }

    private func wrap(_ update: [String: Any]) -> [String: Any] {
        var request = update
        request["rid"] = UUID().uuidString.lowercased()
        request["playerActionTimestampMs"] = String(Self.nowMs())
        request["activityInterceptionType"] = "DO_NOT_INTERCEPT_BY_DEFAULT"
        return request
    }

    private func version() -> [String: Any] {
        ["deviceId": Self.deviceID, "version": String(UInt64.random(in: 1...999_999_999_999_999_999)),
         "timestampMs": String(Self.nowMs())]
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { return }
        try await socket.send(.string(Self.jsonString(object)))
    }

    // MARK: JSON helpers

    private static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ json: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func int(_ json: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = json[key] as? Int { return value }
            if let value = json[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func double(_ json: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = json[key] as? Double { return value }
            if let value = json[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func serverError(_ error: [String: Any]) -> YMError {
        let code = int(error, "http_code", "httpCode") ?? 0
        return code == 401 || code == 403 ? .unauthorized : .http(code)
    }
}
