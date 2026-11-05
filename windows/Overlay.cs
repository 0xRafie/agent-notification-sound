// Notification banner for Windows, the counterpart of overlay/Overlay.swift: the
// agent's icon, a bold title and the message on a card tinted by class, in the
// bottom-right corner above the taskbar, where Windows shows its own
// notifications. It never takes focus, stays while the pointer is over it (with
// a close button), closes on click or when dragged to the right, and stacks with
// the other banners. In "auto" mode it fades out after a few seconds; in
// "sticky" mode it stays until you close it. It also plays the class sound, so
// a notification costs one process.
//
// Usage: notify-overlay <class> <title> <message> [icon] [auto|sticky] [sound.wav]
//        notify-overlay --play <sound.wav>        (only the sound; omp/ uses it)
//   class  done | progress | question | failed | quiet
//   icon   a .png, .jpg or .ico file, or an .exe whose icon to show; else a spark
//
// install.sh compiles it with the C# compiler that ships with Windows (.NET
// Framework 4), which only knows C# 5, so this file sticks to C# 5:
//   csc -target:winexe -r:System.Windows.Forms.dll -r:System.Drawing.dll Overlay.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program {
  static readonly Stopwatch clock = Stopwatch.StartNew();
  public static long Now() { return clock.ElapsedMilliseconds; }

  [STAThread]
  static int Main(string[] args) {
    // Never show the .NET crash dialog: it would take focus. Exit quietly instead.
    AppDomain.CurrentDomain.UnhandledException += delegate { Environment.Exit(1); };
    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
    try {
      if (args.Length >= 2 && args[0] == "--play") { Play(args[1]); return 0; }
      if (args.Length < 3) return 2; // a GUI program has no console for a usage line
      string icon = args.Length > 3 ? args[3] : "";
      bool sticky = args.Length > 4 && args[4] == "sticky";
      string sound = args.Length > 5 ? args[5] : "";
      Native.SetProcessDPIAware();
      if (sound != "") {
        // A foreground thread, so the sound plays to the end even when the
        // banner is closed first.
        new Thread(delegate () { Play(sound); }).Start();
      }
      Application.Run(new Banner(args[0], args[1], args[2], icon, sticky));
      return 0;
    } catch {
      return 1;
    }
  }

  static void Play(string path) {
    try { using (var player = new SoundPlayer(path)) player.PlaySync(); } catch { }
  }
}

/// A value that eases from where it is now to a target (ease-out, like the macOS banner).
sealed class Tween {
  double from, to, ms;
  long start;
  public void Set(double v) { from = to = v; ms = 0; }
  public void To(double v, double duration) {
    long now = Program.Now();
    from = At(now); to = v; start = now; ms = duration;
  }
  public double At(long now) {
    if (ms <= 0) return to;
    double t = Math.Min(1, (now - start) / ms);
    return from + (to - from) * (1 - Math.Pow(1 - t, 3));
  }
  public bool Done(long now) { return ms <= 0 || now - start >= ms; }
}

sealed class Banner : Form {
  // Same class colors as overlay/Overlay.swift.
  static readonly Dictionary<string, Color> Tints = new Dictionary<string, Color> {
    { "done", Color.FromArgb(48, 199, 92) },
    { "progress", Color.FromArgb(255, 158, 10) },
    { "question", Color.FromArgb(10, 133, 255) },
    { "failed", Color.FromArgb(255, 59, 48) },
    { "quiet", Color.FromArgb(143, 143, 148) },
  };

  readonly bool sticky, quiet;
  readonly float s;              // display scale, 1 at 96 dpi
  readonly int W, H, pad, margin, gap;
  readonly Rectangle work;       // the primary screen minus the taskbar
  readonly Size frameSize;       // the card plus room for its shadow
  readonly IntPtr[] cards = new IntPtr[2]; // rendered card: [0] plain, [1] with the close button

  // Slots (0 = bottom) keep stacked banners from overlapping, even when several
  // start at once: each banner holds a named mutex for its slot until it exits,
  // and Windows frees the mutex of a process that died. When a banner below
  // closes, the ones above move down into the gap.
  int slot;
  Mutex slotLock;

  // The card's offset right of its place (dragging), its top edge, its opacity.
  readonly Tween offset = new Tween(), top = new Tween(), alpha = new Tween();
  readonly System.Windows.Forms.Timer frame = new System.Windows.Forms.Timer();
  readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer();
  readonly System.Windows.Forms.Timer hide = new System.Windows.Forms.Timer();
  bool hovering, closing, pressed, dragged, dirty;
  int pressX, polls;
  double pressOffset;
  readonly List<KeyValuePair<long, double>> samples = new List<KeyValuePair<long, double>>();

