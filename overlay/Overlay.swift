// Glass notification banner with a class-colored tint, drawn top-right.
// Behaves like a macOS banner: never takes focus, stays while the pointer is
// over it (with a close button), and closes on click or a two-finger swipe to
// the right. In "auto" mode it also fades out after a few seconds; in "sticky"
// mode it stays until you close it. It also files a copy in Notification Center
// (provisional delivery: no macOS banner, no permission prompt), except for
// the grey "quiet" class.
// Usage: notify-overlay <class> <title> <message> [icon] [auto|sticky]
//        notify-overlay --nc-status
//   class  done | progress | question | failed | quiet
//   icon   a name from the repo's icons/ (claude, codex, grok, omp), or a path to an .app or image file
// install.sh builds it into ~/Applications/Agent Notify.app (Notification Center
// only accepts apps there, not in /tmp). Needs macOS 26 for Liquid Glass; older
// macOS falls back to a blurred material.
import AppKit
import UserNotifications

let args = CommandLine.arguments
// `notify-overlay --nc-status`: Notification Center authorization and how many
// of this app's notifications are there now (for troubleshooting).
if args.count == 2, args[1] == "--nc-status" {
  let center = UNUserNotificationCenter.current()
  center.getNotificationSettings { s in
    let status = [0: "not determined", 1: "denied", 2: "authorized", 3: "provisional", 4: "ephemeral"][s.authorizationStatus.rawValue] ?? "?"
    let style = [0: "none", 1: "banners", 2: "alerts"][s.alertStyle.rawValue] ?? "?"
    center.getDeliveredNotifications { d in
      print("authorization: \(status), alert style: \(style), in Notification Center: \(d.count)")
      if s.authorizationStatus == .authorized && s.alertStyle != .none {
        print("copies are skipped: macOS would show them as a second banner. Set System Settings > Notifications > Agent Notify > alert style to None.")
      }
      exit(0)
    }
  }
  RunLoop.main.run(until: Date().addingTimeInterval(5))
  exit(1)
}
guard args.count >= 4 else {
  FileHandle.standardError.write("usage: notify-overlay <class> <title> <message> [icon] [auto|sticky]\n".data(using: .utf8)!)
  exit(2)
}
let cls = args[1], title = args[2], message = args[3]
let iconArg = args.count > 4 ? args[4] : "claude"
let sticky = args.count > 5 && args[5] == "sticky"

let tints: [String: NSColor] = [
  "done": NSColor(srgbRed: 0.19, green: 0.78, blue: 0.36, alpha: 1),
  "progress": NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1),
  "question": NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1),
  "failed": NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1),
  "quiet": NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1),
]
let tint = tints[cls] ?? tints["quiet"]!
let seconds: Double = cls == "quiet" ? 3.5 : 5

/// Orange rounded square with an eight-ray spark, used when no app icon is given.
func sparkIcon(size: CGFloat) -> NSImage {
  NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: size * 0.23, yRadius: size * 0.23).fill()
    NSColor.white.setFill()
    let c = NSPoint(x: r.midX, y: r.midY), len = size * 0.27, w = size * 0.075
    for i in 0..<8 {
      var t = AffineTransform(translationByX: c.x, byY: c.y)
      t.rotate(byDegrees: CGFloat(i) * 45)
      let ray = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: size * 0.05, width: w, height: len), xRadius: w / 2, yRadius: w / 2)
      ray.transform(using: t)
      ray.fill()
    }
    return true
  }
}

func icon(size: CGFloat) -> NSImage {
  let fm = FileManager.default
  if !iconArg.contains("/"), // a name: icons/<name>.png, bundled into the app by install.sh
     let url = Bundle.main.url(forResource: iconArg, withExtension: "png", subdirectory: "icons"),
     let img = NSImage(contentsOf: url) { return img }
  if iconArg.hasSuffix(".app"), fm.fileExists(atPath: iconArg) { return NSWorkspace.shared.icon(forFile: iconArg) }
  if fm.fileExists(atPath: iconArg), let img = NSImage(contentsOfFile: iconArg) { return img }
  return sparkIcon(size: size)
}

