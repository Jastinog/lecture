import ObjectiveC
import SwiftUI
import UIKit

// iOS 6 navigation: a push slides the new screen in from the right while the old
// one slides out to the left, both the full width and in lockstep — no parallax,
// no dimming, no shadow — on the curve UIKit moves the bar by, so the two keep together.
//
// SwiftUI's `NavigationStack` never asks its navigation controller's delegate
// for an animator, so the standard one is restyled instead: UIKit's own push/pop
// animator gets our slide in place of iOS 7's parallax. The system edge swipe
// (an iOS 7 addition, kept for convenience) drives that same slide, the bar's
// titles included.

@MainActor
enum ClassicTransitions {
    nonisolated static let transitionDuration: TimeInterval = 0.35

    /// Restyles UIKit's push/pop animator. Call once at launch.
    static func install() {
        guard let cls = NSClassFromString("_UINavigationParallaxTransition") else { return }
        // UIKit calls the animator on the main thread.
        let animate: @convention(block) (AnyObject, UIViewControllerContextTransitioning) -> Void = { _, context in
            MainActor.assumeIsolated { slide(context) }
        }
        let duration: @convention(block) (AnyObject, UIViewControllerContextTransitioning?) -> TimeInterval = { _, _ in
            transitionDuration
        }
        replace(cls, #selector(UIViewControllerAnimatedTransitioning.animateTransition(using:)),
                with: imp_implementationWithBlock(animate))
        replace(cls, #selector(UIViewControllerAnimatedTransitioning.transitionDuration(using:)),
                with: imp_implementationWithBlock(duration))
    }

    private static func replace(_ cls: AnyClass, _ selector: Selector, with imp: IMP) {
        if let method = class_getInstanceMethod(cls, selector) { method_setImplementation(method, imp) }
    }

    /// Both screens slide the full width together.
    private static func slide(_ context: UIViewControllerContextTransitioning) {
        guard let fromVC = context.viewController(forKey: .from),
              let toVC = context.viewController(forKey: .to),
              let from = context.view(forKey: .from) ?? fromVC.view,
              let to = context.view(forKey: .to) ?? toVC.view else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        // A popped screen has already left the stack; a covered one hasn't.
        let push = toVC.navigationController?.viewControllers.contains(fromVC) ?? true
        // UIKit sets up the bar's crossfade a moment later.
        let bar = (toVC.navigationController ?? fromVC.navigationController)?.navigationBar
        if let bar { DispatchQueue.main.async { slideBarItems(in: bar, push: push) } }
        let container = context.containerView
        let width = container.bounds.width
        let final = context.finalFrame(for: toVC)
        let start = from.frame
        if push { container.addSubview(to) } else { container.insertSubview(to, belowSubview: from) }
        to.frame = final.offsetBy(dx: push ? width : -width, dy: 0)
        // Lay the new screen out now, so it slides in drawn rather than filling
        // in on the way.
        to.layoutIfNeeded()

        // The tab bar rides with whichever of the two screens shows it.
        let fromShowsBar = !TabBarHider.hides(fromVC), toShowsBar = !TabBarHider.hides(toVC)
        if fromShowsBar != toShowsBar { TabBarTracker.shared.follow(fromShowsBar ? from : to, in: container) }

        // UIKit moves the bar's background and titles on the coordinator's
        // curve (a spring, not ease-in-out); the screens move on the same one,
        // or the bar runs ahead of them and opens a gap.
        let curve = (toVC.transitionCoordinator ?? fromVC.transitionCoordinator)?.completionCurve ?? .easeInOut
        let options = context.isInteractive
            ? UIView.AnimationOptions.curveLinear
            : UIView.AnimationOptions(rawValue: UInt(curve.rawValue) << 16)
        UIView.animate(withDuration: transitionDuration, delay: 0, options: options) {
            to.frame = final
            from.frame = start.offsetBy(dx: push ? -width : width, dy: 0)
        } completion: { _ in
            let cancelled = context.transitionWasCancelled
            if cancelled {
                from.frame = start
                to.removeFromSuperview()
            }
            if fromShowsBar != toShowsBar { TabBarTracker.shared.finish(shown: cancelled ? fromShowsBar : toShowsBar) }
            context.completeTransition(!cancelled)
        }
    }