  public Banner(string cls, string title, string message, string iconArg, bool sticky) {
    this.sticky = sticky;
    quiet = cls == "quiet";
    using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) s = g.DpiX / 96f;
    W = Px(356); H = Px(64); pad = Px(16); margin = Px(12); gap = Px(8);
    work = Screen.PrimaryScreen.WorkingArea;
    frameSize = new Size(W + 2 * pad, H + 2 * pad);

    Color tint;
    if (!Tints.TryGetValue(cls, out tint)) tint = Tints["quiet"];
    bool dark = IsDark();
    using (Image icon = LoadIcon(iconArg, Px(38))) {
      for (int i = 0; i < 2; i++) {
        using (Bitmap card = Render(tint, dark, icon, title, message, i == 1)) cards[i] = Native.Select(card);
      }
    }

    slot = ClaimFreeSlot();
    top.Set(SlotTop(slot));
    offset.Set(Px(48));
    alpha.Set(0);

    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    StartPosition = FormStartPosition.Manual;
    AutoScaleMode = AutoScaleMode.None;
    Bounds = new Rectangle(WindowPos(Program.Now()), frameSize);

    frame.Interval = 15;
    frame.Tick += delegate { Step(); };
    poll.Interval = 50;
    poll.Tick += delegate { Poll(); };
    hide.Tick += delegate { hide.Stop(); Dismiss(false); };
  }

  int Px(float v) { return (int)Math.Round(v * s); }

  // Topmost, no taskbar button, never activated, drawn with per-pixel alpha.
  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
      return cp;
    }
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void WndProc(ref Message m) {
    // A click must not activate the banner, or your typing would land here.
    if (m.Msg == Native.WM_MOUSEACTIVATE) { m.Result = (IntPtr)Native.MA_NOACTIVATE; return; }
    base.WndProc(ref m);
  }

  protected override void OnHandleCreated(EventArgs e) {
    base.OnHandleCreated(e);
    Present(Program.Now());
  }

  protected override void OnShown(EventArgs e) {
    base.OnShown(e);
    offset.To(0, 320);   // glide in from the right
    alpha.To(1, 220);
    frame.Start();
    poll.Start();
    ScheduleHide(quiet ? 3500 : 5000);
  }

  void ScheduleHide(int ms) {
    hide.Stop();
    if (sticky || closing) return;
    hide.Interval = ms;
    hide.Start();
  }

  void Dismiss(bool slide) {
    if (closing) return;
    closing = true;
    hide.Stop();
    if (slide) offset.To(W + pad + margin, 240);
    alpha.To(0, slide ? 240 : 200);
  }

  void Step() {
    long now = Program.Now();
    bool moving = !(offset.Done(now) && top.Done(now) && alpha.Done(now));
    if (moving || dirty) Present(now);
    if (closing && !moving) {
      frame.Stop();
      poll.Stop();
      ReleaseSlot();
      Close();
    }
  }

  void Poll() {
    if (closing) return;
    long now = Program.Now();
    // Hover is polled: the banner is never active, and a dragged card moves under the pointer.
    bool over = CardRect(now).Contains(Cursor.Position);
    if (over != hovering) {
      hovering = over;
      dirty = true;
      if (over) hide.Stop();
      else if (!pressed) ScheduleHide(2500);
    }
    // A few times a second: move down into a slot that freed up below.
    if (++polls % 5 == 0 && !pressed) {
      for (int i = 0; i < slot; i++) {
        Mutex m = Claim(i);
        if (m == null) continue;
        ReleaseSlot();
        slotLock = m;
        slot = i;
        top.To(SlotTop(i), 300);
        break;
      }
    }
  }

  // Click: close. Drag: the card follows the pointer to the right (a little
  // resistance to the left); a far drag or a quick flick closes it, anything
  // else snaps back.
  protected override void OnMouseDown(MouseEventArgs e) {
    if (e.Button != MouseButtons.Left || closing) return;
    pressed = true;
    dragged = false;
    pressX = Cursor.Position.X;
    pressOffset = offset.At(Program.Now());
    samples.Clear();
    hide.Stop();
  }

  protected override void OnMouseMove(MouseEventArgs e) {
    if (!pressed) return;
    int dx = Cursor.Position.X - pressX;
    if (!dragged && Math.Abs(dx) < Px(4)) return;
    dragged = true;
    long now = Program.Now();
    offset.Set(pressOffset + dx);
    samples.Add(new KeyValuePair<long, double>(now, pressOffset + dx));
    while (samples.Count > 2 && now - samples[0].Key > 100) samples.RemoveAt(0);
    Present(now);
  }

  protected override void OnMouseUp(MouseEventArgs e) {
    if (!pressed) return;
    pressed = false;
    long now = Program.Now();
    if (!dragged) {
      if (CardRect(now).Contains(Cursor.Position)) Dismiss(false);
      return;
    }
    double x = offset.At(now), speed = 0; // px per ms
    if (samples.Count > 1) {
      KeyValuePair<long, double> a = samples[0], b = samples[samples.Count - 1];
      if (b.Key > a.Key) speed = (b.Value - a.Value) / (b.Key - a.Key);
    }
    if (x > W * 0.35 || speed > 0.8 * s) {
      Dismiss(true);
    } else {
      offset.To(0, 260);
      if (!hovering) ScheduleHide(2500);
    }
  }

  // Geometry, in physical pixels (the process is DPI aware).
  int HomeLeft() { return work.Right - margin - W; }
  int SlotTop(int i) { return work.Bottom - margin - H - i * (H + gap); }
  int MaxSlot() { return Math.Max(0, (work.Height - margin) / (H + gap) - 1); }
  double Slid(double x) { return x >= 0 ? x : Math.Max(-Px(14), x * 0.25); }

  Rectangle CardRect(long now) {
    return new Rectangle((int)Math.Round(HomeLeft() + Slid(offset.At(now))), (int)Math.Round(top.At(now)), W, H);
  }

  Point WindowPos(long now) {
    Rectangle card = CardRect(now);
    return new Point(card.X - pad, card.Y - pad);
  }

  void Present(long now) {
    double shown = Slid(offset.At(now));
    double fade = 1 - Math.Min(1, Math.Max(0, shown) / W) * 0.8;
    double a = Math.Max(0, Math.Min(1, alpha.At(now) * fade));
    Native.Update(Handle, cards[hovering ? 1 : 0], WindowPos(now), frameSize, (byte)Math.Round(255 * a));
    dirty = false;
  }

  static Mutex Claim(int i) {
    var m = new Mutex(false, "Local\\AgentNotify.Slot" + i);
    bool got;
    try { got = m.WaitOne(0); } catch (AbandonedMutexException) { got = true; }
    if (got) return m;
    m.Dispose();
    return null;
  }

  int ClaimFreeSlot() {
    int max = MaxSlot();
    for (int i = 0; i <= max; i++) {
      Mutex m = Claim(i);
      if (m != null) { slotLock = m; return i; }
    }
    return max;
  }

  void ReleaseSlot() {
    if (slotLock == null) return;
    try { slotLock.ReleaseMutex(); } catch { }
    slotLock.Dispose();
    slotLock = null;
  }

  // Windows notifications follow the system theme ("Choose your default Windows mode").
  static bool IsDark() {
    try {
      object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 1);
      return v is int && (int)v == 0;
    } catch {
      return false;
    }
  }

  Bitmap Render(Color tint, bool dark, Image icon, string title, string message, bool withClose) {
    var bmp = new Bitmap(frameSize.Width, frameSize.Height, PixelFormat.Format32bppArgb);
    using (Graphics g = Graphics.FromImage(bmp)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.InterpolationMode = InterpolationMode.HighQualityBicubic;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      g.CompositingQuality = CompositingQuality.HighQuality;
      g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit; // ClearType needs an opaque window
      var card = new RectangleF(pad, pad, W, H);
      float radius = Px(8);
      Color fill = dark ? Color.FromArgb(44, 44, 44) : Color.FromArgb(249, 249, 249);

      // Soft shadow, a little lower than the card: rings that add up to about
      // 22% black at its edge.
      int ringAlpha = Math.Max(1, (int)Math.Round(255 * (1 - Math.Pow(0.78, 1.0 / pad))));
      using (var b = new SolidBrush(Color.FromArgb(ringAlpha, 0, 0, 0))) {
        for (int i = pad; i >= 1; i--) {
          RectangleF ring = card;
          ring.Inflate(i, i);
          ring.Offset(0, Px(3));
          using (GraphicsPath p = RoundRect(ring, radius + i)) g.FillPath(b, p);
        }
      }

      // The class color fades from the icon side to almost clear on the right.
      using (GraphicsPath path = RoundRect(card, radius)) {
        using (var b = new SolidBrush(fill)) g.FillPath(b, path);
        RectangleF wash = card;
        wash.Inflate(1, 0);
        using (var b = new LinearGradientBrush(wash, Color.FromArgb(115, tint), Color.FromArgb(10, tint), LinearGradientMode.Horizontal)) g.FillPath(b, path);
        using (var pen = new Pen(dark ? Color.FromArgb(30, 255, 255, 255) : Color.FromArgb(24, 0, 0, 0), 1)) g.DrawPath(pen, path);
      }

      float iconSize = Px(38), iconX = pad + Px(13);
      g.DrawImage(icon, iconX, pad + (H - iconSize) / 2f, iconSize, iconSize);

      float closeSize = Px(16), textX = iconX + iconSize + Px(11), textW = pad + W - textX - Px(14);
      using (var fmt = new StringFormat(StringFormatFlags.NoWrap))
      using (var titleFont = new Font("Segoe UI Semibold", 13 * s, FontStyle.Regular, GraphicsUnit.Pixel))
      using (var textFont = new Font("Segoe UI", 13 * s, FontStyle.Regular, GraphicsUnit.Pixel))
      using (var titleBrush = new SolidBrush(dark ? Color.White : Color.FromArgb(26, 26, 26)))
      using (var textBrush = new SolidBrush(dark ? Color.FromArgb(210, 255, 255, 255) : Color.FromArgb(160, 0, 0, 0))) {
        fmt.Trimming = StringTrimming.EllipsisCharacter;
        g.DrawString(title, titleFont, titleBrush, new RectangleF(textX, pad + Px(12), textW - closeSize, Px(19)), fmt);
        g.DrawString(message, textFont, textBrush, new RectangleF(textX, pad + Px(32), textW, Px(19)), fmt);
      }

      if (withClose) {
        float x = pad + W - closeSize - Px(7), y = pad + Px(7), k = closeSize * 0.32f;
        using (var b = new SolidBrush(dark ? Color.FromArgb(150, 255, 255, 255) : Color.FromArgb(115, 0, 0, 0))) g.FillEllipse(b, x, y, closeSize, closeSize);
        using (var pen = new Pen(fill, Math.Max(1.5f, 1.4f * s))) {
          g.DrawLine(pen, x + k, y + k, x + closeSize - k, y + closeSize - k);
          g.DrawLine(pen, x + closeSize - k, y + k, x + k, y + closeSize - k);
        }
      }
    }
    return bmp;
  }

  static Image LoadIcon(string path, int size) {
    try {
      if (path != "" && File.Exists(path)) {
        string ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".exe") { using (Icon ic = Icon.ExtractAssociatedIcon(path)) return ic.ToBitmap(); }
        if (ext == ".ico") { using (var ic = new Icon(path, size, size)) return ic.ToBitmap(); }
        using (FileStream fs = File.OpenRead(path))
        using (Image img = Image.FromStream(fs)) return new Bitmap(img);
      }
    } catch { }
    return Spark(size);
  }

  /// Orange rounded square with an eight-ray spark, used when no icon is given.
  static Bitmap Spark(int size) {
    var b = new Bitmap(size, size, PixelFormat.Format32bppArgb);
    using (Graphics g = Graphics.FromImage(b)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      using (GraphicsPath p = RoundRect(new RectangleF(0, 0, size, size), size * 0.23f))
      using (var br = new SolidBrush(Color.FromArgb(217, 120, 87))) g.FillPath(br, p);
      float len = size * 0.27f, w = size * 0.075f;
      for (int i = 0; i < 8; i++) {
        GraphicsState state = g.Save();
        g.TranslateTransform(size / 2f, size / 2f);
        g.RotateTransform(i * 45);
        using (GraphicsPath ray = RoundRect(new RectangleF(-w / 2, size * 0.05f, w, len), w / 2)) g.FillPath(Brushes.White, ray);
        g.Restore(state);
      }
    }
    return b;
  }

  static GraphicsPath RoundRect(RectangleF r, float radius) {
    float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
    var p = new GraphicsPath();
    p.AddArc(r.X, r.Y, d, d, 180, 90);
    p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
    p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
    p.CloseFigure();
    return p;
  }
}

