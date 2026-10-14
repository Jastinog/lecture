import SwiftUI
import MediaPlayer

/// A small animated equalizer — the universal "sound is playing right now" cue.
/// The bars oscillate while `isPlaying`; when paused they settle to a short, even
/// resting height so the control still reads as an audio marker. The perpetual
/// motion comes from a single `repeatForever(autoreverses:)` animation, so there's
/// no timer: one state flip drives the oscillation forever, and flipping it back
/// stops it. Bars use distinct durations so they fall out of sync like a real meter.
struct EqualizerBars: View {
    var isPlaying: Bool
    var color: Color = Palette.accent

    private let specs: [(min: CGFloat, max: CGFloat, duration: Double)] = [
        (0.30, 0.85, 0.52), (0.55, 1.00, 0.70), (0.25, 0.70, 0.44), (0.45, 0.95, 0.62),
    ]
    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(specs.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: height * (animating ? specs[i].max : specs[i].min))
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: specs[i].duration).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.25),
                        value: animating)
            }
        }
        .frame(width: 16, height: height)
        // `animating` mirrors `isPlaying`; the change is what the per-bar animations
        // above key on, so toggling it starts (repeatForever) or stops the meter.
        .onChange(of: isPlaying, initial: true) { _, playing in animating = playing }
    }

    private let height: CGFloat = 15
}

/// One of the iOS 6 Music player's transport glyphs (play, pause, previous,
/// next), white and engraved into the black chrome.
struct TransportGlyph: View {
    let name: String
    let height: CGFloat

    var body: some View {
        Image.classic(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .shadow(color: .black, radius: 0, x: 0, y: -1)
    }
}

/// Destinations pushed inside the Now Playing screen. Chapters and the sleep timer
/// are full screens of their own (with a back button), never sheets or menus.
enum PlayerRoute: Hashable {
    case sleepTimer, speed
    case editBookmark(UUID)
}

/// One of the screens Now Playing pushes. `done` returns to the player; `push`
/// opens a further player screen (a bookmark's editor).
struct PlayerRouteView: View {
    let route: PlayerRoute
    let done: () -> Void
    let push: (PlayerRoute) -> Void
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        // Re-inject the player into pushed screens: on iOS 26 an environment
        // object set on a stack doesn't reach its `navigationDestination` views
        // (see `LibraryDestinations`).
        Group {
            switch route {
            case .sleepTimer: SleepTimerView(onDone: done)
            case .speed: SpeedView(onDone: done)
            case .editBookmark(let id): BookmarkEditView(id: id)
            }
        }
        .environmentObject(player)
        .classicBackButton()
    }
}

