import Foundation

/// A rotor session: hands out tracks in batches and reports what the listener did with them,
/// which is how My Wave learns. Every report's outcome goes to `onLog` so it can be seen.
@MainActor
final class WaveSession {
    let seeds: [String]
    /// Receives lines like `skip 18.4s · ok` or `trackStarted · http 400`.
    var onLog: ((String) -> Void)?

    private let client: YMClient
    private var sessionID: String?
    private var batchID: String?
    private var played: [String] = []
    private var batches = 0

    /// Server only needs the recent tail to avoid repeats.
    private static let queueMemory = 30

    var tag: String? {
        guard let sessionID else { return nil }
        let short = sessionID.filter(\.isHexDigit).prefix(4).lowercased()
        return "sess#\(short.isEmpty ? "0000" : short) · batch \(String(format: "%02d", batches))"
    }

    init(client: YMClient, seeds: [String]) {
        self.client = client
        self.seeds = seeds
    }

    func start() async throws -> [Track] {
        let session = try await client.newWaveSession(seeds: seeds)
        sessionID = session.radioSessionId
        batchID = session.batchId
        batches = 1
        send(.radioStarted, label: "radioStarted")
        return session.sequence?.map(\.track) ?? []
    }

    func more() async throws -> [Track] {
        guard let sessionID else { return try await start() }
        let next = try await client.waveSessionTracks(sessionID: sessionID, queue: Array(played.suffix(Self.queueMemory)))
        if let batch = next.batchId { batchID = batch }
        batches += 1
        log("batch \(String(format: "%02d", batches)) · \(next.sequence?.count ?? 0) trk")
        return next.sequence?.map(\.track) ?? []
    }

    func started(_ track: Track) {
        played.append(ref(track))
        send(.trackStarted(trackID: track.id.value), label: "trackStarted")
    }

    func finished(_ track: Track, played seconds: Double) {
        send(.trackFinished(trackID: track.id.value, played: seconds), label: "finished \(Int(seconds))s")
    }

    func skipped(_ track: Track, played seconds: Double) {
        send(.skip(trackID: track.id.value, played: seconds), label: String(format: "skip %.1fs", seconds))
    }

    func liked(_ track: Track, _ liked: Bool) {
        guard liked else { return }
        send(.like(trackID: track.id.value), label: "like")
    }

    func disliked(_ track: Track) {
        send(.dislike(trackID: track.id.value), label: "dislike")
    }

    private func ref(_ track: Track) -> String {
        track.albumID.map { "\(track.id.value):\($0.value)" } ?? track.id.value
    }

    private func log(_ line: String) {
        onLog?(line)
    }

    private func send(_ event: YMClient.WaveEvent, label: String) {
        guard let sessionID else { return }
        let client = client
        let batchID = batchID
        Task {
            do {
                try await client.sendWaveFeedback(sessionID: sessionID, batchID: batchID, event: event)
                log("\(label) · ok")
            } catch {
                log("\(label) · \(Self.describe(error))")
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case YMError.http(let code): "http \(code)"
        case YMError.unauthorized: "unauthorized"
        default: "err"
        }
    }
}
