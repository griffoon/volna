import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Two AVPlayers that take turns: the idle one preloads the next track, which gives
/// near-gapless hand-offs and lets us crossfade. Feeds Now Playing and My Wave feedback.
@MainActor
@Observable
final class PlayerEngine {
    enum Source: Equatable {
        case list
        case wave(title: String)
    }

    enum SleepTimer: Equatable {
        case at(Date)
        case endOfTrack
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0 {
        didSet { elapsedStamp = Date() }
    }
    private(set) var duration: Double = 0
    private(set) var source: Source = .list
    private(set) var sleepTimer: SleepTimer?
    var errorMessage: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<Track> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }
    var isWave: Bool { if case .wave = source { true } else { false } }

    private let players = [AVPlayer(), AVPlayer()]
    private var active = 0
    private var activePlayer: AVPlayer { players[active] }
    private var standbyPlayer: AVPlayer { players[1 - active] }
    private var preloaded: (trackID: FlexibleID, item: AVPlayerItem)?
    private var preloadTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var isCrossfading = false
    private var elapsedStamp = Date()
    private var client: YMClient?
    private var wave: WaveSession?
    private var observers: [Any] = []
    private var artwork: (id: String, image: MPMediaItemArtwork)?

    /// Refill My Wave when this many tracks are left.
    private static let waveRefillThreshold = 2
    private static let fadeStep: Duration = .milliseconds(50)