let app = NSApplication.shared
// .prohibited for the whole run: macOS can then never make the banner the
// active app, so your typing stays where it is. (.accessory, even switched to
// after launch, still got activated now and then and took keyboard focus.)
// Hover is tracked by polling the pointer, since mouse-entered events need
// .accessory. If the app is activated anyway, focus goes straight back.
app.setActivationPolicy(.prohibited)
let previousApp = NSWorkspace.shared.frontmostApplication
NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
  previousApp?.activate()
}

// Notification Center copy: delivered quietly, grouped per agent ("Claude [dev]" → "Claude").
// Skipped when macOS would also show it as a banner (you allowed Agent Notify
// banners or alerts), so there is never a second banner over the glass one.
let ncPending = cls != "quiet"
if ncPending {
  let center = UNUserNotificationCenter.current()
  center.getNotificationSettings { settings in
    if settings.authorizationStatus == .authorized && settings.alertStyle != .none {
      DispatchQueue.main.async { ncDone = true; if quitting { app.terminate(nil) } }
      return
    }
    center.requestAuthorization(options: [.provisional]) { _, _ in
    let n = UNMutableNotificationContent()
    n.title = title
    n.body = message
    n.threadIdentifier = String(title.split(separator: " ").first ?? "agent")
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil)) { _ in
      DispatchQueue.main.async { ncDone = true; if quitting { app.terminate(nil) } }
    }
    }
  }
}
var ncDone = !ncPending, quitting = false
/// Quit once the banner is gone and the Notification Center copy is filed.
func quit() {
  if !slotFile.isEmpty { unlink(slotFile); slotFile = "" }
  quitting = true
  if ncDone { app.terminate(nil) }
}

let w: CGFloat = 356, h: CGFloat = 64, margin: CGFloat = 14, radius: CGFloat = 22, gap: CGFloat = 8
let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
/// Slots (0 = top) keep stacked banners from overlapping, even when several
/// start at once: each banner holds a lock file named after its slot until it
/// closes. A lock whose process is gone counts as free. When a banner above
/// closes, the ones below move up into the gap, like macOS banners do.
let slotDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/agent-notify/slots").path
let maxSlot = max(0, Int((screen.height - margin) / (h + gap)) - 1)
var slotFile = ""
/// Takes slot `i` if it is free (or its owner died); true on success.
func claim(_ i: Int) -> Bool {
  let path = "\(slotDir)/\(i)"
  for _ in 0..<2 {
    let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    if fd >= 0 {
      let pid = "\(getpid())"
      _ = pid.withCString { write(fd, $0, strlen($0)) }
      close(fd)
      return true
    }
    guard let owner = try? String(contentsOfFile: path, encoding: .utf8), let opid = Int32(owner),
          kill(opid, 0) != 0, errno == ESRCH else { return false }
    unlink(path)
  }
  return false
}
func frame(forSlot i: Int) -> NSRect {
  NSRect(x: screen.maxX - w - margin, y: screen.maxY - margin - h - CGFloat(i) * (h + gap), width: w, height: h)
}
try? FileManager.default.createDirectory(atPath: slotDir, withIntermediateDirectories: true)
var slot = (0...maxSlot).first(where: claim) ?? maxSlot
slotFile = "\(slotDir)/\(slot)"
var home = frame(forSlot: slot)