/// The Now Playing screen, built like the iOS 6 Music player: a black glossy bar,
/// a dark strip with the chrome scrubber, the artwork on linen, a reel-to-reel
/// tape deck whose spools trade tape as the topic plays, and silver controls on
/// black.
///
/// It's pushed onto the tab's stack like any page, with an arrow back button in
/// the black bar; the list button flips the artwork over to the chapters and
/// bookmarks, as Music flipped the album to its lectures.
struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayer
    let onClose: () -> Void

    /// Brief "saved" confirmation after adding a bookmark.
    @State private var bookmarkAdded = false
    /// The artwork turned over to the chapter list.
    @State private var showingChapters = false
    /// The previous screen's title, for the back button.
    @State private var backTitle = String(localized: "Back")
    @EnvironmentObject private var router: NavRouter
    /// The stack depth the player sits at; popping below it brings the tab bar back.
    @State private var depth = 0

    var body: some View {
        main
            .toolbar(.hidden, for: .navigationBar)
            // The bar is hidden; this names the back button of the screens it pushes.
            .navigationTitle("Player")
            .background(PreviousTitleReader { backTitle = $0.isEmpty ? String(localized: "Back") : $0 })
            .onChange(of: player.topic?.id) { showingChapters = false }
            .onAppear {
                depth = router.path.count
                TabBarVisibility.shared.set(hidden: true)
            }
            .onChange(of: router.path.count) { _, count in
                if count < depth { TabBarVisibility.shared.set(hidden: false) }
            }
            .onDisappear {
                if router.path.count < depth { TabBarVisibility.shared.set(hidden: false) }
            }
    }

    private var main: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                PlayerScrubber(clock: player.clock, chapterKey: chapterKey,
                               chapterLine: chapterLine, seek: player.seek)
                artwork
                TapeDeck(clock: player.clock, rate: player.rate, isPlaying: player.isPlaying,
                         label: String(localized: "Lecture \(player.currentIndex + 1)"), seek: player.seek,
                         step: player.skip(forward:))
                    .frame(height: min(160, max(110, geo.size.height * 0.19)))
                controls
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// Identifies the playing chapter, so the scrubber drops a half-finished drag
    /// when the chapter changes under it.
    private var chapterKey: String { "\(player.topic?.id ?? 0)-\(player.currentIndex)" }

    /// "7 of 32" under the chapter title.
    private var chapterLine: String {
        let count = player.topic?.lectures.count ?? 0
        let title = player.currentLecture?.displayTitle(at: player.currentIndex) ?? ""
        return count > 1 ? "\(title)\n\(String(localized: "\(player.currentIndex + 1) of \(count)"))" : title
    }

    // MARK: Header

    /// The black glossy bar: back on the left, chapters on the right, and author /
    /// title / status centred on the screen whatever the buttons' widths.
    private var header: some View {
        HStack {
            BackBarButton(title: backTitle, black: true, action: onClose)
                .frame(maxWidth: Self.barSide, alignment: .leading)
            Spacer(minLength: 0)
            // Enabled even for a one-chapter topic: the back also holds its bookmarks.
            chaptersButton
                .disabled(player.topic == nil)
                .accessibilityLabel(showingChapters ? "Artwork" : "Lectures and Bookmarks")
        }
        .overlay {
            VStack(spacing: 0) {
                Text(player.topic?.lecturer ?? "")
                    .font(.helvetica(12, weight: .bold))
                    .foregroundStyle(Palette.rgb(0xB4B4B4))
                Text(player.topic?.title ?? "")
                    .font(.helvetica(12, weight: .bold))
                    .engraved()
                HStack(spacing: 5) {
                    if player.isBuffering {
                        ClassicSpinner(style: .white).scaleEffect(0.7).frame(width: 14, height: 14)
                    } else if player.isPlaying {
                        EqualizerBars(isPlaying: true, color: Palette.rgb(0xB4B4B4))
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 11)
                    }
                    Text(statusText)
                        .contentTransition(.identity)
                }
                .font(.helvetica(12, weight: .bold))
                .foregroundStyle(Palette.rgb(0xB4B4B4))
            }
            .lineLimit(1)
            .padding(.horizontal, Self.barSide + 8)
        }
        .padding(.horizontal, BarMetrics.edgeInset)
        .frame(height: 44)
        .background { Image.classic("BlackBar").resizable() }
    }

    /// Room kept for the bar's buttons either side of the centred title.
    private static let barSide: CGFloat = 92

    /// The list button. It turns the artwork over to the chapters and, while
    /// they show, wears a thumbnail of the cover to turn it back — as Music's did.
    @ViewBuilder private var chaptersButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.75)) { showingChapters.toggle() }
        } label: {
            if showingChapters {
                CoverImage(url: player.topic?.coverURL, width: 21, corner: 1)
                    .frame(height: 26)
                    .clipped()
            } else {
                Image.classic("ShowChapters")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 16)
            }
        }
        // Music's list glyph comes with its own engraving.
        .buttonStyle(ClassicBarButtonStyle(skin: .black, engraved: false))
    }

    private var statusText: String {
        if player.isBuffering { return String(localized: "Loading…") }
        return player.isPlaying ? String(localized: "Now Playing") : String(localized: "Paused")
    }

    // MARK: Artwork

    /// The cover as a real topic lying on dark linen. Takes whatever height is left.
    private var artwork: some View {
        Group {
            FlipView(angle: showingChapters ? 180 : 0) {
                cover
            } back: {
                PlayerListSide(push: { router.push($0) }) {
                    withAnimation(.easeInOut(duration: 0.75)) { showingChapters = false }
                }
            }
        }
        .frame(minHeight: 120)
    }

    /// The cover lying on linen.
    private var cover: some View {
        GeometryReader { geo in
            let width = max(60, min((geo.size.height - 36) * CoverAspect.ratio, geo.size.width - 80))
            CoverImage(url: player.topic?.coverURL, width: width, corner: 0, hiRes: true)
                .bookCover()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LinenBackground())
        .clipped()
    }

    // MARK: Controls

    /// Transport, volume and the speed / bookmark / timer row on black chrome.
    private var controls: some View {
        VStack(spacing: 12) {
            transport
            ClassicVolumeSlider()
                .frame(height: 30)
                .padding(.horizontal, 6)
            toolsRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [.init(color: Palette.rgb(0x3A3A3A), location: 0),
                                   .init(color: Palette.rgb(0x1C1C1C), location: 0.12),
                                   .init(color: Palette.rgb(0x0D0D0D), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle().fill(.black).frame(height: 1)
                        Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var transport: some View {
        HStack {
            skipButton(forward: false)
            Spacer(minLength: 0)
            glyphButton("TransportPrev", height: 23, label: String(localized: "Previous Lecture"), action: player.previous)
            Spacer(minLength: 0)
            glyphButton(player.isPlaying ? "TransportPause" : "TransportPlay", height: 27,
                        label: player.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                        action: player.togglePlayPause)
            Spacer(minLength: 0)
            glyphButton("TransportNext", height: 23, label: String(localized: "Next Lecture"), action: player.next)
                .disabled(player.currentIndex + 1 >= (player.topic?.lectures.count ?? 0))
            Spacer(minLength: 0)
            skipButton(forward: true)
        }
        .padding(.horizontal, 4)
    }

    /// The Music player's own "back 30 seconds" key — white, like the transport
    /// glyphs beside it — and its mirror for forward, the "30" kept reading true.
    private func skipButton(forward: Bool) -> some View {
        Button { player.skip(forward: forward) } label: {
            Image.classic(forward ? "SkipForward" : "SkipBack")
                .shadow(color: .black, radius: 0, x: 0, y: -1)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressGlowStyle())
        .accessibilityLabel(player.skipLabel(forward: forward))
    }

    /// A transport key drawn with the Music player's own glyph.
    private func glyphButton(_ name: String, height: CGFloat, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportGlyph(name: name, height: height)
                .frame(width: 64, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressGlowStyle())
        .accessibilityLabel(label)
    }

    /// Add a bookmark, the speed (−/value/+) and the sleep timer: three black
    /// keys of one width, in words.
    private var toolsRow: some View {
        HStack(spacing: 8) {
            Button(action: addBookmark) {
                Text(bookmarkAdded ? "Saved" : "Bookmark")
                    .contentTransition(.identity)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.classicBlackBar)
            .disabled(player.topic == nil)

            speedControl

            NavigationLink(value: PlayerRoute.sleepTimer) {
                SleepTimerLabel(clock: player.clock, mode: player.sleepMode)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.classicBlackBar)
        }
    }

    /// Fine speed control: −/+ in 0.05 steps around the current speed; the value
    /// itself opens the speed screen (presets, reset to default). Drawn as a black
    /// three-segment control. Blue when the topic keeps a speed of its own.
    private var speedControl: some View {
        HStack(spacing: 0) {
            Button { player.stepRate(-1) } label: {
                Text("−").frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .disabled(player.rate <= RateTopic.range.lowerBound)
            .accessibilityLabel("Slower")

            NavigationLink(value: PlayerRoute.speed) {
                Text(AudioPlayer.rateLabel(player.rate))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(player.hasTopicRate ? Palette.rgb(0x8CC8FF) : .white)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .overlay(alignment: .leading) { Rectangle().fill(.black.opacity(0.6)).frame(width: 1) }
                    .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.6)).frame(width: 1) }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Speed \(AudioPlayer.rateLabel(player.rate))")
            .accessibilityHint(player.hasTopicRate ? "This topic’s own speed" : "")

            Button { player.stepRate(1) } label: {
                Text("+").frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .disabled(player.rate >= RateTopic.range.upperBound)
            .accessibilityLabel("Faster")
        }
        .buttonStyle(.plain)
        .font(.helvetica(13, weight: .bold))
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 0, x: 0, y: -1)
        .frame(maxWidth: .infinity)
        .background { BarButtonSkin.black.bezel() }
        .animation(.snappy, value: player.rate)
    }

    private func addBookmark() {
        guard let topic = player.topic else { return }
        BookmarkStore.shared.add(Bookmark(
            topicID: topic.id, index: player.currentIndex, time: player.clock.currentTime,
            chapterTitle: player.currentLecture?.displayTitle(at: player.currentIndex) ?? "",
            lectureID: player.currentLecture?.id))
        bookmarkAdded = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            bookmarkAdded = false
        }
    }
}

/// A borderless glyph button that glows white under the finger, as iOS 6's
/// transport keys did (`showsTouchWhenHighlighted`).
private struct PressGlowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    Image.classic("PressedGlow")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : 0.35)
            // iOS 6 keys changed outright: no animated release, and a glyph that
            // changes under the finger (play ↔ pause) swaps in a single frame.
            .transaction { $0.animation = nil }
    }
}