    init() {
        configureAudioSession()
        configureRemoteCommands()
        for player in players {
            player.automaticallyWaitsToMinimizeStalling = true
            observers.append(player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self, weak player] time in
                MainActor.assumeIsolated {
                    guard let self, let player, player === self.activePlayer else { return }
                    self.tick(time)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.activePlayer.currentItem, !self.isCrossfading else { return }
                self.trackEnded()
            }
        })
    }

    func attach(_ client: YMClient?) {
        self.client = client
        if client == nil { stop() }
        StreamResolver.clearCache()
    }

    // MARK: Starting playback

    func play(_ tracks: [Track], startAt start: Int = 0) {
        reportSkipIfNeeded()
        wave = nil
        source = .list
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        invalidatePreload()
        loadCurrent()
    }

    /// My Wave with the user's saved settings, or any rotor seeds (`track:1`, `artist:2`, `activity:x`).
    func startWave(seeds: [String]? = nil, title: String = "Моя волна") {
        guard let client else { return }
        reportSkipIfNeeded()
        let seeds = seeds ?? (["user:onyourwave"] + Preferences.waveSeeds)
        let session = WaveSession(client: client, seeds: seeds)
        wave = session
        source = .wave(title: title)
        queue = []
        index = 0
        invalidatePreload()
        activePlayer.pause()
        isLoading = true
        Task {
            do {
                let tracks = try await session.start()
                guard wave === session else { return }
                queue = tracks
                loadCurrent()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Queue editing

    func playNext(_ track: Track) {
        guard current != nil else { return play([track]) }
        queue.insert(track, at: index + 1)
        invalidatePreload()
        preloadNext()
    }

    func enqueue(_ track: Track) {
        guard current != nil else { return play([track]) }
        if isWave { return playNext(track) }
        queue.append(track)
        if index + 1 == queue.count - 1 { invalidatePreload(); preloadNext() }
    }

    // MARK: Transport

    func togglePlay() {
        guard current != nil else { return }
        if isPlaying { activePlayer.pause() } else { activePlayer.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next() {
        reportSkipIfNeeded()
        advance()
    }

    func previous() {
        if elapsed > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        invalidatePreload()
        loadCurrent()
    }

    func jump(to track: Track) {
        guard let position = queue.firstIndex(of: track) else { return }
        reportSkipIfNeeded()
        index = position
        invalidatePreload()
        loadCurrent()
    }

    func seek(to seconds: Double) {
        activePlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
        updateNowPlaying()
    }

    /// Elapsed time extrapolated between periodic ticks, for smooth lyric animation.
    func liveElapsed(at date: Date) -> Double {
        guard isPlaying, !isLoading else { return elapsed }
        return elapsed + min(date.timeIntervalSince(elapsedStamp), 1)
    }

    // MARK: Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel()
        sleepTimer = timer
        guard case .at(let date) = timer else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await fadeOutAndPause()
        }
    }

    private func fadeOutAndPause() async {
        let player = activePlayer
        for step in stride(from: 1.0, through: 0, by: -0.05) {
            player.volume = Float(step)
            try? await Task.sleep(for: .milliseconds(100))
        }
        player.pause()
        player.volume = 1
        isPlaying = false
        sleepTimer = nil
        updateNowPlaying()
    }

    // MARK: Advancing

    private func trackEnded() {
        if let track = current { wave?.finished(track, played: elapsed) }
        if sleepTimer == .endOfTrack {
            sleepTimer = nil
            activePlayer.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        advance()
    }

    private func advance() {
        guard index + 1 < queue.count else {
            if isWave { refillWave(thenAdvance: true) } else { stopAtEnd() }
            return
        }
        index += 1
        loadCurrent()
    }

    private func reportSkipIfNeeded() {
        guard let track = current, isWave else { return }
        wave?.skipped(track, played: elapsed)
    }

    // MARK: Loading

    private func loadCurrent() {
        guard let track = current else { return }
        loadTask?.cancel()
        fadeTask?.cancel()
        isCrossfading = false
        elapsed = 0
        duration = Double(track.durationMs ?? 0) / 1000
        updateNowPlaying()

        if let ready = preloaded, ready.trackID == track.id, standbyPlayer.currentItem === ready.item {
            preloaded = nil
            let old = activePlayer
            active = 1 - active
            old.pause()
            old.replaceCurrentItem(with: nil)
            startActive()
            return
        }

        isLoading = true
        let quality = Preferences.quality
        loadTask = Task {
            guard let client else { return }
            do {
                let url = try await StreamResolver(client: client).streamURL(for: track.id.value, quality: quality)
                guard !Task.isCancelled else { return }
                standbyPlayer.pause()
                activePlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                startActive()
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "\(track.title): \(error.localizedDescription)"
            }
        }
    }

    private func startActive() {
        activePlayer.volume = 1
        activePlayer.play()
        isPlaying = true
        isLoading = false
        updateNowPlaying()
        if let track = current { wave?.started(track) }
        if isWave, queue.count - index <= Self.waveRefillThreshold {
            refillWave(thenAdvance: false)
        }
        preloadNext()
    }

    private func preloadNext() {
        guard preloaded == nil, queue.indices.contains(index + 1), let client else { return }
        let next = queue[index + 1]
        let quality = Preferences.quality
        preloadTask?.cancel()
        preloadTask = Task {
            guard let url = try? await StreamResolver(client: client).streamURL(for: next.id.value, quality: quality),
                  !Task.isCancelled,
                  queue.indices.contains(index + 1), queue[index + 1].id == next.id
            else { return }
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 30
            standbyPlayer.replaceCurrentItem(with: item)
            standbyPlayer.volume = 0
            standbyPlayer.pause()
            preloaded = (next.id, item)
        }
    }

    private func invalidatePreload() {
        preloadTask?.cancel()
        if preloaded != nil {
            standbyPlayer.replaceCurrentItem(with: nil)
            preloaded = nil
        }
    }

    private func refillWave(thenAdvance: Bool) {
        guard let wave else { return }
        Task {
            guard let tracks = try? await wave.more(), self.wave === wave else { return }
            let known = Set(queue.map(\.id))
            queue.append(contentsOf: tracks.filter { !known.contains($0.id) })
            if thenAdvance, index + 1 < queue.count {
                index += 1
                loadCurrent()
            } else {
                preloadNext()
            }
        }
    }

    // MARK: Crossfade

    private func beginCrossfade(over seconds: Double) {
        guard let ready = preloaded, queue.indices.contains(index + 1), queue[index + 1].id == ready.trackID,
              standbyPlayer.currentItem === ready.item, let finishing = current
        else { return }
        isCrossfading = true
        wave?.finished(finishing, played: elapsed)
        preloaded = nil

        let outgoing = activePlayer
        active = 1 - active
        let incoming = activePlayer
        incoming.volume = 0
        incoming.play()
        index += 1
        elapsed = 0
        duration = Double(current?.durationMs ?? 0) / 1000
        updateNowPlaying()
        if let track = current { wave?.started(track) }

        fadeTask = Task {
            let steps = max(1, Int(seconds * 20))
            for step in 1...steps {
                try? await Task.sleep(for: Self.fadeStep)
                if Task.isCancelled { break }
                let progress = Float(step) / Float(steps)
                incoming.volume = progress
                outgoing.volume = 1 - progress
            }
            outgoing.pause()
            outgoing.replaceCurrentItem(with: nil)
            incoming.volume = 1
            isCrossfading = false
            if isWave, queue.count - index <= Self.waveRefillThreshold { refillWave(thenAdvance: false) }
            preloadNext()
        }
    }

    // MARK: Ticks

    private func tick(_ time: CMTime) {
        elapsed = time.seconds.isFinite ? time.seconds : 0
        if let itemDuration = activePlayer.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        let fade = Preferences.crossfade
        if fade > 0, isPlaying, !isCrossfading, sleepTimer != .endOfTrack, duration > fade * 2,
           duration - elapsed <= fade {
            beginCrossfade(over: fade)
        }
    }

    private func stopAtEnd() {
        activePlayer.pause()
        isPlaying = false
        seek(to: 0)
    }

    private func stop() {
        loadTask?.cancel()
        fadeTask?.cancel()
        invalidatePreload()
        players.forEach { $0.replaceCurrentItem(with: nil) }
        wave = nil
        queue = []
        index = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == false { self?.togglePlay() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPlaying == true { self?.togglePlay() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.fullTitle,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.albums?.first?.title { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork, artwork.id == track.id.value { info[MPMediaItemPropertyArtwork] = artwork.image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if artwork?.id != track.id.value { loadArtwork(for: track) }
    }

    private func loadArtwork(for track: Track) {
        guard let url = CoverURL.make(track.cover, size: 600) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  current?.id == track.id
            else { return }
            artwork = (track.id.value, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            updateNowPlaying()
        }
    }
}
