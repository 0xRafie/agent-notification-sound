// Glass notification banner with a class-colored tint, drawn top-right.
// It never takes focus, ignores the mouse and fades out after a few seconds.
// Usage: notify-overlay <class> <title> <message> [icon] [slot]
//   class  done | progress | question | failed | quiet
//   icon   claude (icons/claude.png), or a path to an .app or image file
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
  if iconArg == "claude" {
    let repo = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    if let img = NSImage(contentsOf: repo.appendingPathComponent("icons/claude.png")) { return img }
  }
  if iconArg.hasSuffix(".app"), fm.fileExists(atPath: iconArg) { return NSWorkspace.shared.icon(forFile: iconArg) }
  if fm.fileExists(atPath: iconArg), let img = NSImage(contentsOfFile: iconArg) { return img }
  return sparkIcon(size: size)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let w: CGFloat = 356, h: CGFloat = 64, margin: CGFloat = 14, radius: CGFloat = 22
let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
let frame = NSRect(x: screen.maxX - w - margin, y: screen.maxY - margin - h - slot * (h + 8), width: w, height: h)

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

// Content: icon, bold title, message. Text colors follow light/dark mode.
// The class color is a thin wash over the glass (NSGlassEffectView.tintColor barely shows).
let tintAlpha: CGFloat = 0.22
let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
content.wantsLayer = true
content.layer?.backgroundColor = tint.withAlphaComponent(tintAlpha).cgColor
content.layer?.cornerRadius = radius
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

if #available(macOS 26.0, *) {
  let glass = NSGlassEffectView(frame: content.frame)
  glass.cornerRadius = radius
  glass.contentView = content
  panel.contentView = glass
} else {
  let blur = NSVisualEffectView(frame: content.frame)
  blur.material = .hudWindow
  blur.blendingMode = .behindWindow
  blur.state = .active
  blur.wantsLayer = true
  blur.layer?.cornerRadius = radius
  blur.layer?.masksToBounds = true
  blur.addSubview(content)
  panel.contentView = blur
}

panel.alphaValue = 0
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
  NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                       completionHandler: { app.terminate(nil) })
}
app.run()
