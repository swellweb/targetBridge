import AppKit
import CoreVideo
import Foundation

/// Keeps the virtual display compositing at its full rate by giving it
/// something that always changes.
///
/// WHY
///
/// A CGVirtualDisplay has no scanout forcing a rhythm, so WindowServer
/// composites it only when something changes. Read a still page and content
/// production sags to about 5.6 Hz — measured — and the next keystroke then
/// waits for whatever tick comes next. That wait is 173 ms on average and past
/// 1.4 s at worst, and it is the whole of what "it feels sluggish when I start
/// typing again" means. Nothing downstream can fix it: the pixels for that
/// keystroke do not exist yet, so there is nothing for the encoder or the link
/// to be faster about.
///
/// The display has no slow mode of its own, though. Whenever anything on it
/// animates — a video, a spinner — it holds a rock-solid 60 Hz indefinitely,
/// including for 37 seconds with no input at all. So the fix is not to make it
/// faster, it is to stop letting it go quiet: put one pixel on it that changes
/// every frame, and the compositor keeps producing. A keystroke then lands in a
/// frame that was going to be composited anyway.
///
/// WHAT IT COSTS
///
/// Every composited frame is a real frame to us — encoded, sent, decoded — so
/// this trades bandwidth and heat for latency, permanently rather than only
/// while it is needed. That is a deliberate choice for this setup: it runs on
/// mains power, and watching a video already pins both machines at exactly this
/// load, so the ceiling is one we know both ends survive.
///
/// `defaults write com.targetbridge.sender TBKeepWarm -bool false` turns it off.
///
/// HOW
///
/// A 1×1 borderless window in a corner of the virtual display, alternating
/// between two colours a single step apart. One pixel out of nearly fifteen
/// million, changing by 1/255 — invisible in practice, and enough damage that
/// WindowServer must composite the frame. Driven by a CVDisplayLink bound to
/// that display, so the beat is the display's own rather than a timer racing
/// it.
@MainActor
final class TBKeepWarm {
    private var window: NSWindow?
    private var link: CVDisplayLink?
    private var phase = false

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "TBKeepWarm") as? Bool) ?? true
    }

    /// `displayID` must be the virtual display: the point is to keep THAT
    /// compositor busy, and a window on any other screen would keep the wrong
    /// one awake while doing nothing for the link.
    func start(displayID: CGDirectDisplayID) {
        guard Self.isEnabled, window == nil else { return }

        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else {
            TBLog.connection.warning("keep-warm: display \(displayID, privacy: .public) has no bounds; not starting")
            return
        }

        // Bottom-left corner in Cocoa coordinates. CGDisplayBounds is top-left
        // origin and NSWindow is bottom-left, so the y needs flipping against
        // the primary display's height.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let origin = NSPoint(x: bounds.minX,
                             y: primaryHeight - bounds.maxY)

        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .normal
        // Present on every Space and in every app, so switching desktops does
        // not silently take the beat away.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.backgroundColor = .black
        w.alphaValue = 1.0
        w.orderFrontRegardless()
        window = w

        var displayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink) == kCVReturnSuccess,
              let displayLink else {
            TBLog.connection.warning("keep-warm: could not create a display link; not starting")
            w.close(); window = nil
            return
        }

        // The callback is C and runs on the link's own thread; hop to main
        // because the change it makes is to a window.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let me = Unmanaged<TBKeepWarm>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.tick() } }
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(displayLink)
        link = displayLink

        TBLog.connection.notice("keep-warm: on (display \(displayID, privacy: .public)) — TBKeepWarm=false disables")
    }

    func stop() {
        if let link {
            CVDisplayLinkStop(link)
            self.link = nil
        }
        window?.close()
        window = nil
    }

    /// One step of the alternation. Two greys one level apart: enough for
    /// WindowServer to treat the window as dirty, not enough for an eye to see.
    private func tick() {
        guard let window else { return }
        phase.toggle()
        let v = phase ? 0.0 : 1.0 / 255.0
        window.backgroundColor = NSColor(red: v, green: v, blue: v, alpha: 1.0)
    }

    // No deinit: a nonisolated one cannot touch these main-actor properties
    // under Swift 6, and it would be redundant anyway — this object lives as
    // long as the service, and `stop()` runs on every teardown path.
}
