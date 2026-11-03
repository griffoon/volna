import Foundation

/// A rotor session: hands out tracks in batches and reports what the listener did with them,
/// which is how My Wave learns.
@MainActor
final class WaveSession {
    let seeds: [String]
    private let client: YMClient
    private var sessionID: String?
    private var batchID: String?
    private var played: [String] = []

    /// Server only needs the recent tail to avoid repeats.
    private static let queueMemory = 30

    init(client: YMClient, seeds: [String]) {
        self.client = client
        self.seeds = seeds
    }

    func start() async throws -> [Track] {
        let session = try await client.newWaveSession(seeds: seeds)
        sessionID = session.radioSessionId
        batchID = session.batchId
        send(.radioStarted)
        return session.sequence?.map(\.track) ?? []
    }

    func more() async throws -> [Track] {
        guard let sessionID else { return try await start() }
        let next = try await client.waveSessionTracks(sessionID: sessionID, queue: Array(played.suffix(Self.queueMemory)))
        if let batch = next.batchId { batchID = batch }
        return next.sequence?.map(\.track) ?? []
    }

    func started(_ track: Track) {
        played.append(ref(track))
        send(.trackStarted(trackID: ref(track)))
    }

    func finished(_ track: Track, played seconds: Double) {
        send(.trackFinished(trackID: ref(track), played: seconds))
    }

    func skipped(_ track: Track, played seconds: Double) {
        send(.skip(trackID: ref(track), played: seconds))
    }

    private func ref(_ track: Track) -> String {
        track.albumID.map { "\(track.id.value):\($0.value)" } ?? track.id.value
    }

    private func send(_ event: YMClient.WaveEvent) {
        guard let sessionID else { return }
        let client = client
        let batchID = batchID
        Task.detached {
            try? await client.sendWaveFeedback(sessionID: sessionID, batchID: batchID, event: event)
        }
    }
}