/// Playback scrubber in the dark strip under the bar: elapsed time, the chrome
/// slider, remaining time and the chapter line. Observes only the `PlaybackClock`,
/// so the twice-a-second position tick redraws just this strip, not the player.
/// Holds its own scrubbing state so dragging the knob doesn't fight the live time.
private struct PlayerScrubber: View {
    @ObservedObject var clock: PlaybackClock
    let chapterKey: String
    let chapterLine: String
    let seek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    /// Right-hand label shows the chapter's time left instead of its length.
    /// Tapping the label flips it; the choice is remembered.
    @AppStorage("lecture.showRemaining") private var showRemaining = true

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(formatTime(position))
                    .frame(width: 54, alignment: .leading)
                ChromeSlider(
                    value: position,
                    range: 0...max(clock.duration, 1),
                    style: .nowPlaying,
                    onChange: { scrubTime = $0 },
                    onEditingChanged: { editing in
                        if editing {
                            scrubTime = clock.currentTime
                            isScrubbing = true
                        } else {
                            // A chapter change mid-drag ended the scrub; don't
                            // carry its position into the new chapter.
                            if isScrubbing { seek(scrubTime) }
                            isScrubbing = false
                        }
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Position in Lecture")
                    .accessibilityValue(formatTime(position))
                    .accessibilityAdjustableAction { direction in
                        let step: Double = direction == .increment ? 15 : -15
                        seek(min(max(clock.currentTime + step, 0), clock.duration))
                    }
                Button { showRemaining.toggle() } label: {
                    Text(showRemaining
                         ? "−\(formatTime(max(clock.duration - position, 0)))"
                         : formatTime(clock.duration))
                        .frame(width: 54, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Switches between the lecture’s length and the time left")
            }
            .font(.helvetica(12, weight: .bold).monospacedDigit())
            .engraved()

            Text(chapterLine)
                .font(.helvetica(12, weight: .bold))
                .foregroundStyle(Palette.rgb(0xC8C8C8))
                .shadow(color: .black, radius: 0, x: 0, y: -1)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [Palette.rgb(0x3C3C3C), Palette.rgb(0x1E1E1E)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 1) }
        }
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
        .zIndex(1)
        // A drag in progress belongs to the chapter it started on.
        .onChange(of: chapterKey) { isScrubbing = false }
    }

    private var position: Double { isScrubbing ? scrubTime : clock.currentTime }
}

/// The reel-to-reel deck on brushed aluminium, after Podcasts' tape deck. The
/// tape is the playing lecture alone: the left reel holds what's left of it and
/// the right one what's been heard, so tape visibly moves across as it plays;
/// both reels turn while playing. A paper label names the lecture and the plate
/// above says how long it has left.
private struct TapeDeck: View {
    @ObservedObject var clock: PlaybackClock
    let rate: Float
    let isPlaying: Bool
    let label: String
    /// Moves playback to a time in the lecture.
    let seek: (Double) -> Void
    /// Moves playback by the user's skip step, forward or back.
    let step: (Bool) -> Void

    /// The reels' turn so far, advanced frame by frame.
    @State private var spin = ReelSpin()
    /// While a reel is turned by hand: the finger's last angle about that
    /// reel's centre, and the seconds wound so far.
    @State private var winding: (grip: Double, wound: Double)?
    @State private var ticker = UISelectionFeedbackGenerator()

    /// Seconds of the lecture one full turn of a reel winds by hand.
    private static let secondsPerTurn = 60.0

    var body: some View {
        GeometryReader { geo in
            let layout = DeckLayout(size: geo.size)
            let p = progress
            let rl = layout.reel.pack(fill: 1 - p), rr = layout.reel.pack(fill: p)
            ZStack {
                // Layers, each redrawn only as often as it changes: the fixtures,
                // heads and cover never (the heads only slide), the tape and its
                // packs as the lecture advances, and the reels every frame while playing.
                DeckLayer(part: .fixtures, size: geo.size).equatable()
                // The three heads rest on the tape while it plays and draw back
                // under their cover when it stops — and while a reel is wound by
                // hand, as decks lift the tape off the heads to spool. They move
                // quickly at first and settle gently.
                DeckLayer(part: .heads, size: geo.size).equatable()
                    .offset(y: isPlaying && winding == nil ? 0 : -DeckLayout.headLift)
                    .animation(.easeOut(duration: 0.45), value: isPlaying && winding == nil)
                DeckLayer(part: .cover, size: geo.size).equatable()
                Canvas { gc, _ in
                    DeckArt.tape(gc, layout, rl: rl, rr: rr)
                    // The packs don't turn to the eye, so they sit here under the
                    // flanges, whose windows show them.
                    let art = ReelArt.shared(for: layout.reel)
                    DeckArt.pack(gc, at: layout.left, art, radius: rl)
                    DeckArt.pack(gc, at: layout.right, art, radius: rr)
                }
                TimelineView(.animation(paused: !isPlaying && winding == nil)) { context in
                    let (al, ar) = spin.advance(to: context.date, rl: rl, rr: rr, rate: rate,
                                                holding: winding != nil)
                    let art = ReelArt.shared(for: layout.reel)
                    Canvas(rendersAsynchronously: true) { gc, _ in
                        DeckArt.reel(gc, at: layout.left, art, angle: al)
                        DeckArt.reel(gc, at: layout.right, art, angle: ar)
                    }
                }
            }
            .overlay {
                // The reels can be turned by hand, like a record: anticlockwise
                // winds on, clockwise back.
                ForEach([true, false], id: \.self) { isLeft in
                    Circle()
                        .fill(.clear)
                        .contentShape(Circle())
                        .frame(width: layout.reel.r * 2, height: layout.reel.r * 2)
                        // Before `position`, so the finger is read about the reel's centre.
                        .gesture(windGesture(radius: layout.reel.r, mine: isLeft ? rl : rr,
                                             other: isLeft ? rr : rl, isLeft: isLeft))
                        .position(isLeft ? layout.left : layout.right)
                }
            }
            .overlay {
                // A typed paper label stuck to the plate, ruled in red; while a
                // reel is wound, it reads how far.
                Text(winding.map { Self.windLabel($0.wound) } ?? label)
                    .monospacedDigit()
                    .font(.custom("AmericanTypewriter", fixedSize: 14))
                    .foregroundStyle(Palette.rgb(0x26324F))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                    .frame(width: max(40, layout.spread * 2 - layout.reel.r * 2 - 14), height: 26)
                    .background(alignment: .bottom) {
                        Rectangle().fill(Palette.rgb(0xC8463E).opacity(0.55)).frame(height: 0.75)
                            .padding(.horizontal, 4).padding(.bottom, 5)
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(LinearGradient(colors: [Palette.rgb(0xFCF9EF), Palette.rgb(0xEFE6CF)],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay { RoundedRectangle(cornerRadius: 1.5).strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    .position(x: layout.midX, y: layout.left.y - 4)
            }
        }
        .background(BrushedMetalBackground())
        .overlay(alignment: .top) {
            LectureLeftLabel(clock: clock, rate: rate)
                .padding(.top, 7)
        }
        .overlay(alignment: .top) { Rectangle().fill(.white).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rgb(0x6A6A6A)).frame(height: 1) }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("\(formatPercent(progress)) of the lecture played")
        .accessibilityHint("Turn a reel to wind back or on.")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment)
        }
    }

    /// Turning a reel by hand. The reel follows the finger round its centre and
    /// the other reel takes up the same length of tape; each turn winds
    /// `secondsPerTurn`, ticking every five seconds, and letting go moves
    /// playback by what was wound, within the lecture.
    private func windGesture(radius: Double, mine: Double, other: Double, isLeft: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = atan2(value.location.y - radius, value.location.x - radius)
                guard let (last, before) = winding else {
                    winding = (a, 0)
                    ticker.prepare()
                    return
                }
                // The shortest way round from the last angle.
                var turn = a - last
                if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
                // Same tape off one reel as onto the other.
                let carried = turn * mine / other
                spin.turn(left: isLeft ? turn : carried, right: isLeft ? carried : turn)
                // Anticlockwise (a negative turn) winds on.
                let now = before - turn / (2 * .pi) * Self.secondsPerTurn
                if Int((now / 5).rounded(.down)) != Int((before / 5).rounded(.down)) { ticker.selectionChanged() }
                winding = (a, now)
            }
            .onEnded { _ in
                if let wound = winding?.wound, abs(wound) >= 1 {
                    seek(min(max(clock.currentTime + wound, 0), clock.duration))
                }
                winding = nil
            }
    }