// The window stays put; only the card inside it moves (smooth, in step with the
// display). It is wider than the card so the card can slide out to the right,
// and padded so the card's shadow isn't clipped. Fully transparent parts let
// clicks through to the app below.
let pad: CGFloat = 12
func windowFrame(_ home: NSRect) -> NSRect {
  NSRect(x: home.minX - pad, y: home.minY - pad, width: w * 2 + margin + pad, height: h + pad * 2)
}
let panel = NSPanel(contentRect: windowFrame(home), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.becomesKeyOnlyIfNeeded = true
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

/// Ease-out curve close to the one macOS uses for banners.
let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

/// The card: takes every click, hover and swipe; the icon and labels don't.
final class BannerView: NSView {
  let close = NSButton()
  var hideWork: DispatchWorkItem?
  var swipe: CGFloat = 0          // how far the fingers have dragged it (points)
  var tracking = false            // a trackpad swipe is in progress
  var closing = false
  var lastScroll = Date.distantPast
  var samples: [(t: TimeInterval, dx: CGFloat)] = []
  var monitor: Any?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.22
    layer?.shadowRadius = 9
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
    close.isBordered = false
    close.imageScaling = .scaleProportionallyUpOrDown
    close.contentTintColor = .secondaryLabelColor
    close.frame = NSRect(x: 4, y: frame.height - 22, width: 18, height: 18)
    close.target = self
    close.action = #selector(closeClicked)
    close.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = convert(point, from: superview)
    if !close.isHidden, close.frame.contains(p) { return close }
    return bounds.contains(p) ? self : nil
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func scheduleHide(after s: Double) {
    hideWork?.cancel()
    if sticky { return }
    let work = DispatchWorkItem { [weak self] in self?.dismiss(slide: false) }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
  }
  override func mouseEntered(with event: NSEvent) { pointerEntered() }
  override func mouseExited(with event: NSEvent) { pointerLeft() }
  var hovering = false
  func pointerEntered() { guard !hovering else { return }; hovering = true; hideWork?.cancel(); close.isHidden = false }
  func pointerLeft() { guard hovering else { return }; hovering = false; close.isHidden = true; if !closing { scheduleHide(after: 2.5) } }
  override func mouseUp(with event: NSEvent) { dismiss(slide: false) }
  @objc func closeClicked() { dismiss(slide: false) }

  /// Moves the card `x` points right of its place (a little resistance to the
  /// left), fading as it goes. It's a layer transform, applied by the
  /// compositor every frame; moving the view's frame made AppKit and the glass
  /// redraw and the card stepped a few points at a time instead of gliding.
  var offset: CGFloat = 0
  func shownX(_ x: CGFloat) -> CGFloat { x >= 0 ? x : max(-14, x * 0.25) }
  func fade(_ x: CGFloat) -> Float { Float(1 - min(1, max(0, x) / w) * 0.8) }
  func setOffset(_ x: CGFloat) {
    offset = x
    guard let layer = layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeAllAnimations()
    layer.setAffineTransform(CGAffineTransform(translationX: shownX(x), y: 0))
    layer.opacity = fade(shownX(x))
    CATransaction.commit()
  }

  /// Animates the card from where it is now (mid-animation included) to offset
  /// `x` and the given opacity.
  func animate(to x: CGFloat, opacity: Float, duration: Double, timing: CAMediaTimingFunction, done: (() -> Void)? = nil) {
    guard let layer = layer else { done?(); return }
    let fromT = layer.presentation()?.affineTransform() ?? layer.affineTransform()
    let fromO = layer.presentation()?.opacity ?? layer.opacity
    offset = x
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { done?() }
    layer.removeAllAnimations()
    layer.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
    layer.opacity = opacity
    let move = CABasicAnimation(keyPath: "transform")
    move.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(fromT))
    move.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(x, 0, 0))
    let alpha = CABasicAnimation(keyPath: "opacity")
    alpha.fromValue = fromO
    alpha.toValue = opacity
    for a in [move, alpha] {
      a.duration = duration
      a.timingFunction = timing
      layer.add(a, forKey: a.keyPath)
    }
    CATransaction.commit()
  }

  // Trackpad: the card follows a two-finger swipe; a far drag or a quick flick
  // to the right closes it, anything else snaps back. Mice without gesture
  // phases: enough rightward scrolling within half a second closes it.
  var lastWheel = Date.distantPast
  override func scrollWheel(with event: NSEvent) { handle(event) }
  func handle(_ event: NSEvent) {
    guard !closing else { return }
    var dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    if event.phase.isEmpty && event.momentumPhase.isEmpty {
      if !event.hasPreciseScrollingDeltas { dx *= 10 }
      if Date().timeIntervalSince(lastWheel) > 0.5 { swipe = 0 }
      lastWheel = Date()
      swipe = max(0, swipe + dx)
      if swipe > 50 { dismiss(slide: true) }
      return
    }
    guard event.momentumPhase.isEmpty else { return }
    drag(dx, began: event.phase.contains(.began), ended: event.phase.contains(.ended) || event.phase.contains(.cancelled), time: event.timestamp)
  }

  /// One step of a trackpad swipe (also driven directly by AGENT_NOTIFY_SIM).
  func drag(_ dx: CGFloat, began: Bool, ended: Bool, time: TimeInterval) {
    guard !closing else { return }
    lastScroll = Date()
    if began || !tracking {
      tracking = true
      swipe = 0
      samples = []
      // The card slides out from under the pointer, and macOS then sends the
      // rest of the gesture to the app below; keep listening there too.
      if monitor == nil {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.handle(e) }
      }
    }
    swipe += dx
    samples.append((time, dx))
    samples.removeAll { time - $0.t > 0.1 }
    if ended {
      finishSwipe()
    } else {
      setOffset(swipe)
    }
  }

  /// Rightward speed of the last 0.1 s of the swipe, in points per second.
  var velocity: CGFloat {
    guard let first = samples.first, let last = samples.last, last.t > first.t else { return 0 }
    return samples.reduce(0) { $0 + $1.dx } / CGFloat(max(last.t - first.t, 0.016))
  }

  func stopListening() {
    if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    tracking = false
  }

  func finishSwipe() {
    let v = velocity
    stopListening()
    if swipe > 90 || (v > 450 && swipe > 8) {
      dismiss(slide: true, speed: v)
    } else {
      animate(to: 0, opacity: 1, duration: 0.35, timing: easeOut)
    }
    swipe = 0
  }

  func dismiss(slide: Bool, speed: CGFloat = 0) {
    guard !closing else { return }
    closing = true
    hideWork?.cancel()
    stopListening()
    let endX = slide ? w + margin + 8 : shownX(offset) + 24
    // A flick keeps its speed; otherwise a short ease-out.
    let distance = endX - shownX(offset)
    let duration = slide && speed > 0 ? min(0.3, max(0.12, Double(distance / speed) * 1.6)) : 0.28
    animate(to: endX, opacity: 0, duration: duration, timing: slide ? CAMediaTimingFunction(name: .easeOut) : easeOut) {
      self.window?.orderOut(nil)
      quit()
    }
  }
}

