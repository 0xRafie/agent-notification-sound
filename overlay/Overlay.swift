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
// Launch as .prohibited so macOS doesn't activate the banner and pull keyboard
// focus away from your app (.accessory at launch did, for ~3 s). Switch to
// .accessory once running: that doesn't activate it, and hover events need it.
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { app.setActivationPolicy(.accessory) }

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

let panel = NSPanel(contentRect: home, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.becomesKeyOnlyIfNeeded = true
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

/// Takes every click, hover and swipe on the banner; the icon and labels don't.
final class BannerView: NSView {
  let close = NSButton()
  var hideWork: DispatchWorkItem?
  var swipe: CGFloat = 0
  var closing = false

  override init(frame: NSRect) {
    super.init(frame: frame)
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
  override func mouseEntered(with event: NSEvent) { hideWork?.cancel(); close.isHidden = false }
  override func mouseExited(with event: NSEvent) { close.isHidden = true; scheduleHide(after: 2.5) }
  override func mouseUp(with event: NSEvent) { dismiss(slide: false) }
  @objc func closeClicked() { dismiss(slide: false) }

  // Trackpad: the banner follows a two-finger swipe to the right; far enough
  // closes it, otherwise it snaps back. Mice without gesture phases: enough
  // rightward scrolling within half a second closes it.
  var lastWheel = Date.distantPast
  override func scrollWheel(with event: NSEvent) {
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
    if event.phase.contains(.began) { swipe = 0 }
    swipe = max(0, swipe + dx)
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      if swipe > 50 { dismiss(slide: true) } else {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window?.animator().setFrame(home, display: true) }
      }
      swipe = 0
    } else {
      window?.setFrameOrigin(NSPoint(x: home.minX + swipe, y: home.minY))
    }
  }

  func dismiss(slide: Bool) {
    guard !closing else { return }
    closing = true
    hideWork?.cancel()
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = slide ? 0.25 : 0.4
      window?.animator().alphaValue = 0
      if slide { window?.animator().setFrameOrigin(NSPoint(x: screen.maxX + 20, y: home.minY)) }
    }, completionHandler: { self.window?.orderOut(nil); quit() })
  }
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

let banner = BannerView(frame: content.frame)
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
panel.contentView = banner

panel.alphaValue = 0
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
banner.scheduleHide(after: seconds)

// Move up one step when the slot right above is free, so the stack closes a
// gap in order (a banner never jumps past another). Not while you are pointing
// at this one or swiping it.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
  guard slot > 0, !banner.closing, banner.swipe == 0, banner.close.isHidden, claim(slot - 1) else { return }
  unlink(slotFile)
  slot -= 1
  slotFile = "\(slotDir)/\(slot)"
  home = frame(forSlot: slot)
  NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().setFrame(home, display: true) }
}
app.run()
