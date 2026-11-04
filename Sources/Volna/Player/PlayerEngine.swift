import AVFoundation
import os
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
    private(set) var isPlaying = false {
        didSet { if !isPlaying, oldValue { pausedAt = Date() } }
    }
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0 {
        didSet { elapsedStamp = Date() }
    }
    private(set) var duration: Double = 0
    private(set) var source: Source = .list
    private(set) var sleepTimer: SleepTimer?
    /// Codec and bitrate of what is playing now, for the HUD.
    private(set) var stream: StreamSource?
    var errorMessage: String?

    /// `sess#7f3a | batch 07` while a rotor session runs.
    var waveTag: String? { wave?.tag }
    /// Latest reports to Yandex and how they went, newest last.
    private(set) var reportLog: [String] = []
    /// Needed for `/play-audio`; set once the account is known.
    var uid: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<Track> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }
    var nextTrack: Track? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }
    var previousTrack: Track? { queue.indices.contains(index - 1) ? queue[index - 1] : nil }
    var isWave: Bool { if case .wave = source { true } else { false } }

    private let players = [AVPlayer(), AVPlayer()]
    private var active = 0
    private var activePlayer: AVPlayer { players[active] }
    private var standbyPlayer: AVPlayer { players[1 - active] }
    private var preloaded: (trackID: FlexibleID, item: AVPlayerItem, source: StreamSource)?
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
    /// The listen in progress, reported to `/play-audio` when it starts and when it ends.
    private var listen: (track: Track, playID: String, from: String)?

    private var pausedAt: Date?
    private var retriedTrackID: FlexibleID?
    private var consecutiveFailures = 0
    private var restoredPending = false
    private var lastRemembered = Date.distantPast
    private static let rememberEvery: TimeInterval = 10

    private static let logLength = 6
    /// After this long on pause the stream link is assumed dead and refetched on resume.
    private static let staleAfter: TimeInterval = 15 * 60
    private static let maxConsecutiveFailures = 4
    private static let collectionFrom = "mobile-own_collection-default"

    /// Refill My Wave when this many tracks are left.
    private static let waveRefillThreshold = 2
    private static let fadeStep: Duration = .milliseconds(50)

    /// The player whose sound is heard, read by the analyzer clock from any thread.
    nonisolated(unsafe) private static let audible = OSAllocatedUnfairLock<AVPlayer?>(uncheckedState: nil)

    init() {
        AudioAnalyzer.shared.clock = {
            guard let player = PlayerEngine.audible.withLock({ $0 }), let item = player.currentItem,
                  let tap = AudioAnalyzer.shared.tapID(for: item) else { return nil }
            let time = player.currentTime().seconds
            return time.isFinite ? (tap, time) : nil
        }
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
        observeSystemPauses()
    }

    /// Keeps `isPlaying` honest when iOS pauses us: unplugged headphones, calls, Siri, other apps.
    private func observeSystemPauses() {
        for player in players {
            observers.append(player.observe(\.currentItem?.status) { [weak self, weak player] observed, _ in
                let failed = observed.currentItem?.status == .failed
                Task { @MainActor in
                    guard failed, let self, let player, player === self.activePlayer else { return }
                    self.recoverFromItemFailure()
                }
            })
            observers.append(player.observe(\.timeControlStatus) { [weak self, weak player] observed, _ in
                let status = observed.timeControlStatus
                Task { @MainActor in
                    guard let self, let player, player === self.activePlayer,
                          !self.isLoading, !self.isCrossfading, player.currentItem != nil else { return }
                    let nearEnd = self.duration > 0 && self.elapsed > self.duration - 0.6
                    if status == .paused, self.isPlaying, !nearEnd {
                        self.isPlaying = false
                        self.updateNowPlaying()
                    } else if status == .playing, !self.isPlaying {
                        self.isPlaying = true
                        self.updateNowPlaying()
                    }
                }
            })
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.activePlayer.currentItem else { return }
                self.recoverFromItemFailure()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated {
                guard let self,
                      let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                if type == .began {
                    self.isPlaying = false
                } else if let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
                          AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume),
                          self.current != nil {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.activePlayer.play()
                    self.isPlaying = true
                }
                self.updateNowPlaying()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable else { return }
                self.activePlayer.pause()
                self.isPlaying = false
                self.updateNowPlaying()
            }
        })
    }

    func attach(_ client: YMClient?) {
        self.client = client
        if client == nil { stop(); PlaybackMemory.clear() }
        StreamResolver.clearCache()
        if client != nil, queue.isEmpty { restore() }
    }

    // MARK: Remembering where we stopped

    /// Puts back the last queue and position, paused; Play continues from there.
    private func restore() {
        guard let saved = PlaybackMemory.load(), saved.tracks.indices.contains(saved.index) else { return }
        source = .list
        resetOrder()
        queue = saved.tracks
        index = saved.index
        elapsed = saved.position
        duration = Double(current?.durationMs ?? 0) / 1000
        restoredPending = true
        updateNowPlaying()
    }

    private func remember() {
        guard !queue.isEmpty else { return }
        PlaybackMemory.save(tracks: queue, index: index, position: elapsed)
        lastRemembered = Date()
    }

    // MARK: Starting playback

    func play(_ tracks: [Track], startAt start: Int = 0) {
        reportSkipIfNeeded()
        wave = nil
        source = .list
        resetOrder()
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        invalidatePreload()
        loadCurrent()
    }

    /// Starts `tracks` at a given second, e.g. when taking over playback from another device.
    func play(_ tracks: [Track], startAt start: Int, position: Double) {
        reportSkipIfNeeded()
        wave = nil
        source = .list
        resetOrder()
        queue = tracks
        index = max(0, min(start, tracks.count - 1))
        invalidatePreload()
        loadCurrent(resumeAt: position > 1 ? position : nil, freshListen: true)
    }

    /// My Wave with the user's saved settings, or any rotor seeds (`track:1`, `artist:2`, `activity:x`).
    func startWave(seeds: [String]? = nil, title: String = "Моя волна") {
        guard let client else { return }
        reportSkipIfNeeded()
        let seeds = seeds ?? (["user:onyourwave"] + Preferences.waveSeeds)
        let session = WaveSession(client: client, seeds: seeds)
        session.onLog = { [weak self] line in self?.log(line) }
        wave = session
        source = .wave(title: title)
        resetOrder()
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

    // MARK: Listening reports

    private func beginListen(_ track: Track) {
        let from = isWave ? YMClient.waveFrom : Self.collectionFrom
        listen = (track, UUID().uuidString.lowercased(), from)
        reportListen(played: 0, position: 0, label: nil)
    }

    private func endListen() {
        guard listen != nil else { return }
        reportListen(played: elapsed, position: elapsed, label: "play-audio \(Int(elapsed))s")
        listen = nil
    }

    private func reportListen(played: Double, position: Double, label: String?) {
        guard let listen, let client, let uid else {
            if let label { log("\(label) | no uid") }
            return
        }
        Task {
            do {
                try await client.playAudio(track: listen.track, uid: uid, from: listen.from,
                                           playID: listen.playID, played: played, position: position)
                if let label { log("\(label) | ok") }
            } catch {
                log("\(label ?? "play-audio start") | \(WaveSession.describe(error))")
            }
        }
    }

    private func log(_ line: String) {
        reportLog.append(line)
        if reportLog.count > Self.logLength { reportLog.removeFirst(reportLog.count - Self.logLength) }
    }

    /// Likes and dislikes are part of what My Wave learns from.
    func noteLike(_ track: Track, liked: Bool) {
        if isWave { wave?.liked(track, liked) }
    }

    func noteDislike(_ track: Track) {
        if isWave { wave?.disliked(track) }
        if current?.id == track.id { next() }
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
        if restoredPending {
            restoredPending = false
            return loadCurrent(resumeAt: elapsed, freshListen: true)
        }
        if !isPlaying, let pausedAt, Date().timeIntervalSince(pausedAt) > Self.staleAfter {
            // Stream links expire; after a long pause fetch a fresh one and continue from here.
            return loadCurrent(resumeAt: elapsed)
        }
        if isPlaying { activePlayer.pause() } else { activePlayer.play() }
        isPlaying.toggle()
        updateNowPlaying()
        if !isPlaying { remember() }
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
        endListen()
        index -= 1
        invalidatePreload()
        loadCurrent()
    }

    /// Swipe-back: always the previous track, unlike the button which first restarts this one.
    func goBack() {
        guard index > 0 else { return seek(to: 0) }
        reportSkipIfNeeded()
        index -= 1
        invalidatePreload()
        loadCurrent()
    }

    /// By position, so a track that appears twice in the queue jumps to the right copy.
    func jump(toIndex position: Int) {
        guard queue.indices.contains(position) else { return }
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

    // MARK: Repeat and shuffle

    enum RepeatMode: Equatable {
        case off, all, one
    }

    /// The wave never ends, so there it is only off or one track; lists also get «all».
    private(set) var repeatMode: RepeatMode = .off
    /// Shuffle only makes sense for a list; the wave picks its own order.
    private(set) var isShuffled = false
    /// The list in its original order while shuffled, to restore it.
    private var unshuffledQueue: [Track]?

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = isWave ? .one : .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        invalidatePreload()
        preloadNext()
    }

    func toggleShuffle() {
        guard !isWave, let track = current else { return }
        if isShuffled, let original = unshuffledQueue {
            // Back to the original order, staying on the track that plays now.
            queue = original
            index = original.firstIndex { $0.id == track.id } ?? 0
            unshuffledQueue = nil
            isShuffled = false
        } else {
            unshuffledQueue = queue
            var rest = queue
            rest.remove(at: index)
            queue = [track] + rest.shuffled()
            index = 0
            isShuffled = true
        }
        invalidatePreload()
        preloadNext()
    }

    /// A new list or a wave starts in its own order; repeat-all doesn't apply to the wave.
    private func resetOrder() {
        isShuffled = false
        unshuffledQueue = nil
        if isWave, repeatMode == .all { repeatMode = .off }
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
        endListen()
        if let track = current { wave?.finished(track, played: elapsed) }
        if sleepTimer == .endOfTrack {
            sleepTimer = nil
            activePlayer.pause()
            isPlaying = false
            updateNowPlaying()
            return
        }
        if repeatMode == .one, let track = current {
            // Same track again from the top; counts as a fresh listen.
            activePlayer.seek(to: .zero)
            activePlayer.play()
            elapsed = 0
            isPlaying = true
            updateNowPlaying()
            wave?.started(track)
            beginListen(track)
            return
        }
        advance()
    }

    private func advance() {
        guard index + 1 < queue.count else {
            if repeatMode == .all, !isWave, !queue.isEmpty {
                index = 0
                invalidatePreload()
                loadCurrent()
                return
            }
            if isWave {
                refillWave(thenAdvance: true)
            } else if let last = current {
                // The music never stops: a finished list rolls into a wave seeded by its last track.
                startWave(seeds: ["track:\(last.id.value)"], title: "Волна по треку")
            } else {
                stopAtEnd()
            }
            return
        }
        index += 1
        loadCurrent()
    }

    /// Called whenever the current track is abandoned before its end.
    private func reportSkipIfNeeded() {
        endListen()
        guard let track = current, isWave else { return }
        wave?.skipped(track, played: elapsed)
    }

    // MARK: Loading

    private func loadCurrent(resumeAt resume: Double? = nil, freshListen: Bool = false) {
        guard let track = current else { return }
        restoredPending = false
        if resume == nil { retriedTrackID = nil }
        loadTask?.cancel()
        fadeTask?.cancel()
        isCrossfading = false
        elapsed = resume ?? 0
        duration = Double(track.durationMs ?? 0) / 1000
        updateNowPlaying()

        if resume == nil, let ready = preloaded, ready.trackID == track.id, standbyPlayer.currentItem === ready.item {
            preloaded = nil
            stream = ready.source
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
                let source = try await StreamResolver(client: client).stream(for: track.id.value, quality: quality)
                guard !Task.isCancelled else { return }
                standbyPlayer.pause()
                stream = source
                activePlayer.replaceCurrentItem(with: Self.makeItem(source.url, loudness: track.r128))
                if let resume { await activePlayer.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                startActive(resumed: resume != nil && !freshListen)
            } catch {
                guard !Task.isCancelled else { return }
                skipUnplayable(track, reason: WaveSession.describe(error))
            }
        }
    }

    private func startActive(resumed: Bool = false) {
        let audiblePlayer = activePlayer
        Self.audible.withLock { $0 = audiblePlayer }
        activePlayer.volume = 1
        activePlayer.play()
        isPlaying = true
        isLoading = false
        updateNowPlaying()
        // A resumed stream is the same listen continuing, not a new one.
        if !resumed, let track = current {
            wave?.started(track)
            beginListen(track)
        }
        remember()
        if isWave, queue.count - index <= Self.waveRefillThreshold {
            refillWave(thenAdvance: false)
        }
        preloadNext()
    }

    /// A track that won't play is skipped quietly; only a run of failures interrupts the user.
    private func skipUnplayable(_ track: Track, reason: String) {
        isLoading = false
        consecutiveFailures += 1
        log("skip «\(track.title.lowercased())» | \(reason)")
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            consecutiveFailures = 0
            activePlayer.pause()
            isPlaying = false
            errorMessage = "Подряд не играют \(Self.maxConsecutiveFailures) трека. Проверь интернет или подписку."
            return
        }
        advance()
    }

    /// The playing item died (expired link, network drop): fetch a fresh link once and continue
    /// from the same spot; if that fails too, skip the track.
    private func recoverFromItemFailure() {
        guard let track = current, !isLoading else { return }
        if retriedTrackID != track.id {
            retriedTrackID = track.id
            log("relink «\(track.title.lowercased())»")
            loadCurrent(resumeAt: elapsed)
        } else {
            skipUnplayable(track, reason: "stream failed")
        }
    }

    private func preloadNext() {
        guard preloaded == nil, queue.indices.contains(index + 1), let client else { return }
        let next = queue[index + 1]
        let quality = Preferences.quality
        preloadTask?.cancel()
        preloadTask = Task {
            guard let source = try? await StreamResolver(client: client).stream(for: next.id.value, quality: quality),
                  !Task.isCancelled,
                  queue.indices.contains(index + 1), queue[index + 1].id == next.id
            else { return }
            let item = Self.makeItem(source.url, loudness: next.r128)
            item.preferredForwardBufferDuration = 30
            standbyPlayer.replaceCurrentItem(with: item)
            standbyPlayer.volume = 0
            standbyPlayer.pause()
            preloaded = (next.id, item, source)
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

    private static func makeItem(_ url: URL, loudness: Loudness?) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        AudioAnalyzer.shared.attach(to: item, loudness: loudness)
        return item
    }

    // MARK: Crossfade

    private func beginCrossfade(over seconds: Double) {
        guard repeatMode != .one,
              let ready = preloaded, queue.indices.contains(index + 1), queue[index + 1].id == ready.trackID,
              standbyPlayer.currentItem === ready.item, let finishing = current
        else { return }
        isCrossfading = true
        endListen()
        wave?.finished(finishing, played: elapsed)
        preloaded = nil
        stream = ready.source

        let outgoing = activePlayer
        active = 1 - active
        let incoming = activePlayer
        Self.audible.withLock { $0 = incoming }
        incoming.volume = 0
        incoming.play()
        index += 1
        elapsed = 0
        duration = Double(current?.durationMs ?? 0) / 1000
        updateNowPlaying()
        if let track = current {
            wave?.started(track)
            beginListen(track)
        }

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
        if elapsed > 2 { consecutiveFailures = 0 }
        if Date().timeIntervalSince(lastRemembered) > Self.rememberEvery { remember() }
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
        endListen()
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
        // Like / dislike on the lock screen and in Control Center: teach the wave without unlocking.
        center.likeCommand.localizedTitle = "Нравится"
        center.likeCommand.localizedShortTitle = "Нравится"
        center.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let track = self.current else { return }
                self.remoteLike?(track)
            }
            return .success
        }
        center.dislikeCommand.localizedTitle = "Не рекомендовать"
        center.dislikeCommand.localizedShortTitle = "Не то"
        center.dislikeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let track = self.current else { return }
                self.remoteDislike?(track)
            }
            return .success
        }
    }

    /// Lock-screen like/dislike reach the account through these (set by the app).
    var remoteLike: ((Track) -> Void)?
    var remoteDislike: ((Track) -> Void)?
    /// Tells the lock screen whether the current track is already liked.
    var isLikedProvider: ((Track) -> Bool)?

    /// Re-reads the liked state so the lock-screen heart is filled correctly.
    func refreshRemoteLike() {
        guard let track = current else { return }
        MPRemoteCommandCenter.shared().likeCommand.isActive = isLikedProvider?(track) ?? false
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        refreshRemoteLike()
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