    /// "+1:20" / "−0:45".
    private static func windLabel(_ seconds: Double) -> String {
        (seconds < 0 ? "−" : "+") + formatTime(abs(seconds))
    }

    /// How much of the lecture has played.
    private var progress: Double { clock.fraction }
}

/// The reels' angles, integrated from the tape's speed: each frame turns a reel
/// by the tape that passed over it, so the fuller reel turns slower and nothing
/// jumps when a pack's size changes. A pause leaves the angles where they were.
@MainActor
private final class ReelSpin {
    private var left = 0.0, right = 0.0
    private var last: Date?
    /// Tape speed on the plate, in points a second at 1×.
    private let speed = 30.0

    /// `holding`: a hand is on a reel, so the motor lets go and only the hand turns them.
    func advance(to now: Date, rl: Double, rr: Double, rate: Float, holding: Bool) -> (Double, Double) {
        if let last {
            let dt = now.timeIntervalSince(last)
            // Frames resume after a pause or a trip off screen: carry on from
            // where the reels stopped rather than leaping.
            if dt > 0, dt < 0.25, !holding {
                let run = speed * Double(rate) * dt
                // Tape runs along the bottom, left to right: both reels turn anticlockwise.
                left = (left - run / rl).truncatingRemainder(dividingBy: 2 * .pi)
                right = (right - run / rr).truncatingRemainder(dividingBy: 2 * .pi)
            }
        }
        last = now
        return (left, right)
    }

    /// Turns the reels by hand.
    func turn(left dl: Double, right dr: Double) {
        left = (left + dl).truncatingRemainder(dividingBy: 2 * .pi)
        right = (right + dr).truncatingRemainder(dividingBy: 2 * .pi)
    }
}

/// One of the deck's still layers, drawn once for a size: the plate's fixed
/// parts (the reels' shadows, the guides and the corner screws), the erase,
/// record and play heads (which slide as one under the cover), or the head
/// block's cover with its badge and screws.
private struct DeckLayer: View, Equatable {
    enum Part { case fixtures, heads, cover }
    let part: Part
    let size: CGSize

    var body: some View {
        Canvas { gc, _ in
            let d = DeckLayout(size: size)
            switch part {
            case .fixtures: DeckArt.fixtures(gc, d)
            case .heads: DeckArt.heads(gc, d)
            case .cover: DeckArt.headCover(gc, d)
            }
        }
    }
}

/// Everything drawn on the deck, as plain functions of a graphics context.
private enum DeckArt {

    // MARK: Fixtures