/// The window's content: the card plus empty room for it to slide into.
final class RootView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    // While a swipe is in progress the whole window takes the scroll events.
    if banner.tracking, bounds.contains(convert(point, from: superview)) { return self }
    return super.hitTest(point)
  }
  override func scrollWheel(with event: NSEvent) { banner.handle(event) }
}

// Content: icon, bold title, message. Text colors follow light/dark mode.
// The class color fades from the icon side to almost clear on the right
// (NSGlassEffectView.tintColor barely shows, so it's a gradient layer instead).
let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
content.wantsLayer = true
content.layer?.cornerRadius = radius
let wash = CAGradientLayer()
wash.frame = content.bounds
wash.cornerRadius = radius
wash.colors = [tint.withAlphaComponent(0.45).cgColor, tint.withAlphaComponent(0.04).cgColor]
wash.startPoint = CGPoint(x: 0, y: 0.5)
wash.endPoint = CGPoint(x: 1, y: 0.5)
content.layer?.addSublayer(wash)
let iv = NSImageView(frame: NSRect(x: 13, y: (h - 38) / 2, width: 38, height: 38))
iv.image = icon(size: 38)
iv.imageScaling = .scaleProportionallyUpOrDown
content.addSubview(iv)
func label(_ s: String, _ font: NSFont, _ color: NSColor, _ y: CGFloat) {
  let l = NSTextField(labelWithString: s)
  l.font = font
  l.textColor = color
  l.lineBreakMode = .byTruncatingTail
  l.frame = NSRect(x: 61, y: y, width: w - 61 - 16, height: 17)
  content.addSubview(l)
}
label(title, .systemFont(ofSize: 13, weight: .semibold), .labelColor, 33)
label(message, .systemFont(ofSize: 13), .secondaryLabelColor, 14)

let banner = BannerView(frame: NSRect(x: pad, y: pad, width: w, height: h))
if #available(macOS 26.0, *) {
  let glass = NSGlassEffectView(frame: content.frame)
  glass.cornerRadius = radius
  glass.contentView = content
  banner.addSubview(glass)
} else {
  let blur = NSVisualEffectView(frame: content.frame)
  blur.material = .hudWindow
  blur.blendingMode = .behindWindow
  blur.state = .active
  blur.wantsLayer = true
  blur.layer?.cornerRadius = radius
  blur.layer?.masksToBounds = true
  blur.addSubview(content)
  banner.addSubview(blur)
}
banner.addSubview(banner.close)
let root = RootView(frame: NSRect(origin: .zero, size: panel.frame.size))
root.addSubview(banner)
panel.contentView = root

