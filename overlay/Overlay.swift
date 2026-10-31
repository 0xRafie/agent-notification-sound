// Glass notification banner with a class-colored tint, drawn top-right.
// Behaves like a macOS banner: never takes focus, fades out after a few seconds,
// stays while the pointer is over it (with a close button), and closes on click
// or a two-finger swipe to the right.
// Usage: notify-overlay <class> <title> <message> [icon] [slot]
//   class  done | progress | question | failed | quiet
//   icon   a name from icons/ (claude, omp), or a path to an .app or image file
//   slot   0, 1, 2 … stacks banners when several are on screen at once
// Built by install.sh into bin/notify-overlay (needs macOS 26 for Liquid Glass;
// older macOS falls back to a blurred material).
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
  FileHandle.standardError.write("usage: notify-overlay <class> <title> <message> [icon] [slot]\n".data(using: .utf8)!)
  exit(2)
}
let cls = args[1], title = args[2], message = args[3]
let iconArg = args.count > 4 ? args[4] : "claude"
let slot = CGFloat(args.count > 5 ? Int(args[5]) ?? 0 : 0)

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
  if !iconArg.contains("/") { // a name: icons/<name>.png in this repo
    let repo = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    if let img = NSImage(contentsOf: repo.appendingPathComponent("icons/\(iconArg).png")) { return img }
  }
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

let w: CGFloat = 356, h: CGFloat = 64, margin: CGFloat = 14, radius: CGFloat = 22
let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
let home = NSRect(x: screen.maxX - w - margin, y: screen.maxY - margin - h - slot * (h + 8), width: w, height: h)

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
    }, completionHandler: { app.terminate(nil) })
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
app.run()