    static func fixtures(_ gc: GraphicsContext, _ d: DeckLayout) {
        for c in [d.left, d.right] {
            // The reel's shadow on the plate: a soft one far below and a tight
            // contact one. Both flanges' windows line up, so through them shows
            // the plate itself, in the reel's shade.
            var ambient = gc
            ambient.addFilter(.shadow(color: .black.opacity(0.3), radius: d.reel.r * 0.14, x: 0, y: d.reel.r * 0.1))
            ambient.fill(circle(c, d.reel.r - 1), with: .color(.black.opacity(0.01)))
            var shade = gc
            shade.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1.5))
            shade.fill(circle(c, d.reel.r), with: .radialGradient(
                Gradient(colors: [.black.opacity(0.5), .black.opacity(0.3)]),
                center: c, startRadius: d.reel.core, endRadius: d.reel.r))
        }
        for g in d.guides { roller(gc, at: g, radius: d.guideRadius) }
        let inset = 11.0
        for (i, p) in [CGPoint(x: inset, y: inset), CGPoint(x: d.size.width - inset, y: inset),
                       CGPoint(x: inset, y: d.size.height - inset),
                       CGPoint(x: d.size.width - inset, y: d.size.height - inset)].enumerated() {
            screw(gc, at: p, radius: 4, slot: [0.35, 1.1, 0.8, 0.15][i])
        }
    }

    /// A chrome guide roller seen from above, with its pin.
    private static func roller(_ gc: GraphicsContext, at g: CGPoint, radius r: Double) {
        var s = gc
        s.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1.5))
        s.fill(circle(g, r), with: .radialGradient(
            Gradient(colors: [.white, Palette.rgb(0xC4C6C9), Palette.rgb(0x7E8084)]),
            center: CGPoint(x: g.x - r * 0.35, y: g.y - r * 0.45), startRadius: 0, endRadius: r * 1.5))
        gc.fill(circle(g, r), with: .conicGradient(Gradient(colors: [
            .clear, .white.opacity(0.6), .clear, .black.opacity(0.15), .clear, .white.opacity(0.4), .clear
        ]), center: g, angle: .degrees(-60)))
        gc.stroke(circle(g, r - 0.4), with: .color(Palette.rgb(0x55575A)), lineWidth: 0.8)
        gc.stroke(circle(g, r * 0.62), with: .color(.white.opacity(0.7)), lineWidth: 0.6)
        gc.stroke(circle(g, r * 0.62 + 0.6), with: .color(.black.opacity(0.18)), lineWidth: 0.5)
        gc.fill(circle(g, r * 0.32), with: .radialGradient(
            Gradient(colors: [Palette.rgb(0x8A8C8F), Palette.rgb(0x2E3033)]),
            center: CGPoint(x: g.x - r * 0.1, y: g.y - r * 0.12), startRadius: 0, endRadius: r * 0.4))
    }

    /// The erase, record and play heads under the cover's lip, each with its gap.
    static func heads(_ gc: GraphicsContext, _ d: DeckLayout) {
        for x in [d.midX - 14, d.midX, d.midX + 14] {
            // Tall enough to stay under the cover's lip when drawn back.
            let face = CGRect(x: x - 4.5, y: d.tapeTop - 9, width: 9, height: 9)
            var s = gc
            s.addFilter(.shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1))
            s.fill(Path(roundedRect: face, cornerRadius: 1.5), with: .linearGradient(
                Gradient(colors: [Palette.rgb(0x9C9EA1), .white, Palette.rgb(0xA6A8AB), Palette.rgb(0x707275)]),
                startPoint: CGPoint(x: face.minX, y: 0), endPoint: CGPoint(x: face.maxX, y: 0)))
            gc.stroke(Path(roundedRect: face, cornerRadius: 1.5), with: .color(Palette.rgb(0x46484B)), lineWidth: 0.5)
            var gap = Path()
            gap.move(to: CGPoint(x: x, y: face.minY + 1))
            gap.addLine(to: CGPoint(x: x, y: face.maxY))
            gc.stroke(gap, with: .color(.black.opacity(0.65)), lineWidth: 0.4)
        }
    }

    /// The head block's dark brushed cover with the maker's badge and two screws.
    static func headCover(_ gc: GraphicsContext, _ d: DeckLayout) {
        let mid = d.midX
        let cover = CGRect(x: mid - 26, y: d.tapeTop - 27, width: 52, height: 22)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 2,
                                           bottomTrailingRadius: 2, topTrailingRadius: 8).path(in: cover)
        var s = gc
        s.addFilter(.shadow(color: .black.opacity(0.5), radius: 2.5, x: 0, y: 2.5))
        s.fill(shape, with: .linearGradient(Gradient(colors: [Palette.rgb(0x6A6C70), Palette.rgb(0x3A3C40),
                                                              Palette.rgb(0x232528)]),
                                            startPoint: CGPoint(x: 0, y: cover.minY),
                                            endPoint: CGPoint(x: 0, y: cover.maxY)))
        var brushed = gc
        brushed.clip(to: shape)
        brushed.blendMode = .overlay
        brushed.opacity = 0.6
        brushed.draw(Image(uiImage: Texture.brushed), in: cover)
        gc.stroke(shape.applying(CGAffineTransform(translationX: 0, y: 0.5)),
                  with: .linearGradient(Gradient(colors: [.white.opacity(0.5), .clear, .black.opacity(0.5)]),
                                        startPoint: CGPoint(x: 0, y: cover.minY),
                                        endPoint: CGPoint(x: 0, y: cover.maxY)), lineWidth: 0.8)

        // The badge: a chrome plate with the name stamped in.
        let badge = CGRect(x: mid - 11, y: cover.minY + 6, width: 22, height: 8)
        gc.fill(Path(roundedRect: badge, cornerRadius: 2), with: .linearGradient(
            Gradient(colors: [.white, Palette.rgb(0xBCBEC1), Palette.rgb(0x8E9093)]),
            startPoint: CGPoint(x: 0, y: badge.minY), endPoint: CGPoint(x: 0, y: badge.maxY)))
        gc.stroke(Path(roundedRect: badge, cornerRadius: 2), with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        let name = { (color: Color) in Text("LECTURE").font(.helvetica(5.5, weight: .bold)).kerning(1).foregroundStyle(color) }
        gc.draw(name(.white.opacity(0.8)), at: CGPoint(x: badge.midX, y: badge.midY + 0.5))
        gc.draw(name(Palette.rgb(0x3A3C3F)), at: CGPoint(x: badge.midX, y: badge.midY))

        for x in [cover.minX + 6.5, cover.maxX - 6.5] {
            screw(gc, at: CGPoint(x: x, y: cover.midY + 2), radius: 2.4, slot: x < mid ? 0.5 : 1.2)
        }
    }

    /// A countersunk Phillips screw.
    private static func screw(_ gc: GraphicsContext, at p: CGPoint, radius r: Double, slot: Double) {
        gc.fill(circle(p, r + 0.6), with: .linearGradient(
            Gradient(colors: [.black.opacity(0.35), .white.opacity(0.8)]),
            startPoint: CGPoint(x: p.x, y: p.y - r), endPoint: CGPoint(x: p.x, y: p.y + r)))
        gc.fill(circle(p, r), with: .radialGradient(
            Gradient(colors: [.white, Palette.rgb(0xB0B2B5), Palette.rgb(0x77797C)]),
            center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.4), startRadius: 0, endRadius: r * 1.4))
        for k in 0..<2 {
            let a = slot + Double(k) * .pi / 2
            var cross = Path()
            cross.move(to: CGPoint(x: p.x - cos(a) * r * 0.62, y: p.y - sin(a) * r * 0.62))
            cross.addLine(to: CGPoint(x: p.x + cos(a) * r * 0.62, y: p.y + sin(a) * r * 0.62))
            gc.stroke(cross, with: .color(Palette.rgb(0x3A3C3F)), lineWidth: max(0.6, r * 0.24))
        }
    }

    // MARK: Tape

    /// The tape, seen edge on as it stands between the flanges: a hairline of
    /// oxide that leaves each pack on its tangent, wraps under the guides and
    /// runs straight beneath the heads.
    static func tape(_ gc: GraphicsContext, _ d: DeckLayout, rl: Double, rr: Double) {
        let gr = d.guideRadius + d.tapeWidth / 2
        let (g1, g2) = (d.guides[0], d.guides[1])
        let (a1, b1) = lowerTangent(d.left, rl, g1, gr)
        let (a2, b2) = lowerTangent(d.right, rr, g2, gr)
        var tape = Path()
        tape.move(to: a1)
        tape.addLine(to: b1)
        arc(&tape, around: g1, radius: gr, from: angle(of: b1, around: g1), to: .pi / 2)
        arc(&tape, around: g2, radius: gr, from: .pi / 2, to: angle(of: b2, around: g2))
        tape.addLine(to: a2)

        gc.stroke(tape, with: .color(Palette.rgb(0x4A3020)),
                  style: StrokeStyle(lineWidth: d.tapeWidth, lineCap: .butt, lineJoin: .round))
    }

    /// The external tangent below two circles: the points on the first and second.
    private static func lowerTangent(_ c1: CGPoint, _ r1: Double, _ c2: CGPoint, _ r2: Double) -> (CGPoint, CGPoint) {
        let dx = c2.x - c1.x, dy = c2.y - c1.y
        let dist = max(hypot(dx, dy), abs(r1 - r2) + 0.001)
        let theta = atan2(dy, dx), phi = acos((r1 - r2) / dist)
        let options = [theta + phi, theta - phi].map { a in
            (CGPoint(x: c1.x + cos(a) * r1, y: c1.y + sin(a) * r1),
             CGPoint(x: c2.x + cos(a) * r2, y: c2.y + sin(a) * r2))
        }
        return options.max { $0.0.y + $0.1.y < $1.0.y + $1.1.y }!
    }

    private static func angle(of p: CGPoint, around c: CGPoint) -> Double { atan2(p.y - c.y, p.x - c.x) }

    /// Continues `path` with a line to the arc's start, then the arc the short
    /// way from `a0` to `a1`.
    private static func arc(_ path: inout Path, around c: CGPoint, radius r: Double, from a0: Double, to a1: Double) {
        path.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: a1 < a0)
    }

    // MARK: Reel

    /// The wound tape on a reel, from the full pack's art cut to `radius`. Its
    /// rings are a pixel each, so the art lands on whole pixels.
    static func pack(_ gc: GraphicsContext, at c: CGPoint, _ art: ReelArt, radius: Double) {
        let full = art.geometry.full, s = art.scale
        var tape = gc
        tape.clip(to: circle(c, radius))
        let corner = CGPoint(x: ((c.x - full) * s).rounded() / s, y: ((c.y - full) * s).rounded() / s)
        tape.draw(art.pack, in: CGRect(origin: corner, size: CGSize(width: full * 2, height: full * 2)))
        gc.stroke(circle(c, radius - 0.5), with: .color(.black.opacity(0.6)), lineWidth: 1)
        gc.stroke(circle(c, radius - 1.5), with: .color(Palette.rgb(0x8A6646).opacity(0.45)), lineWidth: 0.6)
    }

    /// A reel at `angle`, over its pack: the flange with its windows, then what
    /// turns with the reel — the windows' edges, the footage scale, the rivets,
    /// the drive holes and the centre lock. The metal's light (in `art`) stays put.
    static func reel(_ gc: GraphicsContext, at c: CGPoint, _ art: ReelArt, angle: Double) {
        let g = art.geometry
        let turn = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)

        // The flange, with the windows cut out of it.
        let windows = art.windows.applying(turn)
        var holes = circle(c, g.r)
        holes.addPath(windows)
        var flange = gc
        flange.clip(to: holes, style: FillStyle(eoFill: true))
        flange.draw(art.flange, in: square(c, g.r))

        // The flange's upper edges throw a shadow into the windows, onto the tape;
        // the cut edges are lit where they face up and dark where they face down.
        var inside = gc
        inside.clip(to: windows)
        inside.stroke(windows.applying(CGAffineTransform(translationX: 0, y: 1.6)),
                      with: .color(.black.opacity(0.5)), lineWidth: 2.6)
        for k in 0..<3 {
            let w = art.window.applying(CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: angle + Double(k) * 2 * .pi / 3))
            let box = w.boundingRect
            gc.stroke(w, with: .linearGradient(Gradient(colors: [.black.opacity(0.55), .white.opacity(0.85)]),
                                               startPoint: CGPoint(x: box.midX, y: box.minY),
                                               endPoint: CGPoint(x: box.midX, y: box.maxY)), lineWidth: 1)
        }

        let ticks = art.ticks.applying(turn)
        gc.stroke(ticks.applying(CGAffineTransform(translationX: 0, y: 0.5)), with: .color(.white.opacity(0.6)), lineWidth: 0.5)
        gc.stroke(ticks, with: .color(.black.opacity(0.4)), lineWidth: 0.5)

        for k in 0..<3 {
            let a = angle + Double(k) * 2 * .pi / 3 + .pi / 3
            let p = CGPoint(x: c.x + cos(a) * g.rivetOrbit, y: c.y + sin(a) * g.rivetOrbit)
            gc.fill(circle(p, g.rivet + 0.5), with: .color(.black.opacity(0.25)))
            gc.fill(circle(p, g.rivet), with: .radialGradient(
                Gradient(colors: [.white, Palette.rgb(0x9C9EA1)]),
                center: CGPoint(x: p.x - g.rivet * 0.35, y: p.y - g.rivet * 0.45),
                startRadius: 0, endRadius: g.rivet * 1.4))

            // A drive hole in the hub plate, between the lock's lobes.
            let h = CGPoint(x: c.x + cos(a) * g.core * 0.74, y: c.y + sin(a) * g.core * 0.74)
            gc.fill(circle(h, g.core * 0.1), with: .color(Palette.rgb(0x2A2C2E)))
            gc.stroke(circle(h, g.core * 0.1).applying(CGAffineTransform(translationX: 0, y: 0.4)),
                      with: .color(.white.opacity(0.6)), lineWidth: 0.4)
        }

        // The NAB centre lock: a three-lobed chrome knob, knurled round its lobes,
        // with a domed button.
        let knob = art.knob.applying(turn)
        let h = g.core
        gc.fill(knob.applying(CGAffineTransform(translationX: 0, y: 1.2)), with: .color(.black.opacity(0.3)))
        gc.fill(knob, with: .radialGradient(
            Gradient(colors: [.white, Palette.rgb(0xC6C8CB), Palette.rgb(0x7C7E81)]),
            center: CGPoint(x: c.x - h * 0.2, y: c.y - h * 0.3), startRadius: 0, endRadius: h * 0.9))
        gc.fill(knob, with: .conicGradient(Gradient(colors: [
            .clear, .white.opacity(0.5), .clear, .black.opacity(0.18), .clear, .white.opacity(0.35), .clear,
            .black.opacity(0.18), .clear
        ]), center: c, angle: .degrees(-60)))
        gc.stroke(art.knurl.applying(turn), with: .color(.black.opacity(0.35)), lineWidth: 0.4)
        gc.stroke(knob, with: .color(Palette.rgb(0x46484B)), lineWidth: 0.6)

        let cap = h * 0.22
        gc.fill(circle(c, cap), with: .radialGradient(
            Gradient(colors: [.white, Palette.rgb(0xB4B6B9), Palette.rgb(0x6E7073)]),
            center: CGPoint(x: c.x - cap * 0.35, y: c.y - cap * 0.45), startRadius: 0, endRadius: cap * 1.4))
        gc.stroke(circle(c, cap), with: .linearGradient(Gradient(colors: [.black.opacity(0.4), .white.opacity(0.8)]),
                                                         startPoint: CGPoint(x: c.x, y: c.y - cap),
                                                         endPoint: CGPoint(x: c.x, y: c.y + cap)), lineWidth: 0.6)
    }

    /// The flange's metal as the light falls on it, which doesn't turn with the
    /// reel: spun aluminium, its anisotropic sheen, the rolled rim with its
    /// glints, the stamped ring and the chrome hub plate. Drawn centred in a
    /// square of side 2r.
    static func flange(_ gc: GraphicsContext, _ g: ReelGeometry) {
        let c = CGPoint(x: g.r, y: g.r)
        let disk = circle(c, g.r)
        gc.fill(disk, with: .color(Palette.rgb(0xC8CACD)))
        var spun = gc
        spun.clip(to: disk)
        spun.blendMode = .overlay
        spun.draw(Image(uiImage: Texture.spun), in: square(c, g.r))
        gc.fill(disk, with: .conicGradient(Gradient(colors: [
            .white.opacity(0), .white.opacity(0.6), .white.opacity(0), .black.opacity(0.16),
            .white.opacity(0), .white.opacity(0.45), .white.opacity(0), .black.opacity(0.2),
            .white.opacity(0)
        ]), center: c, angle: .degrees(-60)))

        let light = { (r: Double) in
            GraphicsContext.Shading.linearGradient(Gradient(colors: [.white.opacity(0.95), .black.opacity(0.45)]),
                                                   startPoint: CGPoint(x: c.x, y: c.y - r),
                                                   endPoint: CGPoint(x: c.x, y: c.y + r))
        }
        let shade = { (r: Double) in
            GraphicsContext.Shading.linearGradient(Gradient(colors: [.black.opacity(0.35), .white.opacity(0.7)]),
                                                   startPoint: CGPoint(x: c.x, y: c.y - r),
                                                   endPoint: CGPoint(x: c.x, y: c.y + r))
        }
        gc.stroke(circle(c, g.r - 0.5), with: light(g.r), lineWidth: 1)
        gc.stroke(circle(c, g.r - 2.4), with: shade(g.r), lineWidth: 0.8)
        gc.stroke(circle(c, g.ring), with: shade(g.ring), lineWidth: 1)
        gc.stroke(circle(c, g.ring - 1.2), with: light(g.ring), lineWidth: 0.6)
        for (from, to, alpha) in [(-2.55, -1.75, 0.95), (0.55, 1.0, 0.45)] {
            var glint = Path()
            arc(&glint, around: c, radius: g.r - 1.2, from: from, to: to)
            gc.stroke(glint, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }

        // The hub plate, shadowed onto the flange.
        let h = g.core
        gc.fill(circle(CGPoint(x: c.x, y: c.y + 1), h + 1.5), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.35), .clear]),
            center: CGPoint(x: c.x, y: c.y + 1), startRadius: h - 1, endRadius: h + 1.5))
        gc.fill(circle(c, h), with: .radialGradient(
            Gradient(colors: [.white, Palette.rgb(0xC2C4C7), Palette.rgb(0x86888B)]),
            center: CGPoint(x: c.x - h * 0.3, y: c.y - h * 0.4), startRadius: 0, endRadius: h * 1.5))
        gc.fill(circle(c, h), with: .conicGradient(Gradient(colors: [
            .clear, .white.opacity(0.5), .clear, .black.opacity(0.12), .clear, .white.opacity(0.4), .clear,
            .black.opacity(0.12), .clear
        ]), center: c, angle: .degrees(-60)))
        gc.stroke(circle(c, h - 0.4), with: .color(Palette.rgb(0x505255)), lineWidth: 0.8)
        gc.stroke(circle(c, h * 0.78), with: .color(.white.opacity(0.55)), lineWidth: 0.5)
    }

    static func circle(_ c: CGPoint, _ r: Double) -> Path {
        Path(ellipseIn: square(c, r))
    }

    static func square(_ c: CGPoint, _ r: Double) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }
}

