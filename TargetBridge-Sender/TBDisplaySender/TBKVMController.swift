import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Network

/// Software-KVM input capture. When active, an event tap on a dedicated thread
/// consumes the sender's keyboard/mouse and forwards them to the receiver, which
/// drives its own native desktop. The local cursor is parked and the escape
/// hotkey (⌃⌥⌘K) — recognized inside the tap — always returns control.
///
/// The tap runs OFF the main runloop on purpose: an active tap blocks input
/// delivery until its callback returns, so a main-thread hitch would freeze the
/// whole system's input. The callback only accumulates/forwards and returns fast.
final class TBKVMController: @unchecked Sendable {
    static let shared = TBKVMController()

    // 'k' = kVK_ANSI_K. Escape chord = control+option+command+K.
    private static let escapeKeycode: Int64 = 0x28
    private static let escapeFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    private let lock = NSLock()
    private var active = false
    private var connection: NWConnection?
    /// Called on the main actor when the tap (escape hotkey / a failsafe) forces
    /// KVM off, so the owner can update UI and tell the receiver to exit.
    private var onForceDeactivate: (() -> Void)?

    private var tapThread: Thread?
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var flushTimer: CFRunLoopTimer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var userActivityTimer: Timer?
    private var idleAssertionID = IOPMAssertionID(0)

    // Mouse-move coalescing — touched only on the tap thread (callback + timer
    // run serially on the same runloop), so no locking is needed for these.
    private var pendingDX: Int = 0
    private var pendingDY: Int = 0
    private var hasPendingMove = false

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    // MARK: - Lifecycle (called from the main actor)