    /// iOS 6's bar push: the titles and the back-button side slide half the bar
    /// across as they cross-fade (the old title heading for the back button's
    /// place), while the right-hand buttons only fade. UIKit's own cross-fade
    /// is left running — the outgoing views fade to 0, the incoming to 1 — and
    /// each frame `BarSlide` reads how far a view has faded and shifts it as far.
    /// The edge swipe scrubs those fades, so the slide follows the finger, and
    /// back again if the swipe is given up.
    private static func slideBarItems(in bar: UINavigationBar, push: Bool) {
        guard let content = bar.subviews.first(where: { "\(type(of: $0))".contains("ContentView") })
        else { return }
        let width = bar.bounds.width
        // The outgoing title may sit in a plain container view.
        let items = content.subviews.flatMap { type(of: $0) == UIView.self ? $0.subviews : [$0] }
        var tracks: [BarSlide.Track] = []
        for item in items where item.layer.animation(forKey: "opacity") != nil {
            let isTitle = "\(type(of: item))".contains("TitleControl")
            let frame = item.convert(item.bounds, to: bar)
            guard isTitle || frame.midX < width / 2 else { continue }
            let outgoing = item.alpha == 0
            let shift = (push ? 1 : -1) * width / 2
            tracks.append(.init(view: item, offset: outgoing ? -shift : shift))
        }
        BarSlide(tracks).start()
    }
}

/// Shifts bar items in step with their fade: fully faded out (or not yet in)
/// means fully shifted. Lives until the fades are gone, then puts them back.
private final class BarSlide: NSObject {
    struct Track {
        weak var view: UIView?
        /// The shift at zero opacity.
        let offset: CGFloat
    }

    private let tracks: [Track]
    private var link: CADisplayLink?

    init(_ tracks: [Track]) { self.tracks = tracks }

    func start() {
        guard !tracks.isEmpty else { return }
        step()
        // The link holds its target, keeping this alive until `stop`.
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        var running = false
        for track in tracks {
            guard let view = track.view else { continue }
            guard view.layer.animation(forKey: "opacity") != nil,
                  let shown = view.layer.presentation()?.opacity else {
                view.transform = .identity
                continue
            }
            running = true
            view.transform = CGAffineTransform(translationX: track.offset * CGFloat(1 - shown), y: 0)
        }
        if !running { stop() }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        for track in tracks { track.view?.transform = .identity }
    }
}

/// Where the tab bar sits across the screen. It lies over the stacks rather
/// than beside them, so pushing a screen without it (Now Playing, as iOS 6
/// Music's `hidesBottomBarWhenPushed`) never resizes either screen; the screens
/// that show it keep clear of it through their safe area (`barHeight`).
/// During a push or pop between a screen with the bar and one without, it
/// follows the one with it frame by frame, the edge swipe included.
@MainActor
final class TabBarTracker: ObservableObject {
    static let shared = TabBarTracker()
    /// The room the bar takes at the foot of every stack, given as safe area
    /// so lists scroll their last rows clear of it.
    nonisolated static let barHeight: CGFloat = 49
    /// How far the bar is shifted left or right of its place.
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var hidden = false

    private weak var view: UIView?
    private weak var container: UIView?
    private var link: CADisplayLink?

    func follow(_ view: UIView, in container: UIView) {
        self.view = view
        self.container = container
        hidden = false
        step()
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func finish(shown: Bool) {
        link?.invalidate()
        link = nil
        offset = 0
        hidden = !shown
    }

    @objc private func step() {
        guard let view, let container else { return }
        let frame = view.layer.presentation()?.frame ?? view.frame
        let offset = frame.minX - container.bounds.minX
        if offset != self.offset { self.offset = offset }
    }
}

/// Marks a screen that hides the tab bar: it gives back the room the bar's
/// screens keep clear (`TabBarTracker.barHeight`), and the bar slides off
/// with the screen it was on.
struct TabBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {}

    /// Whether the stack entry `screen` hides the tab bar.
    static func hides(_ screen: UIViewController) -> Bool {
        screen.children.contains { $0 is Probe || hides($0) }
    }

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // The stack entry hosting this probe is one of its ancestors.
            var ancestor = parent
            while let vc = ancestor, !(vc.parent is UINavigationController) { ancestor = vc.parent }
            ancestor?.additionalSafeAreaInsets.bottom = -TabBarTracker.barHeight
        }
    }
}

/// Hiding the system back button (for our arrow-shaped one) switches off the
/// edge swipe; keep it working.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        additionalSafeAreaInsets.bottom = TabBarTracker.barHeight
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Not while a push or pop is still sliding: a swipe begun then wedges the stack.
        viewControllers.count > 1 && transitionCoordinator == nil
    }
}