/// A reel's artwork for one size, made once: the lit metal and the full pack as
/// images, and the turning parts as paths about the origin at angle zero.
private struct ReelArt {
    let geometry: ReelGeometry
    let flange: Image
    /// The fullest pack, one ring per pixel at `scale`.
    let pack: Image
    let scale: Double
    /// One window centred on angle zero, and all three.
    let window: Path
    let windows: Path
    let ticks: Path
    let knob: Path
    let knurl: Path

    @MainActor private static var cached: ReelArt?

    @MainActor static func shared(for g: ReelGeometry) -> ReelArt {
        if let art = cached, art.geometry.r == g.r { return art }
        let art = ReelArt(g)
        cached = art
        return art
    }

    @MainActor private init(_ g: ReelGeometry) {
        geometry = g
        scale = UIScreen.main.scale
        flange = Self.render(side: g.r * 2, scale: scale) { DeckArt.flange($0, g) }
        pack = Image(uiImage: Texture.tapePack(radius: Int((g.full * scale).rounded())))

        let one = g.window
        window = one
        windows = (0..<3).reduce(into: Path()) { all, k in
            all.addPath(one.applying(CGAffineTransform(rotationAngle: Double(k) * 2 * .pi / 3)))
        }

        // The footage scale along each window's outer edge.
        ticks = Path { p in
            for k in 0..<3 {
                let mid = Double(k) * 2 * .pi / 3
                for i in -8...8 {
                    let a = mid + Double(i) * 0.085
                    let r0 = g.windowOuter + 1.6, r1 = r0 + (i % 4 == 0 ? 3.2 : 1.8)
                    p.move(to: CGPoint(x: cos(a) * r0, y: sin(a) * r0))
                    p.addLine(to: CGPoint(x: cos(a) * r1, y: sin(a) * r1))
                }
            }
        }

        let h = g.core, lobe = h * 0.25
        let lobes = (0..<3).map { k -> CGPoint in
            let a = Double(k) * 2 * .pi / 3
            return CGPoint(x: cos(a) * h * 0.5, y: sin(a) * h * 0.5)
        }
        knob = lobes.reduce(DeckArt.circle(.zero, h * 0.42)) { $0.union(DeckArt.circle($1, lobe)) }
        knurl = Path { p in
            for (n, c) in lobes.enumerated() {
                let out = Double(n) * 2 * .pi / 3
                for i in -6...6 {
                    let a = out + Double(i) * 0.2
                    p.move(to: CGPoint(x: c.x + cos(a) * (lobe - 1.3), y: c.y + sin(a) * (lobe - 1.3)))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * lobe, y: c.y + sin(a) * lobe))
                }
            }
        }
    }

    /// Draws into a transparent square bitmap at the screen's scale.
    @MainActor private static func render(side: Double, scale: Double,
                                          _ draw: @escaping (GraphicsContext) -> Void) -> Image {
        let renderer = ImageRenderer(content: Canvas { gc, _ in draw(gc) }.frame(width: side, height: side))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "circle")
    }
}

