// computer-use-mcp (Windows): automation worker.
//
// A long-lived helper the Node MCP server talks to: one JSON request per line on stdin, one JSON
// response per line on stdout. All UI Automation, capture and input work happens here, in compiled
// code, so a screenshot walks the accessibility tree with one cross-process call per expanded node.
//
//   in : {"id":<n>,"op":"<name>","args":{...}}
//   out: {"id":<n>,"ok":true,"result":{...}}  |  {"id":<n>,"ok":false,"error":"..."}
//   out: {"event":"ready","version":"..."} once at startup.
//
// It is compiled on demand with the C# compiler that ships with .NET Framework 4 (C# 5), so no SDK is
// needed: keep the syntax to C# 5 (no string interpolation, no ?. and no expression-bodied members).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;

namespace ComputerUse
{
    static class N
    {
        public delegate bool EnumProc(IntPtr h, IntPtr l);

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }

        [StructLayout(LayoutKind.Sequential)]
        public struct GUITHREADINFO
        {
            public int cbSize, flags;
            public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
            public RECT rcCaret;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WINDOWPLACEMENT { public int length, flags, showCmd; public POINT ptMin, ptMax; public RECT rcNormal; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct SHELLEXECUTEINFO
        {
            public int cbSize; public uint fMask; public IntPtr hwnd;
            public string lpVerb, lpFile, lpParameters, lpDirectory;
            public int nShow; public IntPtr hInstApp, lpIDList; public string lpClass;
            public IntPtr hkeyClass; public uint dwHotKey; public IntPtr hIcon, hProcess;
        }

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
        [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, out int w, out int l);
        [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsGUIThread(bool convert);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
        [DllImport("user32.dll")] public static extern IntPtr ChildWindowFromPointEx(IntPtr parent, POINT p, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong32(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] s);
        [DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] s);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScan(char c);
        [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr m, int pos);
        [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr m);
        [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr m, int pos);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr m, uint item, StringBuilder s, int max, uint flags);
        [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr m, uint item, uint flags);
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder s, ref int size);
        [DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
        [DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr t, int cls, out int info, int len, out int ret);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT v, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool ShellExecuteEx(ref SHELLEXECUTEINFO i);
        [DllImport("kernel32.dll")] public static extern int GetProcessId(IntPtr h);

        public static long GetWindowLong(IntPtr h, int i)
        {
            return IntPtr.Size == 8 ? GetWindowLongPtr64(h, i).ToInt64() : GetWindowLong32(h, i);
        }

        public static IntPtr LParam(long v)
        {
            return IntPtr.Size == 8 ? new IntPtr(v) : new IntPtr(unchecked((int)v));
        }

        public static IntPtr MakeLParam(int lo, int hi)
        {
            return LParam(((long)(hi & 0xFFFF) << 16) | (long)(lo & 0xFFFF));
        }

        public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        public const long WS_EX_TOOLWINDOW = 0x80, WS_DISABLED = 0x08000000;
        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14;
        public const uint GA_ROOT = 2;
        public const uint CWP_SKIPINVISIBLE = 1, CWP_SKIPTRANSPARENT = 4;
        public const uint WM_NULL = 0, WM_SETTEXT = 0x0C, WM_GETTEXTLENGTH = 0x0E, WM_COMMAND = 0x111, WM_INITMENUPOPUP = 0x117;
        public const uint WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_CHAR = 0x102, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
        public const uint WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_LBUTTONDBLCLK = 0x203;
        public const uint WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205, WM_RBUTTONDBLCLK = 0x206;
        public const uint WM_MBUTTONDOWN = 0x207, WM_MBUTTONUP = 0x208, WM_MBUTTONDBLCLK = 0x209;
        public const uint WM_MOUSEWHEEL = 0x20A, WM_MOUSEHWHEEL = 0x20E;
        public const uint WM_CUT = 0x300, WM_COPY = 0x301, WM_PASTE = 0x302, WM_UNDO = 0x304;
        public const uint EM_GETSEL = 0xB0, EM_SETSEL = 0xB1, EM_SCROLLCARET = 0xB7, EM_REPLACESEL = 0xC2, EM_REDO = 0x454;
        public const uint MK_LBUTTON = 1, MK_RBUTTON = 2, MK_SHIFT = 4, MK_CONTROL = 8, MK_MBUTTON = 0x10;
        public const uint MF_BYPOSITION = 0x400, MF_GRAYED = 1, MF_DISABLED = 2, MF_CHECKED = 8, MF_POPUP = 0x10, MF_SEPARATOR = 0x800;
        public const uint SMTO_ABORTIFHUNG = 2;
        public const int VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B;
        public const int VK_LSHIFT = 0xA0, VK_LCONTROL = 0xA2, VK_LMENU = 0xA4;

        // Phantom cursor (layered window)
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref POINT pt, ref SIZE size, IntPtr src, ref POINT srcPt, uint key, ref BLENDFUNCTION blend, uint flags);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
        [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dpiX, out uint dpiY);
    }

    class Fail : Exception
    {
        public Fail(string m) : base(m) { }
    }

    class Win
    {
        public IntPtr H;
        public int Pid;
        public string Title = "", Cls = "";
        public Rectangle R;
        public bool Minimized, Active;
    }

    /// One accessibility element as seen in a screenshot (screen coordinates).
    class El
    {
        public AutomationElement A;
        public El Parent;
        public int Depth;
        public Rectangle Clip;   // visible area: the window, narrowed by every scrolling ancestor
        public string Kind = "", Label = "", Value, AutoId = "", Cls = "";
        public Rectangle R;
        public bool Enabled = true, Focused, Password, Offscreen;
        public IntPtr OwnHwnd, Hwnd;
        public bool CanInvoke, CanToggle, CanSelect, CanExpand, CanValue, ValueReadOnly = true, CanScroll, CanRange;
        public bool Actionable;
        public bool Fetched;

        public string Title
        {
            get
            {
                if (Label.Length > 0) return Label;
                if (AutoId.Length > 0 && !AutoId.All(char.IsDigit)) return "#" + AutoId;
                return "";
            }
        }
    }

    class Snapshot
    {
        public IntPtr H;
        public Rectangle Frame;
        public List<El> All = new List<El>();
        public List<El> Elements = new List<El>();
        public List<El> Texts = new List<El>();
        public int Visited;
        public bool Truncated;
        public List<string> Errors = new List<string>();
        public long Ms;
    }

    class Target
    {
        public El E;
        public Win W;
        public Point P;
        public bool HasPoint;
        public string How = "";
    }

    /// The floating agent cursor, as on macOS: a violet arrow that glides to each action's point, gives a
    /// click a press and a ripple, and stays until hide_cursor (or phantom_cursor_idle_ms). It is a
    /// layered, click-through, never-activated topmost window on its own UI thread, so it neither takes
    /// focus nor intercepts the user's mouse.
    static class Phantom
    {
        const int BaseSize = 80;   // window size at 96 dpi; the arrow tip (hotspot) is its center
        static readonly bool Disabled = Environment.GetEnvironmentVariable("COMPUTER_USE_NO_CURSOR") == "1";
        static readonly object Gate = new object();
        static readonly Stopwatch Clock = Stopwatch.StartNew();
        static System.Windows.Forms.Control ui;
        static Overlay win;
        static System.Windows.Forms.Timer frameTimer, idleTimer;
        static Point? last;          // last target, for the glide duration (worker thread)
        static volatile bool visible;

        // Animation state, touched only on the UI thread.
        static PointF from, to, cur;
        static double glideStart, glideMs, alphaFrom, alpha;
        static double pulseStart = -1, dismissStart, dismissFrom;
        static bool pulsePending, dismissing;
        static int idleMs;

        class Overlay : System.Windows.Forms.NativeWindow
        {
            public Overlay()
            {
                var cp = new System.Windows.Forms.CreateParams();
                cp.Style = unchecked((int)0x80000000);                  // WS_POPUP
                cp.ExStyle = 0x80000 | 0x20 | 0x80 | 0x08000000 | 0x8;  // layered, transparent, tool, no-activate, topmost
                cp.Width = 1;
                cp.Height = 1;
                CreateHandle(cp);
            }

            protected override void WndProc(ref System.Windows.Forms.Message m)
            {
                if (m.Msg == 0x84) { m.Result = new IntPtr(-1); return; }   // WM_NCHITTEST -> HTTRANSPARENT
                if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; }    // WM_MOUSEACTIVATE -> MA_NOACTIVATE
                base.WndProc(ref m);
            }
        }

        static double Now() { return Clock.Elapsed.TotalMilliseconds; }

        static void EnsureStarted()
        {
            if (ui != null) return;
            var ready = new ManualResetEvent(false);
            var th = new Thread(() =>
            {
                var c = new System.Windows.Forms.Control();
                var unused = c.Handle;   // BeginInvoke needs the handle
                win = new Overlay();
                frameTimer = new System.Windows.Forms.Timer { Interval = 15 };
                frameTimer.Tick += (s, e) => Frame();
                idleTimer = new System.Windows.Forms.Timer();
                idleTimer.Tick += (s, e) => { idleTimer.Stop(); BeginDismiss(); };
                ui = c;
                ready.Set();
                System.Windows.Forms.Application.Run();
            });
            th.IsBackground = true;
            th.SetApartmentState(ApartmentState.STA);
            th.Start();
            ready.WaitOne();
        }

        /// Glides the cursor to a screen point. Returns the glide time in ms, so the action can wait
        /// for the cursor to arrive before it happens.
        public static int Show(Point p, bool pulse, int idle)
        {
            if (Disabled) return 0;
            EnsureStarted();
            Point? prev;
            lock (Gate) { prev = last; last = p; }
            double dist = prev.HasValue ? Math.Sqrt(Math.Pow(p.X - prev.Value.X, 2) + Math.Pow(p.Y - prev.Value.Y, 2)) / DpiScale(p) : 140;
            int ms = dist < 10 ? 40 : (int)(Math.Min(0.42, Math.Max(0.20, dist / 1600.0)) * 1000);
            visible = true;
            ui.BeginInvoke((Action)(() => Present(p, prev, ms, pulse, idle)));
            return ms;
        }

        /// Fades the cursor out. False when it was not showing.
        public static bool Dismiss()
        {
            if (ui == null || !visible) return false;
            visible = false;
            ui.BeginInvoke((Action)BeginDismiss);
            return true;
        }

        /// Runs a screen copy with the cursor out of the way.
        public static void HiddenDuring(Action act)
        {
            if (ui == null || !visible) { act(); return; }
            ui.Invoke((Action)(() => N.ShowWindow(win.Handle, 0)));
            try { act(); }
            finally { ui.Invoke((Action)(() => { if (visible) N.ShowWindow(win.Handle, 8); })); }   // SW_SHOWNA
        }

        static void Present(Point p, Point? prev, int ms, bool pulse, int idle)
        {
            idleTimer.Stop();
            idleMs = idle;
            if (dismissing || alpha <= 0)
            {
                // Hidden (or fading out): fade in on the way from the previous point.
                if (alpha <= 0)
                {
                    var s = prev ?? new Point(p.X - 40, p.Y + 40);
                    cur = new PointF(s.X, s.Y);
                }
                dismissing = false;
            }
            from = cur;
            to = new PointF(p.X, p.Y);
            alphaFrom = alpha;
            glideStart = Now();
            glideMs = ms;
            pulsePending = pulse;
            frameTimer.Start();
            Frame();
        }

        static void BeginDismiss()
        {
            if (alpha <= 0) return;
            idleTimer.Stop();
            visible = false;
            dismissing = true;
            dismissStart = Now();
            dismissFrom = alpha;
            glideMs = 0;
            pulsePending = false;
            frameTimer.Start();
        }

        /// cubic-bezier(0.22, 1, 0.36, 1): fast start, soft stop, the macOS curve.
        static double Ease(double t)
        {
            double lo = 0, hi = 1, s = t;
            for (int i = 0; i < 24; i++)
            {
                s = (lo + hi) / 2;
                if (Bezier(s, 0.22, 0.36) < t) lo = s; else hi = s;
            }
            return Bezier(s, 1.0, 1.0);
        }

        static double Bezier(double s, double a, double b)
        {
            double u = 1 - s;
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s;
        }

        static void Frame()
        {
            double now = Now();
            bool busy = false;
            if (glideMs > 0)
            {
                double t = Math.Min(1, (now - glideStart) / glideMs);
                double k = Ease(t);
                cur = new PointF((float)(from.X + (to.X - from.X) * k), (float)(from.Y + (to.Y - from.Y) * k));
                alpha = alphaFrom + (1 - alphaFrom) * k;
                if (t >= 1)
                {
                    glideMs = 0;
                    if (pulsePending) { pulsePending = false; pulseStart = now; }
                    if (idleMs > 0) { idleTimer.Interval = idleMs; idleTimer.Start(); }
                }
                busy = true;
            }
            double ringT = -1, press = 1;
            if (pulseStart >= 0)
            {
                double pt = now - pulseStart;
                if (pt < 340) { ringT = pt / 340; busy = true; } else pulseStart = -1;
                if (pt < 220)
                {
                    double u = pt / 220;
                    press = u < 0.38 ? 1 - 0.12 * (u / 0.38) : 0.88 + 0.12 * ((u - 0.38) / 0.62);
                }
            }
            if (dismissing)
            {
                double dt = (now - dismissStart) / 350;
                if (dt >= 1)
                {
                    dismissing = false;
                    alpha = 0;
                    pulseStart = -1;
                    N.ShowWindow(win.Handle, 0);
                    frameTimer.Stop();
                    return;
                }
                alpha = dismissFrom * (1 - dt);
                busy = true;
            }
            try { Render(cur, alpha, ringT, press); } catch { }
            if (!busy) frameTimer.Stop();
        }

        static float DpiScale(Point p)
        {
            try
            {
                IntPtr mon = N.MonitorFromPoint(new N.POINT(p.X, p.Y), 2);
                uint dx, dy;
                if (N.GetDpiForMonitor(mon, 0, out dx, out dy) == 0 && dx > 0) return dx / 96f;
            }
            catch { }
            return 1f;
        }

        static GraphicsPath Arrow()
        {
            // Points relative to the tip, y down (the macOS polygon, flipped).
            var p = new GraphicsPath();
            p.AddPolygon(new[] {
                new PointF(0, 0), new PointF(0, 20), new PointF(4.8f, 15.5f), new PointF(8.2f, 23f),
                new PointF(11.2f, 21.5f), new PointF(7.8f, 14f), new PointF(14f, 14f) });
            return p;
        }

        static void Render(PointF at, double a, double ringT, double press)
        {
            float scale = DpiScale(Point.Round(at));
            int size = (int)Math.Ceiling(BaseSize * scale);
            float hot = size / 2f;
            using (var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    g.TranslateTransform(hot, hot);
                    g.ScaleTransform(scale, scale);
                    if (ringT >= 0)
                    {
                        // Ripple: grows from 0.35 to 1.55 of 19 px while it fades.
                        double e = 1 - (1 - ringT) * (1 - ringT);
                        float r = (float)(19 * (0.35 + 1.2 * e));
                        double fade = 1 - ringT;
                        using (var b = new SolidBrush(Color.FromArgb((int)(64 * fade), 97, 112, 250))) g.FillEllipse(b, -r, -r, 2 * r, 2 * r);
                        using (var pen = new Pen(Color.FromArgb((int)(235 * fade), 122, 140, 255), 2.5f)) g.DrawEllipse(pen, -r, -r, 2 * r, 2 * r);
                    }
                    g.ScaleTransform((float)press, (float)press);
                    using (var path = Arrow())
                    {
                        // Soft shadow: wide, faint strokes slightly below the arrow.
                        g.TranslateTransform(0, 1.5f);
                        for (int i = 4; i >= 1; i--)
                            using (var sp = new Pen(Color.FromArgb(24, 0, 0, 0), 2.4f + i * 2.2f) { LineJoin = LineJoin.Round }) g.DrawPath(sp, path);
                        g.TranslateTransform(0, -1.5f);
                        using (var fill = new SolidBrush(Color.FromArgb(245, 97, 112, 250))) g.FillPath(fill, path);
                        using (var pen = new Pen(Color.White, 2.4f) { LineJoin = LineJoin.Round }) g.DrawPath(pen, path);
                    }
                }
                Push(bmp, new Point((int)Math.Round(at.X - hot), (int)Math.Round(at.Y - hot)), (byte)Math.Round(255 * Math.Max(0, Math.Min(1, a))));
            }
        }

        static void Push(Bitmap bmp, Point dst, byte opacity)
        {
            IntPtr h = win.Handle;
            IntPtr screen = N.GetDC(IntPtr.Zero), mem = N.CreateCompatibleDC(screen);
            IntPtr hb = bmp.GetHbitmap(Color.FromArgb(0)), old = N.SelectObject(mem, hb);
            try
            {
                var size = new N.SIZE { cx = bmp.Width, cy = bmp.Height };
                var src = new N.POINT(0, 0);
                var pt = new N.POINT(dst.X, dst.Y);
                var blend = new N.BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = opacity, AlphaFormat = 1 };
                N.UpdateLayeredWindow(h, screen, ref pt, ref size, mem, ref src, 0, ref blend, 2);   // ULW_ALPHA
                // Stay above other topmost windows, never activated: HWND_TOPMOST, NOSIZE|NOMOVE|NOACTIVATE|SHOWWINDOW.
                N.SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x40);
            }
            finally
            {
                N.SelectObject(mem, old);
                N.DeleteObject(hb);
                N.DeleteDC(mem);
                N.ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }

    static class Program
    {
        const string Version = "0.2.0";
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };
        static readonly Dictionary<long, Snapshot> Snaps = new Dictionary<long, Snapshot>();
        static readonly Dictionary<string, string> Descriptions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        /// Edit controls whose caret the agent has placed (clicked, typed or moved keys in). In the
        /// background no control has system focus, so this stands in for "the field is focused".
        static readonly HashSet<long> Engaged = new HashSet<long>();
        static CacheRequest TreeCR, ElementCR;
        static bool SelfElevated;
        static bool Debug = Environment.GetEnvironmentVariable("COMPUTER_USE_DEBUG") == "1";

        // ------------------------------------------------------------------ main loop

        [MTAThread]
        static int Main(string[] argv)
        {
            try { if (!N.SetProcessDpiAwarenessContext(new IntPtr(-4))) N.SetProcessDPIAware(); }
            catch (EntryPointNotFoundException) { N.SetProcessDPIAware(); }
            if (argv.Length == 2 && argv[0] == "--foreground")
                return N.SetForegroundWindow(new IntPtr(long.Parse(argv[1]))) ? 0 : 1;
            // AttachThreadInput (modifier key state, giving focus back) needs this thread to have an
            // input queue, which a console thread only gets as a GUI thread.
            N.IsGUIThread(true);
            SelfElevated = IsElevated(Process.GetCurrentProcess().Id) == true;
            TreeCR = MakeCacheRequest(TreeScope.Element | TreeScope.Children);
            ElementCR = MakeCacheRequest(TreeScope.Element);

            var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
            stdout.AutoFlush = true;
            stdout.WriteLine(Json.Serialize(O("event", "ready", "version", Version)));

            string line;
            while ((line = stdin.ReadLine()) != null)
            {
                line = line.Trim();
                if (line.Length == 0) continue;
                object id = 0;
                Dictionary<string, object> resp;
                try
                {
                    var req = (Dictionary<string, object>)Json.DeserializeObject(line);
                    id = Get(req, "id") ?? 0;
                    var args = Get(req, "args") as Dictionary<string, object> ?? new Dictionary<string, object>();
                    resp = O("id", id, "ok", true, "result", Handle(Str(Get(req, "op")), args));
                }
                catch (Exception e)
                {
                    resp = O("id", id, "ok", false, "error", Describe(e));
                }
                string text;
                try { text = Json.Serialize(resp); }
                catch (Exception e) { text = Json.Serialize(O("id", id, "ok", false, "error", "could not encode the result: " + e.Message)); }
                stdout.WriteLine(text);
            }
            return 0;
        }

        static string Describe(Exception e)
        {
            if (e is Fail) return e.Message;
            if (e is ElementNotAvailableException) return "the element no longer exists; take a new screenshot";
            if (e is UnauthorizedAccessException) return "access denied (the app may run as administrator; see list_apps)";
            if (e is TimeoutException) return "the app did not respond in time";
            return e.GetType().Name + ": " + e.Message;
        }

        static object Handle(string op, Dictionary<string, object> a)
        {
            switch (op)
            {
                case "ping": return O("version", Version, "elevated", SelfElevated);
                case "list_apps": return OpListApps();
                case "windows": return O("windows", OpWindows(a));
                case "screenshot": return OpScreenshot(a);
                case "click": return OpClick(a);
                case "type": return OpType(a);
                case "key": return OpKey(a);
                case "scroll": return OpScroll(a);
                case "drag": return OpDrag(a);
                case "menu": return OpMenu(a);
                case "zoom": return OpZoom(a);
                case "open": return OpOpen(a);
                case "hide_cursor": return O("shown", Phantom.Dismiss());
                case "debug_tree":
                    {
                        var w = WindowFor(a);
                        var s = Walk(w, (int)(Num(Get(a, "budgetMs")) ?? 1000), 3000);
                        return O("frame", new List<object> { w.R.X, w.R.Y, w.R.Width, w.R.Height }, "errors", s.Errors, "visited", s.Visited,
                            "all", s.All.Select(e => (object)(new string(' ', e.Depth) + e.Kind + " '" + e.Title + "' cls=" + e.Cls + " " + e.R
                                + (e.CanScroll ? " SCROLL" : "") + " clip=" + e.Clip)).ToList());
                    }
                default: throw new Fail("unknown op \"" + op + "\"");
            }
        }

        // ------------------------------------------------------------------ JSON helpers

        static Dictionary<string, object> O(params object[] kv)
        {
            var d = new Dictionary<string, object>();
            for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
            return d;
        }

        static object Get(Dictionary<string, object> d, string k)
        {
            object v;
            return d != null && d.TryGetValue(k, out v) ? v : null;
        }

        static string Str(object o) { return o == null ? "" : Convert.ToString(o, CultureInfo.InvariantCulture); }

        static double? Num(object o)
        {
            if (o == null) return null;
            try { return Convert.ToDouble(o, CultureInfo.InvariantCulture); } catch { return null; }
        }

        static bool Bool(object o) { return o is bool ? (bool)o : (o != null && (Str(o) == "1" || Str(o).ToLowerInvariant() == "true")); }

        static double[] Nums(object o)
        {
            var arr = o as object[];
            if (arr == null) { var list = o as System.Collections.ArrayList; if (list != null) arr = list.ToArray(); }
            if (arr == null) return null;
            var r = new double[arr.Length];
            for (int i = 0; i < arr.Length; i++) { var v = Num(arr[i]); if (v == null) return null; r[i] = v.Value; }
            return r;
        }

        static string[] Strs(object o)
        {
            var arr = o as object[];
            if (arr == null) { var list = o as System.Collections.ArrayList; if (list != null) arr = list.ToArray(); }
            if (arr == null) return null;
            return arr.Select(Str).ToArray();
        }

        static Dictionary<string, object> Result(string status, string text)
        {
            return O("status", status, "text", text);
        }

        // ------------------------------------------------------------------ windows and processes

        static string WindowText(IntPtr h)
        {
            int len = N.GetWindowTextLength(h);
            var sb = new StringBuilder(Math.Max(len + 1, 2));
            N.GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }

        static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            N.GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        static int PidOf(IntPtr h) { uint pid; N.GetWindowThreadProcessId(h, out pid); return (int)pid; }
        static uint TidOf(IntPtr h) { uint pid; return N.GetWindowThreadProcessId(h, out pid); }

        static bool Cloaked(IntPtr h)
        {
            int v;
            try { return N.DwmGetWindowAttribute(h, N.DWMWA_CLOAKED, out v, 4) == 0 && v != 0; } catch { return false; }
        }

        /// The visible frame of a window (without the invisible resize borders), in screen pixels.
        static Rectangle FrameRect(IntPtr h)
        {
            if (N.IsIconic(h))
            {
                var wp = new N.WINDOWPLACEMENT();
                wp.length = Marshal.SizeOf(wp);
                if (N.GetWindowPlacement(h, ref wp))
                    return Rectangle.FromLTRB(wp.rcNormal.Left, wp.rcNormal.Top, wp.rcNormal.Right, wp.rcNormal.Bottom);
            }
            N.RECT r;
            try
            {
                if (N.DwmGetWindowAttribute(h, N.DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(N.RECT))) == 0 && r.Right > r.Left && r.Bottom > r.Top)
                    return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
            }
            catch { }
            if (N.GetWindowRect(h, out r)) return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
            return Rectangle.Empty;
        }

        static List<IntPtr> Children(IntPtr parent)
        {
            var list = new List<IntPtr>();
            N.EnumChildWindows(parent, (h, l) => { list.Add(h); return true; }, IntPtr.Zero);
            return list;
        }

        /// UWP apps draw inside an ApplicationFrameWindow owned by ApplicationFrameHost.exe; the app's own
        /// process owns the CoreWindow child. Windows are attributed to that process.
        static IntPtr CoreWindowOf(IntPtr frame)
        {
            int framePid = PidOf(frame);
            foreach (var c in Children(frame))
                if (ClassOf(c) == "Windows.UI.Core.CoreWindow" && PidOf(c) != framePid) return c;
            return IntPtr.Zero;
        }

        static List<Win> TopWindows(int pidFilter, bool includePopups = false)
        {
            var list = new List<Win>();
            IntPtr fg = N.GetForegroundWindow();
            N.EnumWindows((h, l) =>
            {
                if (!N.IsWindowVisible(h) || Cloaked(h)) return true;
                // Tool windows and no-activate windows (popup hosts, tooltips) are not app windows.
                if (!includePopups && (N.GetWindowLong(h, N.GWL_EXSTYLE) & (N.WS_EX_TOOLWINDOW | 0x08000000L)) != 0) return true;
                bool min = N.IsIconic(h);
                var r = FrameRect(h);
                if (!min && (r.Width < (includePopups ? 8 : 80) || r.Height < (includePopups ? 8 : 40))) return true;
                string cls = ClassOf(h);
                string title = WindowText(h);
                int pid = PidOf(h);
                if (cls == "ApplicationFrameWindow")
                {
                    var core = CoreWindowOf(h);
                    if (core != IntPtr.Zero) pid = PidOf(core);
                    else if (title.Length == 0) return true;
                }
                if (cls == "Windows.UI.Core.CoreWindow" && title.Length == 0) return true;
                if (pidFilter >= 0 && pid != pidFilter) return true;
                list.Add(new Win { H = h, Pid = pid, Title = title, Cls = cls, R = r, Minimized = min, Active = h == fg });
                return true;
            }, IntPtr.Zero);
            return list;
        }

        static Win WindowFor(Dictionary<string, object> a)
        {
            var hv = Num(Get(a, "hwnd"));
            if (hv == null) throw new Fail("hwnd is required");
            var h = new IntPtr((long)hv.Value);
            if (!N.IsWindow(h)) throw new Fail("the window was closed; take a new screenshot");
            int pid = PidOf(h);
            if (ClassOf(h) == "ApplicationFrameWindow") { var core = CoreWindowOf(h); if (core != IntPtr.Zero) pid = PidOf(core); }
            return new Win { H = h, Pid = pid, Title = WindowText(h), Cls = ClassOf(h), R = FrameRect(h), Minimized = N.IsIconic(h), Active = N.GetForegroundWindow() == h };
        }

        static string ExePath(int pid)
        {
            IntPtr p = N.OpenProcess(0x1000, false, pid);
            if (p == IntPtr.Zero) return "";
            try
            {
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return N.QueryFullProcessImageName(p, 0, sb, ref size) ? sb.ToString() : "";
            }
            finally { N.CloseHandle(p); }
        }

        static bool? IsElevated(int pid)
        {
            IntPtr p = N.OpenProcess(0x1000, false, pid);
            if (p == IntPtr.Zero) return null;
            try
            {
                IntPtr tok;
                if (!N.OpenProcessToken(p, 8, out tok)) return null;
                try
                {
                    int elevated, ret;
                    if (!N.GetTokenInformation(tok, 20, out elevated, 4, out ret)) return null;
                    return elevated != 0;
                }
                finally { N.CloseHandle(tok); }
            }
            finally { N.CloseHandle(p); }
        }

        static string DescriptionOf(string exe)
        {
            if (exe.Length == 0) return "";
            string d;
            if (Descriptions.TryGetValue(exe, out d)) return d;
            try { d = (FileVersionInfo.GetVersionInfo(exe).FileDescription ?? "").Trim(); } catch { d = ""; }
            Descriptions[exe] = d;
            return d;
        }

        static object OpListApps()
        {
            var byPid = new Dictionary<int, Dictionary<string, object>>();
            var order = new List<int>();
            foreach (var w in TopWindows(-1))
            {
                Dictionary<string, object> app;
                if (!byPid.TryGetValue(w.Pid, out app))
                {
                    string exe = ExePath(w.Pid);
                    string name = exe.Length > 0 ? Path.GetFileNameWithoutExtension(exe) : "";
                    if (name.Length == 0) { try { name = Process.GetProcessById(w.Pid).ProcessName; } catch { name = "pid " + w.Pid; } }
                    app = O("pid", w.Pid, "name", name, "exe", exe, "description", DescriptionOf(exe),
                        "elevated", IsElevated(w.Pid) == true, "titles", new List<object>());
                    byPid[w.Pid] = app;
                    order.Add(w.Pid);
                }
                if (w.Title.Length > 0) ((List<object>)app["titles"]).Add(w.Title);
            }
            return O("apps", order.Select(p => (object)byPid[p]).ToList(), "selfElevated", SelfElevated);
        }

        static Dictionary<string, object> WinJson(Win w)
        {
            return O("hwnd", w.H.ToInt64(), "title", w.Title, "cls", w.Cls, "x", w.R.X, "y", w.R.Y,
                "width", w.R.Width, "height", w.R.Height, "minimized", w.Minimized, "active", w.Active);
        }

        static List<object> OpWindows(Dictionary<string, object> a)
        {
            int pid = (int)(Num(Get(a, "pid")) ?? -1);
            return TopWindows(pid).Select(w => (object)WinJson(w)).ToList();
        }

        // ------------------------------------------------------------------ UI Automation

        static CacheRequest MakeCacheRequest(TreeScope scope)
        {
            var cr = new CacheRequest();
            cr.TreeScope = scope;
            cr.TreeFilter = Automation.ControlViewCondition;
            cr.AutomationElementMode = AutomationElementMode.Full;
            foreach (var p in new AutomationProperty[] {
                AutomationElement.ControlTypeProperty, AutomationElement.NameProperty, AutomationElement.BoundingRectangleProperty,
                AutomationElement.IsEnabledProperty, AutomationElement.HasKeyboardFocusProperty, AutomationElement.IsPasswordProperty,
                AutomationElement.IsOffscreenProperty, AutomationElement.NativeWindowHandleProperty, AutomationElement.AutomationIdProperty,
                AutomationElement.ClassNameProperty,
                AutomationElement.IsInvokePatternAvailableProperty, AutomationElement.IsTogglePatternAvailableProperty,
                AutomationElement.IsValuePatternAvailableProperty, AutomationElement.IsSelectionItemPatternAvailableProperty,
                AutomationElement.IsExpandCollapsePatternAvailableProperty, AutomationElement.IsScrollPatternAvailableProperty,
                AutomationElement.IsRangeValuePatternAvailableProperty,
                ValuePattern.ValueProperty, ValuePattern.IsReadOnlyProperty, TogglePattern.ToggleStateProperty,
                RangeValuePattern.ValueProperty, SelectionItemPattern.IsSelectedProperty })
                cr.Add(p);
            return cr;
        }

        static object CP(AutomationElement a, AutomationProperty p)
        {
            try
            {
                object v = a.GetCachedPropertyValue(p, true);
                return v == AutomationElement.NotSupported ? null : v;
            }
            catch { return null; }
        }

        static readonly Dictionary<string, string> KindMap = new Dictionary<string, string> {
            {"Button","button"},{"CheckBox","checkbox"},{"RadioButton","radio"},{"ComboBox","combobox"},{"Edit","textfield"},
            {"Document","document"},{"Slider","slider"},{"Hyperlink","link"},{"ListItem","row"},{"TreeItem","row"},{"DataItem","row"},
            {"MenuItem","menuitem"},{"Menu","menu"},{"MenuBar","menubar"},{"TabItem","tab"},{"Tab","tabs"},{"Spinner","stepper"},
            {"SplitButton","splitbutton"},{"Text","text"},{"Image","image"},{"ScrollBar","scrollbar"},{"Table","table"},
            {"DataGrid","table"},{"Header","header"},{"HeaderItem","header"},{"ProgressBar","progressbar"},{"Group","group"},
            {"Pane","pane"},{"Window","window"},{"Custom","custom"},{"ToolBar","toolbar"},{"Thumb","thumb"},
            {"Separator","separator"},{"List","list"},{"Tree","tree"},{"StatusBar","statusbar"},{"TitleBar","titlebar"},
            {"ToolTip","tooltip"},{"Calendar","calendar"},
        };

        static readonly HashSet<string> ActionKinds = new HashSet<string> {
            "button","checkbox","radio","combobox","textfield","document","slider","link","row","menuitem","tab","stepper","splitbutton" };
        static readonly HashSet<string> ContainerKinds = new HashSet<string> {
            "window","pane","menubar","titlebar","scrollbar","thumb","list","tree","table","tabs","toolbar","statusbar","menu","separator" };
        static readonly HashSet<string> LeafKinds = new HashSet<string> {
            "button","checkbox","radio","menuitem","link","textfield","combobox","slider","progressbar","image","text","scrollbar",
            "thumb","separator","header","stepper" };
        public static readonly HashSet<string> TextKinds = new HashSet<string> { "textfield", "document" };

        static El Describe(AutomationElement a, El parent, int depth)
        {
            var e = new El { A = a, Parent = parent, Depth = depth };
            var ct = CP(a, AutomationElement.ControlTypeProperty) as ControlType;
            string pn = ct != null ? ct.ProgrammaticName : "";
            if (pn.StartsWith("ControlType.")) pn = pn.Substring(12);
            string kind;
            e.Kind = KindMap.TryGetValue(pn, out kind) ? kind : (pn.Length > 0 ? pn.ToLowerInvariant() : "unknown");
            e.Label = (CP(a, AutomationElement.NameProperty) as string ?? "").Trim();
            e.AutoId = CP(a, AutomationElement.AutomationIdProperty) as string ?? "";
            e.Cls = CP(a, AutomationElement.ClassNameProperty) as string ?? "";
            object rect = CP(a, AutomationElement.BoundingRectangleProperty);
            if (rect is System.Windows.Rect)
            {
                var r = (System.Windows.Rect)rect;
                if (!r.IsEmpty && r.Width > 1 && r.Height > 1 && !double.IsInfinity(r.Width))
                    e.R = new Rectangle((int)Math.Round(r.X), (int)Math.Round(r.Y), (int)Math.Round(r.Width), (int)Math.Round(r.Height));
            }
            e.Enabled = !(CP(a, AutomationElement.IsEnabledProperty) is bool) || (bool)CP(a, AutomationElement.IsEnabledProperty);
            e.Focused = CP(a, AutomationElement.HasKeyboardFocusProperty) is bool && (bool)CP(a, AutomationElement.HasKeyboardFocusProperty);
            e.Password = CP(a, AutomationElement.IsPasswordProperty) is bool && (bool)CP(a, AutomationElement.IsPasswordProperty);
            e.Offscreen = CP(a, AutomationElement.IsOffscreenProperty) is bool && (bool)CP(a, AutomationElement.IsOffscreenProperty);
            object hw = CP(a, AutomationElement.NativeWindowHandleProperty);
            e.OwnHwnd = hw is int && (int)hw != 0 ? new IntPtr((int)hw) : IntPtr.Zero;
            e.Hwnd = e.OwnHwnd != IntPtr.Zero ? e.OwnHwnd : (parent != null ? parent.Hwnd : IntPtr.Zero);
            e.CanInvoke = true.Equals(CP(a, AutomationElement.IsInvokePatternAvailableProperty));
            e.CanToggle = true.Equals(CP(a, AutomationElement.IsTogglePatternAvailableProperty));
            e.CanValue = true.Equals(CP(a, AutomationElement.IsValuePatternAvailableProperty));
            e.CanSelect = true.Equals(CP(a, AutomationElement.IsSelectionItemPatternAvailableProperty));
            e.CanExpand = true.Equals(CP(a, AutomationElement.IsExpandCollapsePatternAvailableProperty));
            e.CanScroll = true.Equals(CP(a, AutomationElement.IsScrollPatternAvailableProperty));
            e.CanRange = true.Equals(CP(a, AutomationElement.IsRangeValuePatternAvailableProperty));
            if (e.CanValue)
            {
                e.Value = CP(a, ValuePattern.ValueProperty) as string;
                e.ValueReadOnly = !false.Equals(CP(a, ValuePattern.IsReadOnlyProperty));
            }
            if (e.Value == null && e.CanToggle)
            {
                object ts = CP(a, TogglePattern.ToggleStateProperty);
                if (ts is ToggleState) e.Value = (ToggleState)ts == ToggleState.On ? "on" : (ToggleState)ts == ToggleState.Off ? "off" : "mixed";
            }
            if (e.Value == null && e.CanRange)
            {
                object rv = CP(a, RangeValuePattern.ValueProperty);
                if (rv is double) e.Value = ((double)rv).ToString("0.##", CultureInfo.InvariantCulture);
            }
            if (e.Value == null && e.CanSelect && e.Kind == "tab" && true.Equals(CP(a, SelectionItemPattern.IsSelectedProperty))) e.Value = "selected";
            if (e.Value != null && e.Value.Length > 400) e.Value = e.Value.Substring(0, 400);
            if (e.Value == e.Label) e.Value = null;
            if (e.Password) e.Value = null;

            e.Actionable = ActionKinds.Contains(e.Kind)
                || ((e.CanInvoke || e.CanToggle || e.CanSelect || e.CanExpand) && e.Label.Length > 0 && !ContainerKinds.Contains(e.Kind) && e.Kind != "unknown");
            return e;
        }

        static El DescribeLive(AutomationElement a)
        {
            if (a == null) return null;
            try { return Describe(a.GetUpdatedCache(ElementCR), null, 0); } catch { return null; }
        }

        static Snapshot Walk(Win w, int budgetMs, int hardCap)
        {
            var snap = new Snapshot { H = w.H, Frame = w.R };
            var sw = Stopwatch.StartNew();
            AutomationElement root;
            try { root = AutomationElement.FromHandle(w.H).GetUpdatedCache(TreeCR); }
            catch { snap.Ms = sw.ElapsedMilliseconds; return snap; }
            var rootEl = Describe(root, null, 0);
            rootEl.Hwnd = w.H;
            rootEl.Fetched = true;
            rootEl.Clip = w.R;
            var queue = new Queue<El>();
            queue.Enqueue(rootEl);
            while (queue.Count > 0)
            {
                if (sw.ElapsedMilliseconds > budgetMs || snap.All.Count >= hardCap) { snap.Truncated = true; break; }
                var e = queue.Dequeue();
                AutomationElementCollection kids;
                try
                {
                    if (!e.Fetched) { e.A = e.A.GetUpdatedCache(TreeCR); e.Fetched = true; }
                    kids = e.A.CachedChildren;
                }
                catch (Exception ex) { snap.Errors.Add(e.Kind + "/" + e.Cls + ": " + ex.GetType().Name + " " + ex.Message); continue; }
                if (kids == null) continue;
                if (Debug) snap.Errors.Add(e.Kind + "/" + e.Cls + " kids=" + kids.Count);
                foreach (AutomationElement k in kids)
                {
                    var c = Describe(k, e, e.Depth + 1);
                    snap.Visited++;
                    if (Debug) snap.Errors.Add("   " + c.Kind + "/" + c.Cls + " " + c.R + " off=" + c.Offscreen);
                    // Content scrolled out of its viewport (under a toolbar, say) still lies inside the
                    // window, so each element is clipped to the scroll areas and child windows that
                    // contain it (a WinUI ScrollViewer reports its content extent, its host window the viewport).
                    c.Clip = (e.CanScroll || e.OwnHwnd != IntPtr.Zero) && e != rootEl ? Rectangle.Intersect(e.Clip, e.R) : e.Clip;
                    if (c.R.IsEmpty || !c.R.IntersectsWith(c.Clip)) continue;
                    // Cached IsOffscreen is wrong for HWND-hosted content (the panes that host XAML
                    // islands say true), so containers are walked anyway; offscreen leaves are skipped.
                    if (c.Offscreen && !(ContainerKinds.Contains(c.Kind) || c.Kind == "group" || c.Kind == "custom")) continue;
                    snap.All.Add(c);
                    if (c.Depth < 40 && !LeafKinds.Contains(c.Kind)) queue.Enqueue(c);
                }
            }
            foreach (var c in snap.All)
            {
                if (c.Actionable) snap.Elements.Add(c);
                else if ((c.Kind == "text" || c.Kind == "header") && c.Label.Length > 0
                         && !(c.Parent != null && c.Parent.Actionable && c.Parent.Label == c.Label))
                    snap.Texts.Add(c);
            }
            // Reading order: rows of ~12 px, then left to right.
            snap.Elements = snap.Elements.OrderBy(c => Center(c, w.R).Y / 12).ThenBy(c => Center(c, w.R).X).ToList();
            snap.Ms = sw.ElapsedMilliseconds;
            return snap;
        }

        static Point Center(El e, Rectangle frame)
        {
            var vis = Rectangle.Intersect(e.R, e.Clip.IsEmpty ? frame : Rectangle.Intersect(frame, e.Clip));
            var r = vis.IsEmpty || e.Kind == "menuitem" ? e.R : vis;
            return new Point(r.X + r.Width / 2, r.Y + r.Height / 2);
        }

        static Dictionary<string, object> ElJson(El e, Rectangle frame)
        {
            var c = Center(e, frame);
            return O("kind", e.Kind, "label", e.Title, "value", e.Value, "x", c.X - frame.X, "y", c.Y - frame.Y,
                "w", e.R.Width, "h", e.R.Height, "enabled", e.Enabled, "focused", e.Focused, "password", e.Password);
        }

        static Dictionary<string, object> SnapJson(Snapshot s)
        {
            return O("elements", s.Elements.Select(e => (object)ElJson(e, s.Frame)).ToList(),
                "texts", s.Texts.Select(e => (object)ElJson(e, s.Frame)).ToList(),
                "visited", s.Visited, "truncated", s.Truncated, "axMs", s.Ms);
        }

        // ------------------------------------------------------------------ capture

        static Bitmap CaptureFrame(Win w, out string method)
        {
            N.RECT wr;
            N.GetWindowRect(w.H, out wr);
            int ww = Math.Max(wr.Right - wr.Left, 1), wh = Math.Max(wr.Bottom - wr.Top, 1);
            var crop = Rectangle.Intersect(new Rectangle(w.R.X - wr.Left, w.R.Y - wr.Top, w.R.Width, w.R.Height), new Rectangle(0, 0, ww, wh));
            if (crop.Width < 1 || crop.Height < 1) crop = new Rectangle(0, 0, ww, wh);
            using (var full = new Bitmap(ww, wh, PixelFormat.Format32bppRgb))
            {
                bool printed;
                using (var g = Graphics.FromImage(full))
                {
                    IntPtr hdc = g.GetHdc();
                    printed = N.PrintWindow(w.H, hdc, 2);   // PW_RENDERFULLCONTENT: also DirectComposition/UWP content
                    g.ReleaseHdc(hdc);
                }
                method = printed ? "PrintWindow" : "none";
                var shot = full.Clone(crop, PixelFormat.Format32bppRgb);
                if (!printed || IsBlank(shot))
                {
                    // A blank result happens with some GPU-rendered windows. When the window is the one in
                    // front, the screen pixels are the window, so they can be copied instead.
                    if (N.GetForegroundWindow() == w.H && !w.Minimized)
                    {
                        Phantom.HiddenDuring(() => { using (var g = Graphics.FromImage(shot)) g.CopyFromScreen(w.R.X, w.R.Y, 0, 0, w.R.Size); });
                        method = "screen";
                    }
                    else method = "blank";
                }
                return shot;
            }
        }

        static bool IsBlank(Bitmap b)
        {
            Color first = b.GetPixel(0, 0);
            for (int i = 1; i <= 12; i++)
                for (int j = 1; j <= 12; j++)
                {
                    var c = b.GetPixel(Math.Min(b.Width - 1, b.Width * i / 13), Math.Min(b.Height - 1, b.Height * j / 13));
                    if (c.ToArgb() != first.ToArgb()) return false;
                }
            return true;
        }

        static Bitmap Scaled(Bitmap src, int pw, int ph)
        {
            var dst = new Bitmap(pw, ph, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(dst))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, pw, ph));
            }
            return dst;
        }

        static string Encode(Bitmap b, string mime, double quality)
        {
            using (var ms = new MemoryStream())
            {
                if (mime == "image/png") b.Save(ms, ImageFormat.Png);
                else
                {
                    var codec = ImageCodecInfo.GetImageEncoders().First(c => c.MimeType == "image/jpeg");
                    var ep = new EncoderParameters(1);
                    ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Math.Round(quality * 100));
                    b.Save(ms, codec, ep);
                }
                return Convert.ToBase64String(ms.ToArray());
            }
        }

        static object OpScreenshot(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            bool restored = false;
            if (w.Minimized)
            {
                N.ShowWindow(w.H, 4);   // SW_SHOWNOACTIVATE
                Thread.Sleep(250);
                w = WindowFor(a);
                restored = true;
            }
            double maxEdge = Num(Get(a, "maxEdge")) ?? 1600;
            double scale = Num(Get(a, "scale")) ?? Math.Min(1.0, maxEdge / Math.Max(w.R.Width, w.R.Height));
            int pw = Math.Max(16, (int)Math.Round(w.R.Width * scale));
            int ph = Math.Max(16, (int)Math.Round(w.R.Height * scale));
            double quality = Num(Get(a, "jpegQuality")) ?? 0.8;
            int budget = (int)(Num(Get(a, "budgetMs")) ?? 250);

            // The capture runs in parallel with the accessibility walk.
            Dictionary<string, object> image = null;
            string captureError = null;
            var capture = new Thread(() =>
            {
                try
                {
                    var sw = Stopwatch.StartNew();
                    string method;
                    using (var shot = CaptureFrame(w, out method))
                    {
                        long captureMs = sw.ElapsedMilliseconds;
                        Bitmap outBmp = (pw != shot.Width || ph != shot.Height) ? Scaled(shot, pw, ph) : shot;
                        try
                        {
                            var e0 = Stopwatch.StartNew();
                            string data = Encode(outBmp, "image/jpeg", quality);
                            image = O("data", data, "mimeType", "image/jpeg", "width", outBmp.Width, "height", outBmp.Height,
                                "method", method, "captureMs", captureMs, "encodeMs", e0.ElapsedMilliseconds);
                        }
                        finally { if (outBmp != shot) outBmp.Dispose(); }
                    }
                }
                catch (Exception e) { captureError = e.Message; }
            });
            capture.IsBackground = true;
            capture.Start();

            var snap = Walk(w, budget, 1500);
            if (snap.All.Count == 0 && snap.Visited <= 2)
            {
                // Freshly opened windows (Electron, WebView) build their tree lazily.
                for (int i = 0; i < 3 && snap.All.Count == 0; i++) { Thread.Sleep(80); snap = Walk(w, budget, 1500); }
            }
            capture.Join();
            Snaps[w.H.ToInt64()] = snap;
            var r = SnapJson(snap);
            r["window"] = WinJson(w);
            r["image"] = image;
            r["captureError"] = captureError;
            r["restored"] = restored;
            r["elevated"] = IsElevated(w.Pid) == true && !SelfElevated;
            return r;
        }

        static object OpZoom(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            var region = Nums(Get(a, "region"));
            if (region == null || region.Length != 4) throw new Fail("region must be [x, y, width, height]");
            string method;
            using (var shot = CaptureFrame(w, out method))
            {
                var rect = Rectangle.Intersect(new Rectangle((int)region[0], (int)region[1], (int)Math.Max(1, region[2]), (int)Math.Max(1, region[3])),
                    new Rectangle(0, 0, shot.Width, shot.Height));
                if (rect.Width < 1 || rect.Height < 1) throw new Fail("region is outside the window frame " + shot.Width + "x" + shot.Height);
                double scale = Math.Max(0.1, Math.Min(1.0, Num(Get(a, "scale")) ?? 1.0));
                using (var crop = shot.Clone(rect, PixelFormat.Format32bppRgb))
                {
                    int pw = Math.Max(1, (int)Math.Round(rect.Width * scale)), ph = Math.Max(1, (int)Math.Round(rect.Height * scale));
                    using (var outBmp = Scaled(crop, pw, ph))
                    {
                        return O("status", "ok", "image", O("data", Encode(outBmp, "image/png", 1), "mimeType", "image/png"),
                            "text", "zoom of " + rect.X + "," + rect.Y + " " + rect.Width + "x" + rect.Height + " -> image " + pw + "x" + ph
                                + (method == "blank" ? " (the window did not render in the background; the crop may be blank)" : ""));
                    }
                }
            }
        }

        // ------------------------------------------------------------------ targets

        static Snapshot SnapOf(Win w)
        {
            Snapshot s;
            return Snaps.TryGetValue(w.H.ToInt64(), out s) ? s : null;
        }

        static El HitCache(Snapshot s, Point p)
        {
            if (s == null) return null;
            El best = null;
            foreach (var e in s.All)
            {
                if (!Rectangle.Intersect(e.R, e.Clip).Contains(p)) continue;
                if (best == null || e.Depth > best.Depth || (e.Depth == best.Depth && e.R.Width * e.R.Height < best.R.Width * best.R.Height)) best = e;
            }
            return best;
        }

        static bool PointIsOurs(Win w, Point p)
        {
            IntPtr h = N.WindowFromPoint(new N.POINT(p.X, p.Y));
            return h != IntPtr.Zero && N.GetAncestor(h, N.GA_ROOT) == w.H;
        }

        /// The element under a point of the window. When another window covers that point, the live
        /// hit test would return the other window's element, so the last screenshot's tree is used.
        static El HitTest(Win w, Point p)
        {
            if (PointIsOurs(w, p))
            {
                try
                {
                    var e = DescribeLive(AutomationElement.FromPoint(new System.Windows.Point(p.X, p.Y)));
                    if (e != null) return e;
                }
                catch { }
            }
            return HitCache(SnapOf(w), p);
        }

        static IntPtr ThreadFocus(Win w)
        {
            var tids = new List<uint> { TidOf(w.H) };
            if (w.Cls == "ApplicationFrameWindow") { var core = CoreWindowOf(w.H); if (core != IntPtr.Zero) tids.Add(TidOf(core)); }
            foreach (var tid in tids)
            {
                var gti = new N.GUITHREADINFO();
                gti.cbSize = Marshal.SizeOf(gti);
                if (N.GetGUIThreadInfo(tid, ref gti) && gti.hwndFocus != IntPtr.Zero && gti.hwndFocus != w.H
                    && N.GetAncestor(gti.hwndFocus, N.GA_ROOT) == w.H)
                    return gti.hwndFocus;
            }
            return IntPtr.Zero;
        }

        static bool IsEditClass(IntPtr h)
        {
            if (h == IntPtr.Zero) return false;
            string c = ClassOf(h).ToLowerInvariant();
            return c == "edit" || c.Contains("richedit") || c == "scintilla";
        }

        static IntPtr EditChild(Win w)
        {
            IntPtr best = IntPtr.Zero;
            long bestArea = 0;
            foreach (var c in Children(w.H))
            {
                if (!N.IsWindowVisible(c) || !IsEditClass(c)) continue;
                var r = FrameRect(c);
                long area = (long)r.Width * r.Height;
                if (area > bestArea) { best = c; bestArea = area; }
            }
            return best;
        }

        /// Deepest child window under a screen point, by geometry (works when the window is covered).
        static IntPtr DeepChild(IntPtr top, Point p)
        {
            IntPtr h = top;
            for (int i = 0; i < 32; i++)
            {
                var pt = new N.POINT(p.X, p.Y);
                N.ScreenToClient(h, ref pt);
                IntPtr c = N.ChildWindowFromPointEx(h, pt, N.CWP_SKIPINVISIBLE | N.CWP_SKIPTRANSPARENT);
                if (c == IntPtr.Zero || c == h) break;
                h = c;
            }
            return h;
        }

        static El FindTextElement(Win w)
        {
            var s = SnapOf(w);
            if (s != null)
            {
                var f = s.Elements.FirstOrDefault(e => TextKinds.Contains(e.Kind) && e.Focused);
                if (f != null) return f;
                f = s.Elements.Where(e => TextKinds.Contains(e.Kind) && e.Enabled && (!e.ValueReadOnly || IsEditClass(e.OwnHwnd)))
                    .OrderByDescending(e => (long)e.R.Width * e.R.Height).FirstOrDefault();
                if (f != null) return f;
            }
            var edit = EditChild(w);
            if (edit != IntPtr.Zero) { try { return DescribeLive(AutomationElement.FromHandle(edit)); } catch { } }
            return null;
        }

        static Target FocusedTarget(Win w)
        {
            var t = new Target { W = w, How = "focused" };
            AutomationElement a = null;
            if (N.GetForegroundWindow() == w.H) { try { a = AutomationElement.FocusedElement; } catch { } }
            if (a == null)
            {
                IntPtr hf = ThreadFocus(w);
                if (hf != IntPtr.Zero) { try { a = AutomationElement.FromHandle(hf); } catch { } }
            }
            El e = DescribeLive(a);
            if (e != null && (e.Kind == "window" || e.Kind == "pane" && !IsEditClass(e.OwnHwnd))) e = null;
            if (e == null) e = FindTextElement(w);
            if (e == null) return t;
            t.E = e;
            if (!e.R.IsEmpty) { t.P = Center(e, w.R); t.HasPoint = true; }
            return t;
        }

        static Target Resolve(Dictionary<string, object> a, Win w, bool allowFocused)
        {
            if (Get(a, "element_index") != null)
            {
                int i = (int)(Num(Get(a, "element_index")) ?? 0);
                var s = SnapOf(w);
                if (s == null || i < 1 || i > s.Elements.Count)
                    throw new Fail("element_index " + i + " is not in the last screenshot (valid: 1-" + (s == null ? 0 : s.Elements.Count) + "); take a screenshot first");
                var e = s.Elements[i - 1];
                var live = DescribeLive(e.A);
                if (live == null) throw new Fail("element [" + i + "] no longer exists; take a new screenshot");
                live.Parent = e.Parent;
                live.Clip = e.Clip;
                live.Hwnd = live.OwnHwnd != IntPtr.Zero ? live.OwnHwnd : e.Hwnd;
                if (live.Label.Length == 0) live.Label = e.Label;
                var t = new Target { W = w, E = live, How = "index" };
                if (!live.R.IsEmpty) { t.P = Center(live, w.R); t.HasPoint = true; }
                return t;
            }
            var coord = Nums(Get(a, "coordinate"));
            if (coord != null && coord.Length >= 2)
            {
                var p = new Point(w.R.X + (int)Math.Round(coord[0]), w.R.Y + (int)Math.Round(coord[1]));
                return new Target { W = w, P = p, HasPoint = true, E = HitTest(w, p), How = Str(Get(a, "how")) == "last" ? "last" : "coordinate" };
            }
            if (Str(Get(a, "target")).ToLowerInvariant() == "focused" || allowFocused) return FocusedTarget(w);
            throw new Fail("no target: pass element_index or coordinate");
        }

        static string NameOf(Target t)
        {
            if (t.E == null) return "point";
            string title = t.E.Title;
            return title.Length > 0 ? t.E.Kind + " \"" + Trunc(title, 40) + "\"" : t.E.Kind;
        }

        static string Trunc(string s, int n)
        {
            s = (s ?? "").Replace("\r", "").Replace("\n", " ");
            return s.Length > n ? s.Substring(0, n) + "…" : s;
        }

        /// Shows the phantom cursor at the target and, for actions that wait, lets it arrive first.
        static void CursorTo(Dictionary<string, object> a, Target t, bool pulse, int maxWaitMs, double factor)
        {
            if (!t.HasPoint) return;
            int ms = Phantom.Show(t.P, pulse, (int)(Num(Get(a, "cursorIdleMs")) ?? 0));
            if (ms > 40 && maxWaitMs > 0) Thread.Sleep(Math.Min(maxWaitMs, (int)(ms * factor)));
        }

        static void CheckElevation(Win w)
        {
            if (!SelfElevated && IsElevated(w.Pid) == true)
                throw new Fail("this app runs as administrator, and Windows blocks input from a non-elevated process (UIPI). Ask the user to do this step, or to run the MCP client as administrator");
        }

        // ------------------------------------------------------------------ patterns

        /// Runs a UI Automation action that may block (Invoke on a button that opens a modal dialog
        /// does not return until the dialog closes). Returns false when it is still running.
        static bool RunBounded(Action act, int ms)
        {
            Exception err = null;
            var th = new Thread(() => { try { act(); } catch (Exception e) { err = e; } });
            th.IsBackground = true;
            th.Start();
            if (!th.Join(ms)) return false;
            if (err != null) throw err;
            return true;
        }

        /// Invoke, toggle, select or expand. null when the element has none of those patterns.
        static string Press(El e)
        {
            AutomationElement a = e.A;
            object p;
            if (e.CanInvoke && a.TryGetCurrentPattern(InvokePattern.Pattern, out p))
                return RunBounded(() => ((InvokePattern)p).Invoke(), 1500) ? "invoke" : "invoke (still running: a dialog or menu probably opened)";
            if (e.CanToggle && a.TryGetCurrentPattern(TogglePattern.Pattern, out p))
            {
                ((TogglePattern)p).Toggle();
                Thread.Sleep(60);   // the new state is published asynchronously by some frameworks
                string st = "";
                try { st = ((TogglePattern)p).Current.ToggleState == ToggleState.On ? " (now on)" : " (now off)"; } catch { }
                return "toggle" + st;
            }
            if (e.CanSelect && a.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) { ((SelectionItemPattern)p).Select(); return "select"; }
            if (e.CanExpand && a.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p))
            {
                var ec = (ExpandCollapsePattern)p;
                if (ec.Current.ExpandCollapseState == ExpandCollapseState.Expanded) { ec.Collapse(); return "collapse"; }
                ec.Expand();
                return "expand";
            }
            return null;
        }

        // ------------------------------------------------------------------ mouse

        static uint ModFlags(List<int> mods)
        {
            uint f = 0;
            if (mods.Contains(N.VK_SHIFT)) f |= N.MK_SHIFT;
            if (mods.Contains(N.VK_CONTROL)) f |= N.MK_CONTROL;
            return f;
        }

        static void PostMouse(Win w, Point p, string button, int count, List<int> mods)
        {
            IntPtr h = DeepChild(w.H, p);
            var pt = new N.POINT(p.X, p.Y);
            N.ScreenToClient(h, ref pt);
            IntPtr lp = N.MakeLParam(pt.X, pt.Y);
            uint down = N.WM_LBUTTONDOWN, up = N.WM_LBUTTONUP, dbl = N.WM_LBUTTONDBLCLK, mk = N.MK_LBUTTON;
            if (button == "right") { down = N.WM_RBUTTONDOWN; up = N.WM_RBUTTONUP; dbl = N.WM_RBUTTONDBLCLK; mk = N.MK_RBUTTON; }
            else if (button == "middle") { down = N.WM_MBUTTONDOWN; up = N.WM_MBUTTONUP; dbl = N.WM_MBUTTONDBLCLK; mk = N.MK_MBUTTON; }
            uint mf = ModFlags(mods);
            WithKeyState(h, mods, () =>
            {
                N.PostMessage(h, N.WM_MOUSEMOVE, new IntPtr(mf), lp);
                for (int i = 1; i <= Math.Max(count, 1); i++)
                {
                    N.PostMessage(h, i >= 2 ? dbl : down, new IntPtr(mk | mf), lp);
                    N.PostMessage(h, up, new IntPtr(mf), lp);
                }
            });
        }

        // ------------------------------------------------------------------ keyboard

        static readonly Dictionary<string, int> VK = new Dictionary<string, int> {
            {"return",0x0D},{"enter",0x0D},{"tab",0x09},{"space",0x20},{"backspace",0x08},{"delete",0x08},{"escape",0x1B},{"esc",0x1B},
            {"forwarddelete",0x2E},{"del",0x2E},{"insert",0x2D},{"home",0x24},{"end",0x23},{"pageup",0x21},{"pagedown",0x22},
            {"left",0x25},{"up",0x26},{"right",0x27},{"down",0x28},{"menu",0x5D},{"apps",0x5D},{"capslock",0x14},
            {"f1",0x70},{"f2",0x71},{"f3",0x72},{"f4",0x73},{"f5",0x74},{"f6",0x75},{"f7",0x76},{"f8",0x77},{"f9",0x78},{"f10",0x79},
            {"f11",0x7A},{"f12",0x7B},{"plus",0xBB},{"minus",0xBD},{"comma",0xBC},{"period",0xBE},
        };
        static readonly Dictionary<string, int> ModVK = new Dictionary<string, int> {
            {"ctrl",N.VK_CONTROL},{"control",N.VK_CONTROL},{"cmd",N.VK_CONTROL},{"command",N.VK_CONTROL},
            {"alt",N.VK_MENU},{"option",N.VK_MENU},{"opt",N.VK_MENU},{"shift",N.VK_SHIFT},{"win",N.VK_LWIN},{"meta",N.VK_LWIN},{"super",N.VK_LWIN},
        };
        static readonly HashSet<int> ExtendedVK = new HashSet<int> { 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B, 0x5D };

        class Combo
        {
            public string Name = "";
            public List<int> Mods = new List<int>();
            public int Vk;          // 0 when the key is a character without a virtual key
            public char Ch;         // the character, for single-character keys
        }

        static Combo ParseCombo(string part)
        {
            var c = new Combo { Name = part };
            string lower = part.ToLowerInvariant();
            if (lower == "+") { c.Ch = '+'; c.Vk = 0; return c; }
            var segs = lower.Split('+');
            for (int i = 0; i < segs.Length - 1; i++)
            {
                int m;
                if (!ModVK.TryGetValue(segs[i], out m)) throw new Fail("unknown modifier \"" + segs[i] + "\"; use ctrl, shift, alt or win");
                if (!c.Mods.Contains(m)) c.Mods.Add(m);
            }
            string key = segs[segs.Length - 1];
            int vk;
            if (VK.TryGetValue(key, out vk)) { c.Vk = vk; return c; }
            if (key.Length == 1 || part.Length == 1)
            {
                char ch = part[part.Length - 1];
                c.Ch = ch;
                if (c.Mods.Count > 0)
                {
                    if (ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z') c.Vk = char.ToUpperInvariant(ch);
                    else if (ch >= '0' && ch <= '9') c.Vk = ch;
                    else { short s = N.VkKeyScan(ch); if (s != -1) c.Vk = s & 0xFF; }
                    return c;
                }
                // A bare character goes as its key (so shortcut handlers see it), with shift when the
                // layout needs it; characters that need AltGr or have no key go as WM_CHAR.
                short k = N.VkKeyScan(ch);
                int shiftState = k == -1 ? -1 : (k >> 8) & 0xFF;
                if (k != -1 && (shiftState & 6) == 0)
                {
                    c.Vk = k & 0xFF;
                    if ((shiftState & 1) != 0) c.Mods.Add(N.VK_SHIFT);
                }
                return c;
            }
            throw new Fail("unknown key \"" + part + "\"; examples: return, tab, escape, backspace, delete, left, pagedown, f5, ctrl+s, ctrl+shift+z");
        }

        static void PostKey(IntPtr h, int vk, bool down, bool sys)
        {
            long sc = N.MapVirtualKey((uint)vk, 0);
            long lp = 1 | (sc << 16);
            if (ExtendedVK.Contains(vk)) lp |= 1L << 24;
            if (sys) lp |= 1L << 29;
            if (!down) lp |= (1L << 30) | (1L << 31);
            uint msg = down ? (sys ? N.WM_SYSKEYDOWN : N.WM_KEYDOWN) : (sys ? N.WM_SYSKEYUP : N.WM_KEYUP);
            N.PostMessage(h, msg, new IntPtr(vk), N.LParam(lp));
        }

        static void Sync(IntPtr h, int rounds)
        {
            IntPtr r;
            for (int i = 0; i < rounds; i++) N.SendMessageTimeout(h, N.WM_NULL, IntPtr.Zero, IntPtr.Zero, N.SMTO_ABORTIFHUNG, 250, out r);
        }

        /// Background apps read modifiers with GetKeyState, which posted messages do not change. While the
        /// posted events are handled, the target thread's key state says the modifiers are down: the
        /// threads share input state through AttachThreadInput, and WM_NULL round trips wait until the
        /// target has processed what was posted.
        static void WithKeyState(IntPtr h, List<int> mods, Action post)
        {
            if (mods.Count == 0) { post(); return; }
            uint me = N.GetCurrentThreadId(), tid = TidOf(h);
            bool attached = tid != 0 && tid != me && N.AttachThreadInput(me, tid, true);
            var old = new byte[256];
            if (attached)
            {
                N.GetKeyboardState(old);
                var st = (byte[])old.Clone();
                foreach (var m in mods)
                {
                    st[m] |= 0x80;
                    if (m == N.VK_CONTROL) st[N.VK_LCONTROL] |= 0x80;
                    if (m == N.VK_MENU) st[N.VK_LMENU] |= 0x80;
                    if (m == N.VK_SHIFT) st[N.VK_LSHIFT] |= 0x80;
                }
                N.SetKeyboardState(st);
            }
            try
            {
                post();
                Sync(h, 4);
            }
            finally
            {
                if (attached) { N.SetKeyboardState(old); N.AttachThreadInput(me, tid, false); }
            }
        }

        static IntPtr SendSync(IntPtr h, uint msg, IntPtr w, IntPtr l)
        {
            IntPtr r;
            N.SendMessageTimeout(h, msg, w, l, N.SMTO_ABORTIFHUNG, 1000, out r);
            return r;
        }

        static bool IsMultiline(IntPtr h) { return (N.GetWindowLong(h, N.GWL_STYLE) & 0x4) != 0; }   // ES_MULTILINE

        static void SendCombo(IntPtr h, Combo c)
        {
            bool ctrlAlt = c.Mods.Contains(N.VK_CONTROL) || c.Mods.Contains(N.VK_MENU) || c.Mods.Contains(N.VK_LWIN);
            if (IsEditClass(h) && !ctrlAlt && c.Vk != 0x1B && c.Vk != 0x09 && !(c.Vk == 0x0D && !IsMultiline(h)))
            {
                // Edit controls handle keys in their window procedure, so they are sent synchronously:
                // posted keys would be handled after later EM_ messages (out of order), and the
                // character a posted key turns into depends on the key state when it is finally read.
                Action keyDownUp = () => WithKeyState(h, c.Mods, () =>
                {
                    long sc = N.MapVirtualKey((uint)c.Vk, 0);
                    long lp = 1 | (sc << 16) | (ExtendedVK.Contains(c.Vk) ? 1L << 24 : 0);
                    SendSync(h, N.WM_KEYDOWN, new IntPtr(c.Vk), N.LParam(lp));
                    SendSync(h, N.WM_KEYUP, new IntPtr(c.Vk), N.LParam(lp | (1L << 30) | (1L << 31)));
                });
                if (c.Mods.Count == 0 && (c.Vk == 0x0D || c.Vk == 0x08))
                {
                    // Classic Edit inserts a newline / deletes on the character, RichEdit variants on
                    // the key itself: try the key, and send the character only if nothing changed.
                    int before = TextLength(h);
                    keyDownUp();
                    if (TextLength(h) == before) SendSync(h, N.WM_CHAR, new IntPtr(c.Vk == 0x0D ? '\r' : '\b'), N.LParam(1));
                    return;
                }
                char ch = c.Ch != '\0' ? c.Ch : c.Mods.Count == 0 && c.Vk == 0x20 ? ' ' : '\0';
                if (ch != '\0') { SendSync(h, N.WM_CHAR, new IntPtr(ch), N.LParam(1)); return; }
                keyDownUp();
                return;
            }
            bool sys = c.Mods.Contains(N.VK_MENU) && !c.Mods.Contains(N.VK_CONTROL);
            if (c.Vk == 0)
            {
                N.PostMessage(h, N.WM_CHAR, new IntPtr(c.Ch), N.LParam(1));
                return;
            }
            WithKeyState(h, c.Mods, () =>
            {
                foreach (var m in c.Mods) PostKey(h, m, true, sys);
                PostKey(h, c.Vk, true, sys);
                PostKey(h, c.Vk, false, sys);
                for (int i = c.Mods.Count - 1; i >= 0; i--) PostKey(h, c.Mods[i], false, sys);
            });
            if (c.Mods.Count == 0) Sync(h, 2);
        }

        static void PostText(IntPtr h, string text)
        {
            foreach (char ch in text.Replace("\r\n", "\n"))
            {
                if (ch == '\n') { PostKey(h, 0x0D, true, false); PostKey(h, 0x0D, false, false); }
                else if (ch == '\t') { PostKey(h, 0x09, true, false); PostKey(h, 0x09, false, false); }
                else N.PostMessage(h, N.WM_CHAR, new IntPtr(ch), N.LParam(1));
            }
            Sync(h, 2);
        }

        static int TextLength(IntPtr h)
        {
            IntPtr r;
            if (N.SendMessageTimeout(h, N.WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, N.SMTO_ABORTIFHUNG, 500, out r) == IntPtr.Zero) return -1;
            return r.ToInt32();
        }

        /// The child window that keyboard input for a target should go to.
        static IntPtr KeyHwnd(Target t)
        {
            var cands = new List<IntPtr>();
            if (t.E != null && t.E.OwnHwnd != IntPtr.Zero && t.E.OwnHwnd != t.W.H) cands.Add(t.E.OwnHwnd);
            if (t.HasPoint && t.How != "focused") cands.Add(DeepChild(t.W.H, t.P));
            cands.Add(ThreadFocus(t.W));
            if (t.HasPoint) cands.Add(DeepChild(t.W.H, t.P));
            if (t.E != null && t.E.Hwnd != IntPtr.Zero && t.E.Hwnd != t.W.H) cands.Add(t.E.Hwnd);
            cands.Add(EditChild(t.W));
            var center = new Point(t.W.R.X + t.W.R.Width / 2, t.W.R.Y + t.W.R.Height / 2);
            cands.Add(DeepChild(t.W.H, center));
            // An edit control among the candidates wins: it is where text goes.
            foreach (var c in cands) if (IsEditClass(c)) return c;
            foreach (var c in cands) if (c != IntPtr.Zero && c != t.W.H) return c;
            return t.W.H;
        }

        // ------------------------------------------------------------------ classic (HMENU) menus

        class MenuItem
        {
            public IntPtr Menu;
            public int Pos;
            public string Title = "", Accel = "";
            public uint Id;
            public bool Disabled, Checked, Sub;
        }

        static string NormTitle(string s)
        {
            s = (s ?? "").Replace("&", "");
            int tab = s.IndexOf('\t');
            if (tab >= 0) s = s.Substring(0, tab);
            return s.Replace("…", "").Replace("...", "").Trim().ToLowerInvariant();
        }

        static List<MenuItem> MenuItems(IntPtr owner, IntPtr menu, int parentPos, IntPtr parentMenu)
        {
            if (parentMenu != IntPtr.Zero)
            {
                // Apps fill and enable submenu items when the submenu is about to open.
                IntPtr r;
                N.SendMessageTimeout(owner, N.WM_INITMENUPOPUP, menu, N.MakeLParam(parentPos, 0), N.SMTO_ABORTIFHUNG, 300, out r);
            }
            var list = new List<MenuItem>();
            int n = N.GetMenuItemCount(menu);
            for (int i = 0; i < n; i++)
            {
                uint st = N.GetMenuState(menu, (uint)i, N.MF_BYPOSITION);
                bool sub = N.GetSubMenu(menu, i) != IntPtr.Zero;
                if (sub) st &= 0xFF;   // for submenus the high byte is the item count, not flags
                if ((st & N.MF_SEPARATOR) != 0) continue;
                var sb = new StringBuilder(512);
                N.GetMenuString(menu, (uint)i, sb, sb.Capacity, N.MF_BYPOSITION);
                string raw = sb.ToString();
                int tab = raw.IndexOf('\t');
                list.Add(new MenuItem
                {
                    Menu = menu, Pos = i, Id = N.GetMenuItemID(menu, i),
                    Title = (tab >= 0 ? raw.Substring(0, tab) : raw).Replace("&", "").Trim(),
                    Accel = tab >= 0 ? raw.Substring(tab + 1).Trim() : "",
                    Disabled = (st & (N.MF_GRAYED | N.MF_DISABLED)) != 0,
                    Checked = (st & N.MF_CHECKED) != 0,
                    Sub = sub,
                });
            }
            return list;
        }

        static string StripAccents(string s)
        {
            var d = s.Normalize(NormalizationForm.FormD);
            var sb = new StringBuilder();
            foreach (var ch in d) if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
            return sb.ToString();
        }

        /// "Ctrl+Mayus+S" (accents are stripped), "Strg+S", "Alt+F4" -> modifier set and key name, or null.
        static Combo ParseAccel(string accel)
        {
            if (accel.Length == 0) return null;
            var c = new Combo();
            var segs = StripAccents(accel).ToLowerInvariant().Split('+').Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
            if (segs.Length == 0) return null;
            for (int i = 0; i < segs.Length - 1; i++)
            {
                string m = segs[i];
                if (m == "ctrl" || m == "control" || m == "strg" || m == "ctl") c.Mods.Add(N.VK_CONTROL);
                else if (m == "shift" || m == "mayus" || m == "mayusculas" || m == "maj" || m == "umschalt") c.Mods.Add(N.VK_SHIFT);
                else if (m == "alt") c.Mods.Add(N.VK_MENU);
                else return null;
            }
            string k = segs[segs.Length - 1];
            if (k.Length == 1) { c.Vk = char.ToUpperInvariant(k[0]); return c; }
            int vk;
            if (VK.TryGetValue(k, out vk)) { c.Vk = vk; return c; }
            if (k == "supr" || k == "entf" || k == "suppr") { c.Vk = 0x2E; return c; }
            return null;
        }

        static bool SameCombo(Combo a, Combo b)
        {
            return a.Vk == b.Vk && a.Mods.Count == b.Mods.Count && a.Mods.All(b.Mods.Contains);
        }

        static Tuple<MenuItem, string> FindAccelerator(IntPtr owner, Combo want)
        {
            IntPtr bar = N.GetMenu(owner);
            if (bar == IntPtr.Zero) return null;
            var sw = Stopwatch.StartNew();
            Func<IntPtr, int, IntPtr, string, int, Tuple<MenuItem, string>> search = null;
            search = (menu, pos, parent, path, depth) =>
            {
                foreach (var it in MenuItems(owner, menu, pos, parent))
                {
                    if (sw.ElapsedMilliseconds > 300) return null;
                    string p = path.Length > 0 ? path + " > " + it.Title : it.Title;
                    var c = ParseAccel(it.Accel);
                    if (!it.Sub && c != null && SameCombo(c, want)) return Tuple.Create(it, p);
                    if (it.Sub && depth < 3)
                    {
                        var r = search(N.GetSubMenu(menu, it.Pos), it.Pos, menu, p, depth + 1);
                        if (r != null) return r;
                    }
                }
                return null;
            };
            return search(bar, 0, IntPtr.Zero, "", 0);
        }

        // ------------------------------------------------------------------ ops: click

        static object OpClick(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            string button = Str(Get(a, "button")).ToLowerInvariant();
            if (button.Length == 0) button = "left";
            int count = Math.Max(1, Math.Min(3, (int)(Num(Get(a, "count")) ?? 1)));
            var mods = ParseMods(Get(a, "modifiers"));
            var t = Resolve(a, w, true);
            string name = NameOf(t);
            CursorTo(a, t, true, 220, 0.85);
            IntPtr fgBefore = N.GetForegroundWindow();
            var before = SnapOf(w);
            var popupsBefore = new HashSet<long>(TopWindows(w.Pid, true).Select(x => x.H.ToInt64()));

            Dictionary<string, object> res = null;
            if (t.E != null)
            {
                if (!t.E.Enabled) return Result("unsupported", name + " is disabled; change whatever enables it first");
                if (button == "left" && mods.Count == 0 && !TextKinds.Contains(t.E.Kind))
                {
                    if (count == 1)
                    {
                        string how = Press(t.E);
                        // The point may fall on a text or image inside something pressable.
                        var cur = t.E;
                        for (int hops = 0; how == null && t.How != "index" && hops < 4; hops++)
                        {
                            AutomationElement pa = null;
                            try { pa = TreeWalker.ControlViewWalker.GetParent(cur.A); } catch { }
                            var pe = DescribeLive(pa);
                            if (pe == null || pe.Kind == "window") break;
                            how = Press(pe);
                            if (how != null) name = NameOf(new Target { E = pe });
                            cur = pe;
                        }
                        if (how != null) res = Result("ok", how + " " + name + " (UI Automation)");
                    }
                }
            }
            if (res == null)
            {
                if (!t.HasPoint) return Result("unsupported", name + " has no position on screen; target it by coordinate from a screenshot");
                PostMouse(w, t.P, button, count, mods);
                res = Result("ok", button + " click" + (count > 1 ? " x" + count : "") + " at (" + (t.P.X - w.R.X) + "," + (t.P.Y - w.R.Y) + ") on " + name
                    + " via background mouse event; not verifiable here, take a screenshot to confirm");
                // Clicking a text field by index means "focus it": leave the caret at the end, not where
                // the click happened to land.
                if (t.How == "index" && button == "left" && count == 1 && mods.Count == 0 && t.E != null && TextKinds.Contains(t.E.Kind))
                {
                    IntPtr h = KeyHwnd(t);
                    if (IsEditClass(h))
                    {
                        Engaged.Add(h.ToInt64());
                        Sync(h, 2);
                        int len = Math.Max(0, TextLength(h));
                        N.SendMessage(h, N.EM_SETSEL, new IntPtr(len), new IntPtr(len));
                        res = Result("ok", "focused " + name + " (caret at the end) via background mouse event");
                    }
                }
            }
            AppendChanges(w, before, popupsBefore, res);
            KeepForeground(fgBefore, w);
            res["point"] =t.HasPoint ? new List<object> { t.P.X - w.R.X, t.P.Y - w.R.Y } : null;
            return res;
        }

        /// Some apps bring themselves to the front when a control is invoked (UWP apps such as the
        /// Calculator do on every button). When an action did that, the user's window gets the focus back:
        /// attaching to the thread that now has the foreground is what lets this process set it.
        static void KeepForeground(IntPtr fgBefore, Win w)
        {
            IntPtr now = N.GetForegroundWindow();
            if (fgBefore == IntPtr.Zero || now == fgBefore || fgBefore == w.H || !N.IsWindow(fgBefore)) return;
            if (now != w.H && N.GetAncestor(now, N.GA_ROOT) != w.H && PidOf(now) != w.Pid) return;
            uint me = N.GetCurrentThreadId();
            // UWP frames belong to ApplicationFrameHost, whose thread refuses to be attached; the
            // app's own CoreWindow thread shares its input state and accepts it.
            var tids = new List<uint>();
            if (ClassOf(now) == "ApplicationFrameWindow") { var core = CoreWindowOf(now); if (core != IntPtr.Zero) tids.Add(TidOf(core)); }
            tids.Add(TidOf(now));
            foreach (var tid in tids)
            {
                if (tid == 0 || tid == me || !N.AttachThreadInput(me, tid, true)) continue;
                bool ok;
                try { ok = N.SetForegroundWindow(fgBefore); }
                finally { N.AttachThreadInput(me, tid, false); }
                if (Debug) Console.Error.WriteLine("KeepForeground: tid=" + tid + " set=" + ok + " now=" + N.GetForegroundWindow());
                if (ok && N.GetForegroundWindow() == fgBefore) return;
            }
            // A long-running process loses the right to set the foreground; a freshly started one still
            // has it, so a short-lived copy of this exe hands the focus back.
            try
            {
                var psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--foreground " + fgBefore.ToInt64())
                { UseShellExecute = false, CreateNoWindow = true };
                using (var p = Process.Start(psi)) p.WaitForExit(1500);
            }
            catch { }
            if (Debug) Console.Error.WriteLine("KeepForeground: helper, now=" + N.GetForegroundWindow());
        }

        /// After an action, report what opened: new elements in the window (a dropdown, an expanded
        /// tree) and new windows of the app (menus, popups, dialogs).
        static void AppendChanges(Win w, Snapshot before, HashSet<long> popupsBefore, Dictionary<string, object> res)
        {
            Thread.Sleep(120);
            var opened = TopWindows(w.Pid, true).Where(x => !popupsBefore.Contains(x.H.ToInt64()) && x.H != w.H).ToList();
            if (opened.Count > 0)
                res["newWindows"] = opened.Select(x => (object)O("hwnd", x.H.ToInt64(), "title", x.Title, "cls", x.Cls, "width", x.R.Width, "height", x.R.Height)).ToList();
            if (before == null || !N.IsWindow(w.H)) return;
            var old = new HashSet<string>(before.Elements.Select(e => e.Kind + "|" + e.Title));
            var after = Walk(WindowFor(O("hwnd", w.H.ToInt64())), 120, 1500);
            var added = new List<object>();
            for (int i = 0; i < after.Elements.Count; i++)
            {
                var e = after.Elements[i];
                if (!old.Contains(e.Kind + "|" + e.Title) && (e.Kind == "menuitem" || e.Title.Length > 0)) added.Add(i + 1);
            }
            if (added.Count == 0 || after.Elements.Count == 0) return;
            Snaps[w.H.ToInt64()] = after;
            var sj = SnapJson(after);
            res["elements"] = sj["elements"];
            res["texts"] = sj["texts"];
            res["added"] = added;
        }

        static List<int> ParseMods(object o)
        {
            var mods = new List<int>();
            if (o == null) return mods;
            var names = Strs(o) ?? Str(o).ToLowerInvariant().Split(new[] { '+', ',', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (var n in names)
            {
                int m;
                if (!ModVK.TryGetValue(n.ToLowerInvariant(), out m)) throw new Fail("unknown modifier \"" + n + "\"; use ctrl, shift, alt or win");
                if (!mods.Contains(m)) mods.Add(m);
            }
            return mods;
        }

        // ------------------------------------------------------------------ ops: type

        static object OpType(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            string text = Str(Get(a, "text"));
            if (text.Length == 0) throw new Fail("text is required");
            bool overwrite = Bool(Get(a, "overwrite"));
            var t = Resolve(a, w, true);
            // With no explicit target, the previous point only counts when it holds a text field.
            if (t.How == "last" && (t.E == null || !TextKinds.Contains(t.E.Kind))) t = FocusedTarget(w);
            string name = NameOf(t);
            int chars = text.Length;
            CursorTo(a, t, false, 0, 0);

            if (t.E != null)
            {
                if (t.E.Password) return Result("unsupported", name + " is a password field; the user must type it themselves");
                if (!t.E.Enabled) return Result("unsupported", name + " is disabled");
            }
            IntPtr h = KeyHwnd(t);
            if (PasswordWindow(h)) return Result("unsupported", "the focus is in a password field; the user must type it themselves");

            // 1. Win32 edit controls (Edit, RichEdit): insert at the caret with EM_REPLACESEL, undoable.
            if (IsEditClass(h) && (t.E == null || TextKinds.Contains(t.E.Kind) || t.E.Kind == "pane" || t.E.Kind == "combobox"))
            {
                bool rich = ClassOf(h).ToLowerInvariant().Contains("richedit");
                string ins = rich ? text.Replace("\r\n", "\r").Replace('\n', '\r') : text.Replace("\r\n", "\n").Replace("\n", "\r\n");
                int beforeLen = TextLength(h);
                bool hasFocus = ThreadFocus(w) == h || Engaged.Contains(h.ToInt64());
                Engaged.Add(h.ToInt64());
                int s0 = 0, s1 = 0;
                if (overwrite) N.SendMessage(h, N.EM_SETSEL, IntPtr.Zero, new IntPtr(-1));
                else if (beforeLen > 0)
                {
                    N.SendMessage(h, N.EM_GETSEL, out s0, out s1);
                    if (!hasFocus) { N.SendMessage(h, N.EM_SETSEL, new IntPtr(beforeLen), new IntPtr(beforeLen)); s0 = s1 = beforeLen; }
                    else if (s0 == 0 && s1 >= beforeLen)
                        return Result("unsupported", "the whole content of " + name + " is selected, so typing would replace it; pass overwrite_existing:true, or send key \"right\" first to keep it and append");
                }
                N.SendMessage(h, N.EM_REPLACESEL, new IntPtr(1), ins);
                N.SendMessage(h, N.EM_SCROLLCARET, IntPtr.Zero, IntPtr.Zero);
                int afterLen = TextLength(h);
                int e0, e1;
                N.SendMessage(h, N.EM_GETSEL, out e0, out e1);
                // Replacing a selection can leave the length unchanged; the caret right after the
                // inserted text also proves it went in.
                if (overwrite || afterLen != beforeLen || afterLen < 0 || (e0 == e1 && e1 == Math.Min(s0, s1) + ins.Length && ins.Length > 0 && s0 != s1))
                    return Result("ok", (overwrite ? "replaced the contents of " : "typed " + chars + " chars into ") + name
                        + " via EM_REPLACESEL" + (afterLen >= 0 ? " (now " + afterLen + " chars)" : "")
                        + (!overwrite && !hasFocus && beforeLen > 0 ? "; it was not focused, so the text was appended at the end" : ""));
            }

            // 2. UI Automation ValuePattern (text boxes of WinUI, WPF, browsers...).
            if (t.E != null && t.E.CanValue && !t.E.ValueReadOnly)
            {
                object p;
                if (t.E.A.TryGetCurrentPattern(ValuePattern.Pattern, out p))
                {
                    var vp = (ValuePattern)p;
                    string before = "";
                    try { before = vp.Current.Value ?? ""; } catch { }
                    if (overwrite)
                    {
                        vp.SetValue(text);
                        return Result("ok", "replaced the contents of " + name + " via UIA ValuePattern (" + chars + " chars)");
                    }
                    if (before.Length == 0)
                    {
                        vp.SetValue(text);
                        return Result("ok", "typed " + chars + " chars into " + name + " via UIA ValuePattern");
                    }
                    if (!t.E.Focused && ThreadFocus(w) != h)
                    {
                        vp.SetValue(before + text);
                        return Result("ok", "appended " + chars + " chars to " + name + " via UIA ValuePattern (it was not focused; now " + (before.Length + chars) + " chars)");
                    }
                }
            }

            // 3. Background key events to the focused child window.
            if (t.E == null && t.How != "focused")
                return Result("unsupported", "no accessibility element at that point; click the field first, then type with target:\"focused\"");
            if (t.E != null && !TextKinds.Contains(t.E.Kind) && !t.E.Focused && t.How != "focused" && !IsEditClass(h))
                return Result("unsupported", name + " is not an editable text element; use the element_index of a textfield, or click it and type with target:\"focused\"");
            if (overwrite)
            {
                SendCombo(h, new Combo { Mods = new List<int> { N.VK_CONTROL }, Vk = 'A' });
            }
            PostText(h, text);
            return Result("ok", "typed " + chars + " chars into " + name + " via background key events; not verifiable here, take a screenshot to confirm");
        }

        static bool PasswordWindow(IntPtr h)
        {
            if (h == IntPtr.Zero) return false;
            if (ClassOf(h).ToLowerInvariant() == "edit" && (N.GetWindowLong(h, N.GWL_STYLE) & 0x20) != 0) return true;   // ES_PASSWORD
            try
            {
                var e = DescribeLive(AutomationElement.FromHandle(h));
                return e != null && e.Password;
            }
            catch { return false; }
        }

        // ------------------------------------------------------------------ ops: key

        static object OpKey(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            string keys = Str(Get(a, "keys"));
            var combos = keys.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(ParseCombo).ToList();
            if (combos.Count == 0) throw new Fail("keys is required, e.g. \"return\" or \"ctrl+s\"");
            Target t = (Get(a, "element_index") != null || Get(a, "coordinate") != null) ? Resolve(a, w, false) : FocusedTarget(w);
            IntPtr h = KeyHwnd(t);
            bool secure = (t.E != null && t.E.Password) || PasswordWindow(h);
            bool edit = IsEditClass(h);
            bool rich = edit && ClassOf(h).ToLowerInvariant().Contains("richedit");
            if (edit) Engaged.Add(h.ToInt64());
            var done = new List<string>();
            bool events = false;

            foreach (var c in combos)
            {
                string lname = c.Name.ToLowerInvariant();
                if (secure && !(c.Mods.Count == 0 && (c.Vk == 0x0D || c.Vk == 0x09 || c.Vk == 0x1B)))
                    return Result("unsupported", "the focus is in a password field; only return, tab and escape are sent there. The user must type the password themselves");
                bool ctrlOnly = c.Mods.Count == 1 && c.Mods[0] == N.VK_CONTROL;
                // 1. Edit commands on a Win32 edit control, as messages (exact and background-safe).
                if (edit && ctrlOnly)
                {
                    string how = null;
                    switch (c.Vk)
                    {
                        case 'A': N.SendMessage(h, N.EM_SETSEL, IntPtr.Zero, new IntPtr(-1)); how = "selected all"; break;
                        case 'C': N.SendMessage(h, N.WM_COPY, IntPtr.Zero, IntPtr.Zero); how = "copied (WM_COPY)"; break;
                        case 'X': N.SendMessage(h, N.WM_CUT, IntPtr.Zero, IntPtr.Zero); how = "cut (WM_CUT)"; break;
                        case 'V': N.SendMessage(h, N.WM_PASTE, IntPtr.Zero, IntPtr.Zero); how = "pasted (WM_PASTE)"; break;
                        case 'Z': N.SendMessage(h, N.WM_UNDO, IntPtr.Zero, IntPtr.Zero); how = "undo (WM_UNDO)"; break;
                        case 'Y': if (rich) { N.SendMessage(h, N.EM_REDO, IntPtr.Zero, IntPtr.Zero); how = "redo (EM_REDO)"; } break;
                        case 0x24: N.SendMessage(h, N.EM_SETSEL, IntPtr.Zero, IntPtr.Zero); N.SendMessage(h, N.EM_SCROLLCARET, IntPtr.Zero, IntPtr.Zero); how = "caret to start"; break;
                        case 0x23:
                            int len = Math.Max(0, TextLength(h));
                            N.SendMessage(h, N.EM_SETSEL, new IntPtr(len), new IntPtr(len));
                            N.SendMessage(h, N.EM_SCROLLCARET, IntPtr.Zero, IntPtr.Zero);
                            how = "caret to end";
                            break;
                    }
                    if (how != null) { done.Add(lname + " -> " + how); continue; }
                }
                // 2. A shortcut of a classic menu bar: run its command directly.
                if (c.Mods.Count > 0 && (c.Mods.Contains(N.VK_CONTROL) || c.Mods.Contains(N.VK_MENU)) && c.Vk != 0)
                {
                    var hit = FindAccelerator(w.H, c);
                    if (hit != null)
                    {
                        if (hit.Item1.Disabled) return Result("unsupported", lname + " is the menu item \"" + hit.Item2 + "\", which is disabled right now");
                        N.PostMessage(w.H, N.WM_COMMAND, new IntPtr(hit.Item1.Id & 0xFFFF), IntPtr.Zero);
                        done.Add(lname + " -> menu \"" + hit.Item2 + "\"");
                        continue;
                    }
                }
                // 3. Background key events, with the modifiers in the target thread's key state.
                SendCombo(h, c);
                done.Add(lname);
                events = true;
            }
            return Result("ok", "keys: " + string.Join(", ", done) + (events ? " (sent as background key events; take a screenshot to confirm)" : ""));
        }

        // ------------------------------------------------------------------ ops: scroll

        static object OpScroll(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            string dir = Str(Get(a, "direction")).ToLowerInvariant();
            double amount = Math.Max(0.1, Math.Min(100, Num(Get(a, "amount")) ?? 3));
            bool vertical = dir == "up" || dir == "down";
            double sign = dir == "down" || dir == "right" ? 1 : -1;
            Target t;
            if (Get(a, "element_index") != null || Get(a, "coordinate") != null || Get(a, "target") != null) t = Resolve(a, w, true);
            else
            {
                var p = new Point(w.R.X + w.R.Width / 2, w.R.Y + w.R.Height / 2);
                t = new Target { W = w, P = p, HasPoint = true, E = HitTest(w, p), How = "center" };
            }
            CursorTo(a, t, false, 160, 0.8);

            // The scrollable element that contains the target.
            El area = null;
            AutomationElement cur = t.E != null ? t.E.A : null;
            for (int hops = 0; cur != null && hops < 15; hops++)
            {
                var e = DescribeLive(cur);
                if (e == null) break;
                if (e.CanScroll) { area = e; break; }
                try { cur = TreeWalker.ControlViewWalker.GetParent(cur); } catch { cur = null; }
            }
            if (area == null && t.HasPoint)
            {
                var s = SnapOf(w);
                if (s != null) area = s.All.Where(e => e.CanScroll && e.R.Contains(t.P)).OrderByDescending(e => e.Depth).FirstOrDefault();
            }
            if (area != null)
            {
                object p;
                if (area.A.TryGetCurrentPattern(ScrollPattern.Pattern, out p))
                {
                    var sp = (ScrollPattern)p;
                    try
                    {
                        bool can = vertical ? sp.Current.VerticallyScrollable : sp.Current.HorizontallyScrollable;
                        if (can)
                        {
                            double old = vertical ? sp.Current.VerticalScrollPercent : sp.Current.HorizontalScrollPercent;
                            double view = vertical ? sp.Current.VerticalViewSize : sp.Current.HorizontalViewSize;
                            // One tick is 15% of the visible area; ViewSize is the visible share of the content, in percent.
                            double step = view > 0 && view < 100 ? 15.0 * view / (100.0 - view) : 5;
                            double next = Math.Max(0, Math.Min(100, old + sign * amount * step));
                            string edge = dir == "down" ? "bottom" : dir == "up" ? "top" : dir + " edge";
                            if (Math.Abs(next - old) < 0.05)
                                return Result("ok", "already at the " + edge + "; scroll position " + (old / 100).ToString("0.00", CultureInfo.InvariantCulture));
                            if (vertical) sp.SetScrollPercent(ScrollPattern.NoScroll, next);
                            else sp.SetScrollPercent(next, ScrollPattern.NoScroll);
                            Thread.Sleep(20);
                            double after = vertical ? sp.Current.VerticalScrollPercent : sp.Current.HorizontalScrollPercent;
                            if (Math.Abs(after - old) > 0.05)
                                return Result("ok", "scrolled " + dir + " via UIA ScrollPattern: position " + (old / 100).ToString("0.00", CultureInfo.InvariantCulture)
                                    + " -> " + (after / 100).ToString("0.00", CultureInfo.InvariantCulture) + " (0 = start, 1 = end)");
                        }
                    }
                    catch (InvalidOperationException) { }
                }
            }
            if (!t.HasPoint) return Result("unsupported", "no scroll area found for that target; pass a coordinate inside the content to scroll");
            IntPtr h = DeepChild(w.H, t.P);
            int delta = (int)Math.Round(120 * amount) * (int)-sign;
            N.PostMessage(h, vertical ? N.WM_MOUSEWHEEL : N.WM_MOUSEHWHEEL,
                N.LParam(((long)(short)(vertical ? delta : -delta) & 0xFFFF) << 16), N.MakeLParam(t.P.X, t.P.Y));
            Sync(h, 2);
            return Result("ok", "scrolled " + dir + " " + amount.ToString("0.#", CultureInfo.InvariantCulture)
                + " tick(s) via background wheel event; not verifiable here, take a screenshot to confirm");
        }

        // ------------------------------------------------------------------ ops: drag

        static object OpDrag(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            var mods = ParseMods(Get(a, "modifiers"));
            var from = Resolve(a, w, true);
            var toArgs = O("hwnd", w.H.ToInt64());
            if (Get(a, "to_element_index") != null) toArgs["element_index"] = Get(a, "to_element_index");
            if (Get(a, "to") != null) toArgs["coordinate"] = Get(a, "to");
            if (toArgs.Count == 1) throw new Fail("drag needs to ([x, y]) or to_element_index");
            var to = Resolve(toArgs, w, false);
            if (!from.HasPoint || !to.HasPoint) return Result("unsupported", "start or end has no position on screen; give both as coordinates");
            CursorTo(a, from, true, 180, 0.8);

            IntPtr h = DeepChild(w.H, from.P);
            Func<Point, IntPtr> lp = p => { var pt = new N.POINT(p.X, p.Y); N.ScreenToClient(h, ref pt); return N.MakeLParam(pt.X, pt.Y); };
            uint mf = ModFlags(mods);
            WithKeyState(h, mods, () =>
            {
                N.PostMessage(h, N.WM_MOUSEMOVE, new IntPtr(mf), lp(from.P));
                N.PostMessage(h, N.WM_LBUTTONDOWN, new IntPtr(N.MK_LBUTTON | mf), lp(from.P));
                Sync(h, 2);
                const int steps = 12;
                for (int i = 1; i <= steps; i++)
                {
                    var p = new Point(from.P.X + (to.P.X - from.P.X) * i / steps, from.P.Y + (to.P.Y - from.P.Y) * i / steps);
                    N.PostMessage(h, N.WM_MOUSEMOVE, new IntPtr(N.MK_LBUTTON | mf), lp(p));
                    Sync(h, 1);
                    Thread.Sleep(8);
                }
                N.PostMessage(h, N.WM_LBUTTONUP, new IntPtr(mf), lp(to.P));
            });
            CursorTo(a, to, true, 220, 0.85);
            return Result("ok", "dragged (" + (from.P.X - w.R.X) + "," + (from.P.Y - w.R.Y) + ") -> (" + (to.P.X - w.R.X) + "," + (to.P.Y - w.R.Y)
                + ") via background mouse events; drags are the least reliable in the background, take a screenshot to confirm");
        }

        // ------------------------------------------------------------------ ops: menu

        static object OpMenu(Dictionary<string, object> a)
        {
            var w = WindowFor(a);
            CheckElevation(w);
            var path = (Strs(Get(a, "path")) ?? new string[0]).Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
            bool listOnly = Bool(Get(a, "list"));
            if (N.GetMenu(w.H) != IntPtr.Zero) return ClassicMenu(w, path, listOnly);
            IntPtr fgBefore = N.GetForegroundWindow();
            try { return UiaMenu(w, path, listOnly); }
            finally { Thread.Sleep(80); KeepForeground(fgBefore, w); }
        }

        static object ClassicMenu(Win w, List<string> path, bool listOnly)
        {
            IntPtr menu = N.GetMenu(w.H), parent = IntPtr.Zero;
            int parentPos = 0;
            var walked = new List<string>();
            MenuItem leaf = null;
            foreach (var part in path)
            {
                var items = MenuItems(w.H, menu, parentPos, parent);
                string want = NormTitle(part);
                var hit = items.FirstOrDefault(i => NormTitle(i.Title) == want) ?? items.FirstOrDefault(i => NormTitle(i.Title).StartsWith(want))
                          ?? items.FirstOrDefault(i => NormTitle(i.Title).Contains(want));
                if (hit == null)
                    return Result("unsupported", "no item \"" + part + "\"" + (walked.Count > 0 ? " in \"" + string.Join(" > ", walked) + "\"" : "")
                        + "; available: " + string.Join(", ", items.Select(i => i.Title)));
                walked.Add(hit.Title);
                if (hit.Sub) { parent = menu; parentPos = hit.Pos; menu = N.GetSubMenu(menu, hit.Pos); leaf = null; }
                else { leaf = hit; break; }
            }
            string shown = string.Join(" > ", walked);
            if (leaf != null && !listOnly)
            {
                if (leaf.Disabled) return Result("unsupported", "menu \"" + shown + "\" is disabled right now");
                N.PostMessage(w.H, N.WM_COMMAND, new IntPtr(leaf.Id & 0xFFFF), IntPtr.Zero);
                return Result("ok", "menu \"" + shown + "\" (WM_COMMAND)");
            }
            if (leaf != null) return Result("ok", "\"" + shown + "\" is a command" + (leaf.Disabled ? " (disabled)" : "") + (leaf.Accel.Length > 0 ? " [" + leaf.Accel + "]" : ""));
            var lines = MenuItems(w.H, menu, parentPos, parent).Select(i => i.Title + (i.Sub ? " >" : "") + (i.Accel.Length > 0 ? "  [" + i.Accel + "]" : "")
                + (i.Disabled ? " (disabled)" : "") + (i.Checked ? " (checked)" : ""));
            return Result("ok", (walked.Count == 0 ? "menu bar" : "\"" + shown + "\"") + ":\n" + string.Join("\n", lines));
        }

        static List<AutomationElement> MenuItemsUnder(AutomationElement root)
        {
            var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem);
            try { return root.FindAll(TreeScope.Descendants, cond).Cast<AutomationElement>().ToList(); }
            catch { return new List<AutomationElement>(); }
        }

        static string SafeName(AutomationElement e)
        {
            try { return (e.Current.Name ?? "").Trim(); } catch { return ""; }
        }

        /// Menus of WinUI/WPF/UWP apps through UI Automation. Their submenus only exist while open, so
        /// each level is expanded and the items that appear (in the window or in a popup of the app) are read.
        static object UiaMenu(Win w, List<string> path, bool listOnly)
        {
            AutomationElement root;
            try { root = AutomationElement.FromHandle(w.H); } catch { throw new Fail("window not found"); }
            AutomationElement bar = null;
            try { bar = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuBar)); } catch { }
            if (bar == null) return Result("unsupported", "this window exposes no menu bar; use screenshot and click");

            Func<List<AutomationElement>> allItems = () =>
            {
                var list = MenuItemsUnder(root);
                foreach (var pw in TopWindows(w.Pid, true).Where(x => x.H != w.H))
                {
                    try { list.AddRange(MenuItemsUnder(AutomationElement.FromHandle(pw.H))); } catch { }
                }
                // A popup can show up both under the window and as a window of its own.
                var seen = new HashSet<string>();
                return list.Where(e =>
                {
                    string id;
                    try { id = string.Join(".", e.GetRuntimeId()); } catch { return false; }
                    return seen.Add(id);
                }).ToList();
            };

            var opened = new List<ExpandCollapsePattern>();
            Action closeAll = () =>
            {
                for (int i = opened.Count - 1; i >= 0; i--) { try { opened[i].Collapse(); } catch { } }
            };
            try
            {
                List<AutomationElement> level;
                try { level = bar.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem)).Cast<AutomationElement>().ToList(); }
                catch { level = new List<AutomationElement>(); }
                var walked = new List<string>();
                AutomationElement leaf = null;
                for (int pi = 0; pi < path.Count; pi++)
                {
                    string want = NormTitle(path[pi]);
                    var hit = level.FirstOrDefault(e => NormTitle(SafeName(e)) == want) ?? level.FirstOrDefault(e => NormTitle(SafeName(e)).StartsWith(want))
                              ?? level.FirstOrDefault(e => NormTitle(SafeName(e)).Contains(want));
                    if (hit == null)
                        return Result("unsupported", "no item \"" + path[pi] + "\"" + (walked.Count > 0 ? " in \"" + string.Join(" > ", walked) + "\"" : "")
                            + "; available: " + string.Join(", ", level.Select(SafeName).Where(s => s.Length > 0)));
                    walked.Add(SafeName(hit));
                    object p;
                    bool expandable = hit.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p)
                        && ((ExpandCollapsePattern)p).Current.ExpandCollapseState != ExpandCollapseState.LeafNode;
                    if (!expandable) { leaf = hit; break; }
                    var known = new HashSet<string>(allItems().Select(e => SafeName(e)));
                    var ec = (ExpandCollapsePattern)p;
                    RunBounded(() => ec.Expand(), 1500);
                    opened.Add(ec);
                    List<AutomationElement> kids = new List<AutomationElement>();
                    for (int tries = 0; tries < 6 && kids.Count == 0; tries++)
                    {
                        Thread.Sleep(60);
                        try { kids = hit.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem)).Cast<AutomationElement>().ToList(); }
                        catch { kids = new List<AutomationElement>(); }
                        if (kids.Count == 0) kids = allItems().Where(e => !known.Contains(SafeName(e))).ToList();
                    }
                    level = kids;
                }
                string shown = string.Join(" > ", walked);
                if (leaf != null && !listOnly)
                {
                    object p;
                    if (leaf.TryGetCurrentPattern(InvokePattern.Pattern, out p))
                    {
                        bool done = RunBounded(() => ((InvokePattern)p).Invoke(), 1500);
                        opened.Clear();   // invoking closes the menu
                        return Result("ok", "menu \"" + shown + "\" via invoke" + (done ? "" : " (still running: a dialog probably opened)"));
                    }
                    if (leaf.TryGetCurrentPattern(TogglePattern.Pattern, out p)) { ((TogglePattern)p).Toggle(); return Result("ok", "menu \"" + shown + "\" toggled"); }
                    return Result("unsupported", "menu \"" + shown + "\" cannot be invoked");
                }
                if (leaf != null) return Result("ok", "\"" + shown + "\" is a command");
                if (level.Count == 0) return Result("ok", "\"" + shown + "\": empty");
                var lines = level.Select(e =>
                {
                    string n = SafeName(e);
                    string acc = "";
                    try { acc = e.Current.AcceleratorKey ?? ""; } catch { }
                    bool en = true;
                    try { en = e.Current.IsEnabled; } catch { }
                    return n + (acc.Length > 0 ? "  [" + acc + "]" : "") + (en ? "" : " (disabled)");
                }).Where(s => s.Trim().Length > 0);
                return Result("ok", (walked.Count == 0 ? "menu bar" : "\"" + shown + "\"") + ":\n" + string.Join("\n", lines));
            }
            finally { closeAll(); }
        }

        // ------------------------------------------------------------------ ops: open

        static readonly Dictionary<string, string> Aliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            {"notepad","notepad.exe"},{"bloc de notas","notepad.exe"},{"calc","calc.exe"},{"calculator","calc.exe"},{"calculadora","calc.exe"},
            {"calculatorapp","calc.exe"},{"mspaint","mspaint.exe"},{"paint","mspaint.exe"},{"explorer","explorer.exe"},
            {"file explorer","explorer.exe"},{"explorador de archivos","explorer.exe"},{"wordpad","wordpad.exe"},
            {"word","winword.exe"},{"winword","winword.exe"},{"excel","excel.exe"},{"powerpoint","powerpnt.exe"},{"powerpnt","powerpnt.exe"},
            {"outlook","outlook.exe"},{"edge","msedge.exe"},{"msedge","msedge.exe"},{"chrome","chrome.exe"},
            {"firefox","firefox.exe"},
        };

        static object OpOpen(Dictionary<string, object> a)
        {
            string q = Str(Get(a, "app")).Trim();
            if (q.Length == 0) throw new Fail("app is required");
            string file;
            if (!Aliases.TryGetValue(q, out file)) file = q;
            var cands = new List<string> { file };
            if (!file.Contains(".") && !file.Contains("\\") && !file.Contains(":")) cands.Add(file + ".exe");
            string lastErr = "";
            foreach (var f in cands.Distinct())
            {
                var info = new N.SHELLEXECUTEINFO();
                info.cbSize = Marshal.SizeOf(info);
                info.fMask = 0x40 | 0x400;   // SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI
                info.lpVerb = "open";
                info.lpFile = f;
                info.nShow = 4;              // SW_SHOWNOACTIVATE
                if (N.ShellExecuteEx(ref info))
                {
                    int pid = info.hProcess != IntPtr.Zero ? N.GetProcessId(info.hProcess) : 0;
                    if (info.hProcess != IntPtr.Zero) N.CloseHandle(info.hProcess);
                    return O("status", "ok", "pid", pid, "text", "launched \"" + f + "\"");
                }
                lastErr = new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message;
            }
            throw new Fail("could not launch \"" + q + "\": " + lastErr + ". Use the exe name (e.g. notepad, mspaint, winword) or a full path");
        }
    }
}