    /// Returns false (and does not activate) if Accessibility isn't granted.
    @MainActor
    func activate(connection: NWConnection, onForceDeactivate: @escaping () -> Void) -> Bool {
        if isActive { return true }
        guard Self.ensureAccessibilityPermission() else { return false }

        lock.lock()
        self.connection = connection
        self.onForceDeactivate = onForceDeactivate
        lock.unlock()

        // Park the local cursor: freeze it (deltas still flow to the tap) and hide it.
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()

        let thread = Thread { [weak self] in self?.runTapThread() }
        thread.name = "fd.tbmonitor.sender.kvm-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Failsafes: if the sender resigns active or is quitting, never leave the
        // user with a parked/hidden cursor — force KVM off.
        let nc = NotificationCenter.default
        lifecycleObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.forceDeactivateFromTap()
            },
            nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.forceDeactivateFromTap()
            }
        ]

        // Keep this Mac awake while it's driving the remote. The user's input is
        // consumed and forwarded, so the local idle timer sees no activity and
        // would fire the screensaver/lock mid-session (even worse while passively
        // watching remote video). Declare user activity now and on a repeating
        // timer so the screensaver/display-sleep never engage during KVM.
        declareUserActivity()
        userActivityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.declareUserActivity() }
        }

        lock.lock(); active = true; lock.unlock()
        Self.installAtExitFailsafe()
        return true
    }

    @MainActor
    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("TargetBridge KVM active" as CFString,
                                         kIOPMUserActiveLocal,
                                         &idleAssertionID)
    }

    /// Called by the owning session when its connection drops, so KVM can't
    /// linger after the receiver is gone.
    func notifyConnectionLost() {
        guard isActive else { return }
        forceDeactivateFromTap()
    }

    /// Idempotent. Removes the tap, un-parks the cursor, stops the thread.
    @MainActor
    func deactivate() {
        lock.lock()
        let wasActive = active
        active = false
        connection = nil
        onForceDeactivate = nil
        lock.unlock()
        guard wasActive else { return }

        let nc = NotificationCenter.default
        lifecycleObservers.forEach { nc.removeObserver($0) }
        lifecycleObservers.removeAll()

        userActivityTimer?.invalidate()
        userActivityTimer = nil

        if let rl = runLoop { CFRunLoopStop(rl) }
        tapThread = nil

        // Always un-park, even if teardown of the tap raced.
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    // MARK: - Tap thread

    private func runTapThread() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // active: callback may return nil to consume
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<TBKVMController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("TargetBridge: KVM event tap creation failed")
            Task { @MainActor [weak self] in self?.forceDeactivateFromTap() }
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let rl = CFRunLoopGetCurrent()
        runLoop = rl
        CFRunLoopAddSource(rl, source, .commonModes)

        // ~120 Hz flush of coalesced mouse motion.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, 0, 1.0 / 120.0, 0, 0) { [weak self] _ in
            self?.flushPendingMove()
        }
        flushTimer = timer
        CFRunLoopAddTimer(rl, timer, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()   // blocks until CFRunLoopStop in deactivate()

        // Teardown on this thread.
        if let timer = flushTimer { CFRunLoopTimerInvalidate(timer); flushTimer = nil }
        if let source = runLoopSource { CFRunLoopRemoveSource(rl, source, .commonModes); runLoopSource = nil }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTap = nil
        runLoop = nil
    }

    // MARK: - Event handling (tap thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap on timeout / user input; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                forceDeactivateFromTap()
            }
            return nil
        }

        switch type {
        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == Self.escapeKeycode,
               event.flags.isSuperset(of: Self.escapeFlags) {
                forceDeactivateFromTap()       // escape chord — swallow, return control
                return nil
            }
            flushPendingMove()
            forwardKey(keycode: Int(keycode), down: true, flags: event.flags.rawValue)
            return nil

        case .keyUp:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            flushPendingMove()
            forwardKey(keycode: Int(keycode), down: false, flags: event.flags.rawValue)
            return nil

        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let down = Self.modifierIsDown(keycode: keycode, flags: event.flags)
            flushPendingMove()
            forwardKey(keycode: Int(keycode), down: down, flags: event.flags.rawValue)
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pendingDX += Int(event.getIntegerValueField(.mouseEventDeltaX))
            pendingDY += Int(event.getIntegerValueField(.mouseEventDeltaY))
            hasPendingMove = true
            return nil

        case .leftMouseDown, .leftMouseUp:
            flushPendingMove()
            forwardButton(0, down: type == .leftMouseDown)
            return nil

        case .rightMouseDown, .rightMouseUp:
            flushPendingMove()
            forwardButton(1, down: type == .rightMouseDown)
            return nil

        case .otherMouseDown, .otherMouseUp:
            flushPendingMove()
            forwardButton(2, down: type == .otherMouseDown)
            return nil

        case .scrollWheel:
            let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            forward(.inputScroll, TBMonitorInputScroll(dx: dx, dy: dy))
            return nil

        default:
            return nil
        }
    }

    private func flushPendingMove() {
        guard hasPendingMove else { return }
        let dx = pendingDX, dy = pendingDY
        pendingDX = 0; pendingDY = 0; hasPendingMove = false
        if dx != 0 || dy != 0 {
            forward(.inputMouseMove, TBMonitorInputMouseMove(dx: dx, dy: dy))
        }
    }

    private func forwardKey(keycode: Int, down: Bool, flags: UInt64) {
        forward(.inputKey, TBMonitorInputKey(keycode: keycode, down: down, flags: flags))
    }

    private func forwardButton(_ button: Int, down: Bool) {
        forward(.inputMouseButton, TBMonitorInputMouseButton(button: button, down: down))
    }

    private func forward<T: Encodable>(_ type: TBMonitorPacketType, _ value: T) {
        lock.lock(); let conn = connection; lock.unlock()
        guard let conn, let pkt = TBMonitorProtocol.makeJSONPacket(type: type, value: value) else { return }
        conn.send(content: pkt, completion: .contentProcessed({ _ in }))
    }

    private func forceDeactivateFromTap() {
        lock.lock(); let cb = onForceDeactivate; lock.unlock()
        DispatchQueue.main.async { cb?() }
    }

    // MARK: - Helpers

    /// Maps a modifier keycode + current flags to a down/up state.
    private static func modifierIsDown(keycode: Int64, flags: CGEventFlags) -> Bool {
        let mask: CGEventFlags
        switch keycode {
        case 56, 60: mask = .maskShift        // L/R Shift
        case 59, 62: mask = .maskControl       // L/R Control
        case 58, 61: mask = .maskAlternate     // L/R Option
        case 54, 55: mask = .maskCommand       // L/R Command
        case 57:     mask = .maskAlphaShift    // Caps Lock
        case 63:     mask = .maskSecondaryFn   // Fn
        default:     return false
        }
        return flags.contains(mask)
    }

    @MainActor
    private static func ensureAccessibilityPermission() -> Bool {
        // Literal key value (= kAXTrustedCheckOptionPrompt) to avoid referencing
        // the imported global `var`, which Swift 6 flags as non-Sendable.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // Crash failsafe: re-associate the cursor on abnormal exit so the user is
    // never left with a frozen pointer.
    @MainActor private static var atExitInstalled = false
    @MainActor
    private static func installAtExitFailsafe() {
        guard !atExitInstalled else { return }
        atExitInstalled = true
        atexit { CGAssociateMouseAndMouseCursorPosition(1) }
    }
}