/// Where the deck's parts sit for a given size.
private struct DeckLayout {
    let size: CGSize
    let reel: ReelGeometry
    let spread: Double
    let left: CGPoint
    let right: CGPoint
    /// Edge on, the tape is no thicker than a hairline.
    let tapeWidth = 1.1
    let guideRadius = 5.5
    /// The tape's centreline under the head.
    let tapeY: Double
    let guides: [CGPoint]
    /// How far the heads draw back off the tape.
    static let headLift = 3.5

    var midX: Double { size.width / 2 }
    var tapeTop: Double { tapeY - tapeWidth / 2 }

    init(size: CGSize) {
        self.size = size
        let r = min(size.height * 0.4, size.width * 0.2)
        reel = ReelGeometry(r: r)
        spread = min(size.width * 0.27, r * 1.75)
        let cy = size.height * 0.56, mid = size.width / 2
        left = CGPoint(x: mid - spread, y: cy)
        right = CGPoint(x: mid + spread, y: cy)
        let guideY = size.height - 17
        tapeY = guideY + guideRadius + tapeWidth / 2
        guides = [CGPoint(x: mid - 36, y: guideY), CGPoint(x: mid + 36, y: guideY)]
    }
}

/// A reel's proportions, all from its radius.
private struct ReelGeometry {
    let r: Double
    /// The hub the tape winds on, and the fullest pack.
    var core: Double { r * 0.3 }
    var full: Double { r * 0.86 }
    /// The stamped ring between the hub and the windows.
    var ring: Double { r * 0.4 }
    var rivetOrbit: Double { r * 0.6 }
    var rivet: Double { max(1.6, r * 0.035) }
    /// The windows' outer edge.
    var windowOuter: Double { r * 0.87 }

    /// Pack radius holding `fill` (0…1) of the tape: area grows with length.
    func pack(fill: Double) -> Double {
        (core * core + (full * full - core * core) * min(max(fill, 0), 1)).squareRoot()
    }

    /// One of the three flange windows, about the origin at angle zero: an
    /// annular sector with rounded corners.
    var window: Path {
        let corner = r * 0.07
        let inner = ring + 3 + corner, outer = windowOuter - corner
        let half = 0.72 - corner / ((inner + outer) / 2)
        var sector = Path()
        sector.addArc(center: .zero, radius: outer, startAngle: .radians(-half),
                      endAngle: .radians(half), clockwise: false)
        sector.addArc(center: .zero, radius: inner, startAngle: .radians(half),
                      endAngle: .radians(-half), clockwise: true)
        sector.closeSubpath()
        return sector.union(sector.strokedPath(StrokeStyle(lineWidth: corner * 2, lineJoin: .round)))
    }
}

/// "6 h 20 min left in the topic" embossed on the deck plate, in real time at the
/// current speed.
private struct LectureLeftLabel: View {
    @ObservedObject var clock: PlaybackClock
    let rate: Float

    var body: some View {
        let left = PlaybackMath.remaining(clock.remaining, rate: rate)
        Text(rate == 1 ? "\(formatDuration(left)) left in the lecture"
                       : "\(formatDuration(left)) left in the lecture at \(AudioPlayer.rateLabel(rate))")
            .font(.helvetica(11, weight: .bold))
            .embossed(Palette.rgb(0x5A5A5A))
            // Engraved in the tape deck's metal, which stays light.
            .environment(\.colorScheme, .light)
            .lineLimit(1)
    }
}