// Slide in from the right, like macOS banners.
banner.setOffset(44)
banner.layer?.opacity = 0
panel.orderFrontRegardless()
banner.animate(to: 0, opacity: 1, duration: 0.45, timing: easeOut)
banner.scheduleHide(after: seconds)

// Hover by polling the pointer (see the activation policy note above).
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
  guard !banner.closing, let win = banner.window else { return }
  let card = win.convertToScreen(banner.convert(banner.bounds, to: nil))
  if card.contains(NSEvent.mouseLocation) { banner.pointerEntered() } else { banner.pointerLeft() }
}

// Last-resort safety net: a swipe with no event for 4 s counts as finished.
// It has to be long: a finger resting mid-swipe sends no events at all, and
// the real end of the gesture is caught by the global monitor anyway.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
  if banner.tracking, !banner.closing, Date().timeIntervalSince(banner.lastScroll) > 4 { banner.finishSwipe() }
}
// Manual check: AGENT_NOTIFY_FAKE_SWIPE=120 (or 20) fakes a slow swipe of that
// many points whose end never arrives; after 4 s, 120 must close, 20 must snap back.
if let fake = ProcessInfo.processInfo.environment["AGENT_NOTIFY_FAKE_SWIPE"], let pts = Double(fake) {
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    banner.tracking = true
    banner.swipe = CGFloat(pts)
    banner.lastScroll = Date()
    banner.setOffset(CGFloat(pts))
  }
}

// Test hook: AGENT_NOTIFY_SIM=<pattern> replays a trackpad swipe (began,
// changed…, ended) through the swipe code at ~120 events/s with fractional
// deltas like a real trackpad. Patterns: slow, slowfar, pause, back, jitter.
if let pattern = ProcessInfo.processInfo.environment["AGENT_NOTIFY_SIM"] {
  // (seconds from start, rightward points) for each event.
  var steps: [(TimeInterval, CGFloat)] = []
  func run(_ from: TimeInterval, _ secs: TimeInterval, _ speed: CGFloat, jitter: Bool = false) -> TimeInterval {
    var t = from
    while t < from + secs {
      let dt = jitter ? TimeInterval.random(in: 0.005...0.022) : 1.0 / 120
      steps.append((t, speed * CGFloat(dt) * (jitter ? CGFloat.random(in: 0.4...1.6) : 1)))
      t += dt
    }
    return t
  }
  switch pattern {
  case "slow": _ = run(0, 2, 30)
  case "slowfar": _ = run(0, 3, 50)
  case "pause": let t = run(0, 1, 40); _ = run(t + 0.6, 1, 40)
  case "back": let t = run(0, 1.5, 40); _ = run(t, 1.5, -40)
  default: _ = run(0, 2, 40, jitter: true)
  }
  func send(_ dx: CGFloat, _ phase: Int) {
    banner.drag(dx, began: phase == 1, ended: phase == 4, time: ProcessInfo.processInfo.systemUptime)
  }
  // A thread with a precise clock feeds the main thread; asyncAfter timers get
  // coalesced by macOS into ~60 ms bursts, which a real trackpad never does.
  Thread.detachNewThread {
    let t0 = ProcessInfo.processInfo.systemUptime + 0.8
    for (i, step) in steps.enumerated() {
      let wait = t0 + step.0 - ProcessInfo.processInfo.systemUptime
      if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
      DispatchQueue.main.async { send(step.1, i == 0 ? 1 : 2) }
    }
    usleep(10_000)
    DispatchQueue.main.async { send(0, 4) }
  }
}

// Move up one step when the slot right above is free, so the stack closes a
// gap in order (a banner never jumps past another). Not while you are pointing
// at this one or swiping it.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
  guard slot > 0, !banner.closing, !banner.tracking, banner.close.isHidden, claim(slot - 1) else { return }
  unlink(slotFile)
  slot -= 1
  slotFile = "\(slotDir)/\(slot)"
  home = frame(forSlot: slot)
  NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.35
    ctx.timingFunction = easeOut
    panel.animator().setFrame(windowFrame(home), display: true)
  }
}
app.run()