static class Native {
  public const int WS_EX_TOPMOST = 0x8, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
  public const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
  const int ULW_ALPHA = 2;
  const byte AC_SRC_OVER = 0, AC_SRC_ALPHA = 1;

  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct SIZE { public int CX, CY; }
  [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
  [DllImport("user32.dll")]
  static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr dst, ref POINT ptDst, ref SIZE size, IntPtr src, ref POINT ptSrc, int key, ref BLENDFUNCTION blend, int flags);

  /// A memory DC holding a premultiplied copy of the bitmap, for Update.
  public static IntPtr Select(Bitmap b) {
    IntPtr screen = GetDC(IntPtr.Zero);
    IntPtr dc = CreateCompatibleDC(screen);
    ReleaseDC(IntPtr.Zero, screen);
    SelectObject(dc, b.GetHbitmap(Color.FromArgb(0)));
    return dc;
  }

  /// Shows the card from `src` at `pos` with an overall opacity.
  public static void Update(IntPtr hwnd, IntPtr src, Point pos, Size size, byte alpha) {
    IntPtr screen = GetDC(IntPtr.Zero);
    var dst = new POINT { X = pos.X, Y = pos.Y };
    var sz = new SIZE { CX = size.Width, CY = size.Height };
    var origin = new POINT();
    var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
    UpdateLayeredWindow(hwnd, screen, ref dst, ref sz, src, ref origin, 0, ref blend, ULW_ALPHA);
    ReleaseDC(IntPtr.Zero, screen);
  }
}