/// The sleep-timer key's word, blue while a timer runs (opens the sleep-timer
/// screen). Observes the clock
/// so the minutes countdown updates live; `mode` is passed in (it changes only when
/// the user picks a timer).
private struct SleepTimerLabel: View {
    @ObservedObject var clock: PlaybackClock
    let mode: SleepMode

    var body: some View {
        Text(label)
            .monospacedDigit()
            .foregroundStyle(mode == .off ? .white : Palette.rgb(0x8CC8FF))
            .accessibilityLabel(mode == .off ? "Sleep Timer" : "Sleep Timer: \(label)")
    }

    private var label: String {
        switch mode {
        case .off: return String(localized: "Timer")
        case .minutes where clock.sleepRemaining != nil:
            return formatTime(clock.sleepRemaining ?? 0)
        case .endOfChapter: return String(localized: "Lecture", comment: "The sleep timer key, set to the end of the lecture")
        default: return mode.title
        }
    }
}

/// The system volume slider in the iOS 6 Music player's own lecture and knob.
/// Includes the AirPlay button.
private struct ClassicVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.setVolumeThumbImage(UIImage(named: "Classic/VolumeThumb"), for: .normal)
        view.setMinimumVolumeSliderImage(Self.lecture("Classic/VolumeFill"), for: .normal)
        view.setMaximumVolumeSliderImage(Self.lecture("Classic/VolumeTrack"), for: .normal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    private static func lecture(_ name: String) -> UIImage? {
        UIImage(named: name)?.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
    }
}

/// Sleep-timer screen, pushed from Now Playing. Picking an option applies it and
/// returns to the player.
struct SleepTimerView: View {
    @EnvironmentObject private var player: AudioPlayer
    let onDone: () -> Void

    private let options: [SleepMode] = [.off, .minutes(15), .minutes(30), .minutes(45),
                                        .minutes(60), .endOfChapter]

    var body: some View {
        GroupedList {
            GroupedSection {
                ForEach(options) { mode in
                    CheckmarkRow(title: mode.longTitle, isSelected: mode == player.sleepMode) {
                        player.setSleep(mode)
                        onDone()
                    }
                }
            }
            SleepRemainingFooter(clock: player.clock, mode: player.sleepMode)
        }
        .navigationTitle("Sleep Timer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Live countdown under the sleep options while a minutes timer runs.
private struct SleepRemainingFooter: View {
    @ObservedObject var clock: PlaybackClock
    let mode: SleepMode

    var body: some View {
        GroupFooter(text)
            .padding(.horizontal, GroupedMetrics.rowInset)
            .frame(maxWidth: .infinity)
    }

    private var text: String {
        if case .minutes = mode, let r = clock.sleepRemaining {
            return String(localized: "Pausing in \(formatTime(r)). The sound fades out at the end.") + Self.shakeHint
        } else if mode == .endOfChapter {
            return String(localized: "Playback fades out at the end of this lecture.")
        }
        return String(localized: "The sound fades out before it pauses.") + Self.shakeHint
    }

    private static var shakeHint: String {
        " " + String(localized: "Shake the phone to add 10 minutes, or within 2 minutes of the pause to resume.")
    }
}

/// The back of the artwork: a black segmented strip, "Chapters" or "Bookmarks",
/// over the list it picks.
private struct PlayerListSide: View {
    enum Side: Hashable { case chapters, bookmarks }

    let push: (PlayerRoute) -> Void
    let onDone: () -> Void

    @EnvironmentObject private var player: AudioPlayer
    @ObservedObject private var store = BookmarkStore.shared
    @State private var side = Side.chapters

    var body: some View {
        VStack(spacing: 0) {
            ClassicSegmentedControl(options: [(.chapters, String(localized: "Lectures")), (.bookmarks, bookmarksTitle)],
                                    selection: $side, skin: .black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background {
                    LinearGradient(colors: [Palette.rgb(0x3C3C3C), Palette.rgb(0x1E1E1E)],
                                   startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .bottom) { Rectangle().fill(.black).frame(height: 1) }
                }
            switch side {
            case .chapters: LecturesListView(onDone: onDone)
            case .bookmarks: BookmarksView(onDone: onDone, onEdit: { push(.editBookmark($0)) })
            }
        }
    }

    private var bookmarksTitle: String {
        let count = player.topic.map { store.bookmarks(for: $0.id).count } ?? 0
        return count == 0 ? String(localized: "Bookmarks") : String(localized: "Bookmarks (\(count))")
    }
}

/// The playing topic's chapters on the back of the artwork, as Music listed an
/// album's lectures: the number, or the blue speaker on the one playing; the title;
/// the length. Opens at the playing chapter; picking one plays it and turns back.
struct LecturesListView: View {
    @EnvironmentObject private var player: AudioPlayer
    let onDone: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array((player.topic?.lectures ?? []).enumerated()), id: \.element.id) { index, lecture in
                    let current = index == player.currentIndex
                    RowButton(action: {
                        if current { player.play() } else { player.play(index: index) }
                        onDone()
                    }) {
                        HStack(spacing: 10) {
                            LectureNumber(index: index, isCurrent: current)
                            Text(lecture.displayTitle(at: index))
                                .font(.rowTitle)
                                .rowForeground(current ? Palette.selection : Palette.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatTime(lecture.duration))
                                .font(.rowDetail)
                                .rowForeground(Palette.secondaryText)
                        }
                        .frame(minHeight: 44)
                    }
                    .id(index)
                    .trackRow(index)
                    .plainRow()
                }
            }
            .listStyle(.plain)
            .plainBackground()
            .onAppear { proxy.scrollTo(player.currentIndex, anchor: .center) }
        }
    }
}

/// Speed screen, pushed from Now Playing: presets for this topic plus a way back to
/// the default. Picking applies and returns to the player.
struct SpeedView: View {
    @EnvironmentObject private var player: AudioPlayer
    let onDone: () -> Void

    var body: some View {
        GroupedList {
            GroupedSection(footer: String(localized: "Each topic remembers its speed. Fine-tune it with − and + in the player.")) {
                ForEach(AudioPlayer.ratePresets, id: \.self) { r in
                    CheckmarkRow(title: AudioPlayer.rateLabel(r), isSelected: r == player.rate) {
                        player.setRate(r)
                        onDone()
                    }
                }
            }
            if player.hasTopicRate {
                GroupedSection {
                    RowButton(action: {
                        player.resetTopicRate()
                        onDone()
                    }) {
                        Text("Default (\(AudioPlayer.rateLabel(player.defaultRate)))")
                            .font(.groupedLabel)
                            .rowForeground(Palette.text)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Speed")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A card that turns over around its vertical axis, showing `back` once it's
/// past edge-on — the iOS 6 flip transition. Animate `angle` between 0 and 180.
struct FlipView<Front: View, Back: View>: View, Animatable {
    var angle: Double
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showsBack = angle > 90
        ZStack {
            front
                .opacity(showsBack ? 0 : 1)
                .allowsHitTesting(!showsBack)
            back
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(showsBack ? 1 : 0)
                .allowsHitTesting(showsBack)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .background(Color.black)
    }
}
