import { ConfigStore, clamp } from "./config";
import { PsWorker } from "./worker";

export type JSONObj = Record<string, unknown>;

export enum Status {
  ok = "ok",
  unsupported = "unsupported",
  ineffective = "ineffective",
  error = "error",
}

export interface ContentBlock {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
}

export class ToolResult {
  status: Status = Status.ok;
  text = "";
  extra: ContentBlock[] = [];
  prefix: ContentBlock[] = [];

  static ok(t: string): ToolResult {
    const r = new ToolResult();
    r.status = Status.ok;
    r.text = "ok " + t;
    return r;
  }
  static plain(t: string): ToolResult {
    const r = new ToolResult();
    r.status = Status.ok;
    r.text = t;
    return r;
  }
  static unsupported(t: string): ToolResult {
    const r = new ToolResult();
    r.status = Status.unsupported;
    r.text = `unsupported(${t})`;
    return r;
  }
  static ineffective(t: string): ToolResult {
    const r = new ToolResult();
    r.status = Status.ineffective;
    r.text = `ineffective(${t})`;
    return r;
  }
  static error(t: string): ToolResult {
    const r = new ToolResult();
    r.status = Status.error;
    r.text = "error: " + t;
    return r;
  }

  get content(): ContentBlock[] {
    return [...this.prefix, { type: "text", text: this.text }, ...this.extra];
  }
}

class ToolError extends Error {
  result: ToolResult;
  constructor(msg: string, result?: ToolResult) {
    super(msg);
    this.result = result ?? ToolResult.error(msg);
  }
}

interface App {
  pid: number;
  name: string;
  exe: string;
  description: string;
  elevated: boolean;
  titles: string[];
}

interface Win {
  hwnd: number;
  title: string;
  cls?: string;
  x: number;
  y: number;
  width: number;
  height: number;
  minimized: boolean;
  active?: boolean;
}

interface Elem {
  kind: string;
  label: string;
  value: string | null;
  x: number;
  y: number;
  w: number;
  h: number;
  enabled: boolean;
  focused: boolean;
  password?: boolean;
}

interface Session {
  pid: number;
  name: string;
  exe: string;
  win?: Win;
  nodes: Elem[];
  texts: Elem[];
  lastPoint: Map<number, [number, number]>;
}

interface ActionResult {
  status: string;
  text: string;
  elements?: Elem[];
  texts?: Elem[];
  added?: number[];
  newWindows?: { hwnd: number; title: string; cls: string; width: number; height: number }[];
  point?: [number, number] | null;
}

const MODIFIERS = new Set(["cmd", "command", "meta", "win", "super", "shift", "alt", "option", "opt", "ctrl", "control"]);

function str(a: JSONObj, k: string): string | undefined {
  const v = a[k];
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  return undefined;
}
function num(a: JSONObj, k: string): number | undefined {
  const v = a[k];
  if (typeof v === "number") return v;
  if (typeof v === "string" && v.trim() !== "" && !isNaN(Number(v))) return Number(v);
  return undefined;
}
function int(a: JSONObj, k: string): number | undefined {
  const v = num(a, k);
  return v === undefined ? undefined : Math.round(v);
}
function bool(a: JSONObj, k: string): boolean | undefined {
  const v = a[k];
  if (typeof v === "boolean") return v;
  if (typeof v === "string") return ["true", "1", "yes"].includes(v.toLowerCase());
  if (typeof v === "number") return v !== 0;
  return undefined;
}
function numbers(a: JSONObj, k: string): number[] | undefined {
  const v = a[k];
  if (Array.isArray(v)) {
    const out = v.map((x) => (typeof x === "number" ? x : Number(x)));
    return out.some((x) => isNaN(x)) ? undefined : out;
  }
  if (typeof v === "string") {
    const out = v
      .split(/[, []()x]+/)
      .filter((s) => s !== "")
      .map((s) => Number(s))
      .filter((n) => !isNaN(n));
    return out.length ? out : undefined;
  }
  return undefined;
}

function truncate(s: string, n: number): string {
  const flat = s.replace(/\r\n|\r|\n/g, "⏎").replace(/\t/g, " ");
  return flat.length > n ? flat.slice(0, n) + "…" : flat;
}

function asArray<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[];
  return v === null || v === undefined ? [] : [v as T];
}

const exeBase = (e: string) => e.replace(/^.*[\\/]/, "").replace(/\.exe$/i, "").toLowerCase();

export class Tools {
  private worker: PsWorker;
  private sessions = new Map<number, Session>();
  private appsCache?: { at: number; apps: App[] };

  constructor(worker: PsWorker) {
    this.worker = worker;
  }

  async prewarm(): Promise<void> {
    try {
      await this.worker.call("ping", {}, 20000);
    } catch (e) {
      process.stderr.write(`[computer-use-mcp] worker prewarm failed: ${e}\n`);
    }
  }

  async call(name: string, args: JSONObj): Promise<ToolResult> {
    const t0 = Date.now();
    let r: ToolResult;
    try {
      r = await this.run(name, args);
    } catch (e) {
      if (e instanceof ToolError) r = e.result;
      else r = ToolResult.error(e instanceof Error ? e.message : String(e));
    }
    r.text += `  [${Date.now() - t0} ms]`;
    return r;
  }

  private async run(name: string, args: JSONObj): Promise<ToolResult> {
    switch (name) {
      case "list_apps":
        return this.listApps();
      case "open_app":
        return this.openApp(args);
      case "hide_cursor":
        return this.hideCursor();
      case "batch":
        return this.batch(args);
      default:
        break;
    }
    const s = await this.session(args);
    switch (name) {
      case "list_windows":
        return this.listWindows(s);
      case "screenshot":
        return this.screenshot(s, args);
      case "click":
        return this.click(s, args);
      case "type":
        return this.type(s, args);
      case "key":
        return this.key(s, args);
      case "scroll":
        return this.scroll(s, args);
      case "drag":
        return this.drag(s, args);
      case "menu":
        return this.menu(s, args);
      case "zoom":
        return this.zoom(s, args);
      case "find":
        return this.find(s, args);
      default:
        throw new ToolError(`unknown tool "${name}"`);
    }
  }

  // MARK: apps

  private async getApps(force = false): Promise<App[]> {
    if (!force && this.appsCache && Date.now() - this.appsCache.at < 1500) return this.appsCache.apps;
    const res = await this.worker.call<{ apps: App[] }>("list_apps", {});
    const apps = asArray<App>(res.apps).map((a) => ({ ...a, titles: a.titles || [], description: a.description || "" }));
    this.appsCache = { at: Date.now(), apps };
    return apps;
  }

  private denial(a: App): string | null {
    return ConfigStore.shared.denial(a.name, a.exe, a.description);
  }

  private resolveApp(apps: App[], q: string): App | undefined {
    const pid = Number(q);
    if (Number.isInteger(pid) && String(pid) === q.trim()) {
      return apps.find((a) => a.pid === pid);
    }
    const l = q.toLowerCase().replace(/\.exe$/, "");
    const exact = apps.filter(
      (a) => a.name.toLowerCase() === l || exeBase(a.exe) === l || a.description.toLowerCase() === l
    );
    if (exact.length) return exact.find((a) => this.denial(a) === null) ?? exact[0];
    // Launcher names and other aliases (calc -> CalculatorApp).
    const alias = apps.filter((a) => ConfigStore.sameApp(q, [a.name, exeBase(a.exe), a.description]));
    if (alias.length === 1) return alias[0];
    const partial = apps.filter(
      (a) => exeBase(a.exe).includes(l) || a.name.toLowerCase().includes(l) || a.description.toLowerCase().includes(l)
    );
    return partial.length === 1 ? partial[0] : undefined;
  }

  private async listApps(): Promise<ToolResult> {
    const apps = await this.getApps(true);
    const cfg = ConfigStore.shared;
    const lines: string[] = [];
    const running: string[] = [];
    for (const a of apps.slice().sort((x, y) => x.name.localeCompare(y.name))) {
      const ok = this.denial(a) === null;
      running.push(a.name, exeBase(a.exe), a.description);
      const d = a.description.toLowerCase().replace(/\.exe$/, "");
      const desc = d && d !== a.name.toLowerCase() ? ` "${a.description}"` : "";
      // Window titles only for allowed apps: the others are none of the agent's business.
      const title = ok && a.titles.length ? `  window "${truncate(a.titles[0], 50)}"` : "";
      lines.push(`${ok ? "allowed" : "blocked"} ${a.name}${desc} (pid ${a.pid})${a.elevated ? " [runs as administrator]" : ""}${title}`);
    }
    const idle = cfg.load().allowedApps.filter((n) => !ConfigStore.sameApp(n, running.filter(Boolean)));
    if (idle.length) lines.push("allowed but not running (open_app): " + idle.join(", "));
    lines.push(`config: ${cfg.path}`);
    return ToolResult.plain(lines.join("\n"));
  }

  private async openApp(args: JSONObj): Promise<ToolResult> {
    const q = str(args, "app");
    if (!q) throw new ToolError("`app` is required");
    const apps = await this.getApps(true);
    const running = this.resolveApp(apps, q);
    if (running) {
      const d = this.denial(running);
      if (d) throw new ToolError(d);
      const wins = await this.windows(running.pid);
      return ToolResult.ok(
        `${running.name} already running, pid ${running.pid}, ${wins.length} window(s); it was not brought to front`
      );
    }
    const d = ConfigStore.shared.denial(q, q);
    if (d) throw new ToolError(d);
    const res = await this.worker.call<{ pid: number; text: string }>("open", { app: q }, 20000);
    // Wait for its window: the launched process is not always the one that owns it (UWP apps,
    // single-instance apps that hand over to a running copy).
    const t0 = Date.now();
    while (Date.now() - t0 < 6000) {
      await new Promise((r) => setTimeout(r, 250));
      const now = await this.getApps(true);
      const hit = this.resolveApp(now, q) ?? now.find((a) => a.pid === res.pid);
      if (hit) {
        const deny = this.denial(hit);
        if (deny) throw new ToolError(deny);
        const wins = await this.windows(hit.pid);
        if (wins.length) {
          return ToolResult.ok(
            `${res.text}: ${hit.name} pid ${hit.pid}, ${wins.length} window(s); it was asked not to take focus, but some apps take it anyway`
          );
        }
      }
    }
    return ToolResult.ok(`${res.text}, but no window appeared yet; check list_apps in a moment`);
  }

  private hideCursor(): ToolResult {
    return ToolResult.ok("no floating cursor is drawn on Windows; nothing to hide");
  }

  // MARK: session

  private async session(args: JSONObj): Promise<Session> {
    const q = str(args, "app");
    if (!q) throw new ToolError("`app` is required (name, exe or pid; see list_apps)");
    let app = this.resolveApp(await this.getApps(false), q);
    if (!app) app = this.resolveApp(await this.getApps(true), q);
    if (!app) throw new ToolError(`"${q}" is not running (or the name is ambiguous); use open_app or list_apps`);
    const d = this.denial(app);
    if (d) throw new ToolError(d);
    let s = this.sessions.get(app.pid);
    if (!s) {
      s = { pid: app.pid, name: app.name, exe: app.exe, nodes: [], texts: [], lastPoint: new Map() };
      this.sessions.set(app.pid, s);
    }
    return s;
  }

  private async windows(pid: number): Promise<Win[]> {
    const res = await this.worker.call<{ windows: Win[] }>("windows", { pid });
    return asArray<Win>(res.windows);
  }

  private async resolveWindow(s: Session, args: JSONObj, follow: boolean): Promise<Win> {
    const wid = int(args, "window_id");
    const wins = await this.windows(s.pid);
    if (wid !== undefined) {
      const w = wins.find((x) => x.hwnd === wid);
      if (!w) throw new ToolError(`window_id ${wid} not found in ${s.name}; use list_windows`);
      return w;
    }
    if (wins.length === 0) throw new ToolError(`${s.name} has no windows; use open_app`);
    if (!follow && s.win) {
      const w = wins.find((x) => x.hwnd === s.win!.hwnd);
      if (!w) throw new ToolError("the window from the last screenshot was closed; take a new screenshot");
      return w;
    }
    return wins.find((x) => x.active) ?? (s.win && wins.find((x) => x.hwnd === s.win!.hwnd)) ?? wins[0];
  }

  private bind(s: Session, win: Win): void {
    if (!s.win || s.win.hwnd !== win.hwnd) {
      s.nodes = [];
      s.texts = [];
    }
    s.win = win;
  }

  private async listWindows(s: Session): Promise<ToolResult> {
    const wins = await this.windows(s.pid);
    if (wins.length === 0) return ToolResult.plain(`${s.name} has no windows`);
    const lines = wins.map(
      (w) =>
        `window_id=${w.hwnd} "${truncate(w.title || "", 60)}" ${w.width}x${w.height}` +
        (w.minimized ? " minimized" : "") +
        (w.active ? " active" : "")
    );
    return ToolResult.plain(lines.join("\n"));
  }

  // MARK: screenshot

  private line(i: number, e: Elem): string {
    let s = `[${i}] ${e.kind}${e.label ? ` "${truncate(e.label, 40)}"` : ""} @${e.x},${e.y} ${e.w}x${e.h}`;
    if (e.password) s += " password =•••";
    else if (e.value && e.value !== e.label) s += ` ="${truncate(e.value, 30)}"`;
    if (e.focused) s += " focused";
    if (!e.enabled) s += " disabled";
    return s;
  }

  private async screenshot(s: Session, args: JSONObj): Promise<ToolResult> {
    const t0 = Date.now();
    const cfg = ConfigStore.shared.load();
    const win = await this.resolveWindow(s, args, true);
    this.bind(s, win);
    const w = win.width;
    const h = win.height;
    const scale =
      num(args, "scale") !== undefined ? clamp(num(args, "scale")!, 0.1, 1) : Math.min(1, cfg.maxImageEdge / Math.max(w, h));

    const res = await this.worker.call<{
      window: Win;
      image: { data: string; mimeType: string; width: number; height: number; method: string; captureMs: number; encodeMs: number } | null;
      captureError: string | null;
      elements: Elem[];
      texts: Elem[];
      visited: number;
      truncated: boolean;
      axMs: number;
      restored: boolean;
      elevated: boolean;
    }>("screenshot", {
      hwnd: win.hwnd,
      scale,
      maxEdge: cfg.maxImageEdge,
      budgetMs: cfg.budgetMs,
      jpegQuality: cfg.jpegQuality,
    });

    s.nodes = asArray<Elem>(res.elements);
    s.texts = asArray<Elem>(res.texts);
    const fw = res.window ? res.window.width : w;
    const fh = res.window ? res.window.height : h;
    if (res.window) s.win = { ...win, ...res.window };

    const title = (res.window && res.window.title) || win.title || "";
    const lines: string[] = [];
    lines.push(`${s.name} "${truncate(title, 60)}" window_id=${win.hwnd}${res.restored ? " (was minimized: restored without activating it)" : ""}`);
    let frameLine = `frame ${Math.round(fw)}x${Math.round(fh)}: coordinates are window pixels in this frame, origin top-left`;
    if (res.image) {
      frameLine += `; image ${res.image.width}x${res.image.height} (scale ${scale.toFixed(2)})`;
      if (scale < 1) frameLine += `, multiply image pixels by ${(1 / scale).toFixed(2)} to get coordinates`;
    }
    lines.push(frameLine);
    if (!res.image) lines.push(`image: none. ${res.captureError ?? "capture failed"}`);
    else if (res.image.method === "blank")
      lines.push("note: the window does not render in the background (GPU-drawn app), so the image is blank; the element list is still valid");
    if (res.elevated)
      lines.push("note: this app runs as administrator, so Windows blocks input to it from this server (UIPI); only reading works");

    const maxEl = cfg.maxElements;
    for (let i = 0; i < Math.min(s.nodes.length, maxEl); i++) lines.push(this.line(i + 1, s.nodes[i]));
    if (s.nodes.length > maxEl) lines.push(`+${s.nodes.length - maxEl} more elements not listed; use find`);
    if (s.nodes.length === 0) lines.push("no actionable elements exposed; act by coordinate");

    const others = (await this.windows(s.pid)).filter((x) => x.hwnd !== win.hwnd);
    if (others.length) {
      lines.push(
        "other windows: " +
          others
            .slice(0, 6)
            .map((o) => `${o.hwnd}${o.title ? ` "${truncate(o.title, 30)}"` : ""}`)
            .join(", ")
      );
    }

    let timing = `timing: capture ${res.image ? Math.round(res.image.captureMs) : 0} ms, ax ${Math.round(res.axMs)} ms (${res.visited} nodes${
      res.truncated ? ", cut by budget" : ""
    }), encode ${res.image ? Math.round(res.image.encodeMs) : 0} ms, total ${Date.now() - t0} ms`;
    if (res.image) timing += `, image ${Math.round((res.image.data.length * 3) / 4 / 1024)} KB`;
    lines.push(timing);

    const out = ToolResult.plain(lines.join("\n"));
    if (res.image && res.image.data) {
      out.extra = [{ type: "image", data: res.image.data, mimeType: res.image.mimeType }];
    }
    return out;
  }

  // MARK: targets

  /**
   * element_index, coordinate or target:"focused"; with none, the point of the previous action in that
   * window (or, with fallback "focused", the focused element; with "none", nothing: the worker decides).
   */
  private targetArgs(s: Session, args: JSONObj, win: Win, fallback: "focused" | "none" = "focused"): JSONObj {
    const out: JSONObj = { hwnd: win.hwnd };
    if (args.element_index !== undefined) {
      const i = int(args, "element_index");
      if (i === undefined || i < 1 || i > s.nodes.length) {
        throw new ToolError(`element_index is not in the last screenshot (valid: 1-${s.nodes.length}); take a screenshot first`);
      }
      out.element_index = i;
      return out;
    }
    if (args.coordinate !== undefined) {
      const p = numbers(args, "coordinate");
      if (!p || p.length < 2) throw new ToolError("coordinate must be [x, y]");
      if (p[0] < 0 || p[1] < 0 || p[0] > win.width || p[1] > win.height) {
        throw new ToolError(
          `coordinate (${Math.round(p[0])},${Math.round(p[1])}) is outside the frame ${Math.round(win.width)}x${Math.round(
            win.height
          )}; coordinates are window pixels, not image pixels`
        );
      }
      out.coordinate = [p[0], p[1]];
      return out;
    }
    if (args.target !== undefined) {
      const t = str(args, "target") ?? "";
      if (t.toLowerCase() !== "focused") throw new ToolError('target only accepts "focused"');
      out.target = "focused";
      return out;
    }
    const lp = s.lastPoint.get(win.hwnd);
    if (lp) {
      out.coordinate = lp;
      out.how = "last";
      return out;
    }
    if (fallback === "focused") out.target = "focused";
    return out;
  }

  private async act(s: Session, win: Win, op: string, payload: JSONObj): Promise<ToolResult> {
    const res = await this.worker.call<ActionResult>(op, payload);
    let r: ToolResult;
    if (res.status === "unsupported") r = ToolResult.unsupported(res.text);
    else if (res.status === "ineffective") r = ToolResult.ineffective(res.text);
    else if (res.status === "error") r = ToolResult.error(res.text);
    else r = ToolResult.ok(res.text);

    if (res.point) s.lastPoint.set(win.hwnd, res.point);
    if (res.elements) {
      s.nodes = asArray<Elem>(res.elements);
      s.texts = asArray<Elem>(res.texts);
    }
    const added = asArray<number>(res.added);
    if (added.length) {
      r.text +=
        "\nopened/new elements (click directly by element_index):\n" +
        added
          .slice(0, 20)
          .map((i) => this.line(i, s.nodes[i - 1]))
          .join("\n");
    }
    const opened = asArray<{ hwnd: number; title: string; cls: string; width: number; height: number }>(res.newWindows);
    if (opened.length) {
      r.text +=
        "\nnew window(s) of the app (a menu, popup or dialog): " +
        opened
          .slice(0, 4)
          .map((o) => `window_id=${o.hwnd}${o.title ? ` "${truncate(o.title, 30)}"` : ""} ${o.width}x${o.height}`)
          .join(", ") +
        "; take a screenshot with that window_id to act in it";
    }
    return r;
  }

  private async click(s: Session, args: JSONObj): Promise<ToolResult> {
    const button = (str(args, "button") ?? "left").toLowerCase();
    if (!["left", "right", "middle"].includes(button)) throw new ToolError("button must be left, right or middle");
    const count = clamp(int(args, "count") ?? 1, 1, 3);
    const modifiers = this.modifiers(args);
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const ta = this.targetArgs(s, args, win);
    return this.act(s, win, "click", { ...ta, button, count, modifiers });
  }

  private async type(s: Session, args: JSONObj): Promise<ToolResult> {
    const text = str(args, "text");
    if (!text) throw new ToolError("`text` is required");
    const overwrite =
      (bool(args, "overwrite_existing") ?? false) || (bool(args, "clear") ?? false) || str(args, "mode")?.toLowerCase() === "replace";
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const ta = this.targetArgs(s, args, win);
    return this.act(s, win, "type", { ...ta, text, overwrite });
  }

  private async key(s: Session, args: JSONObj): Promise<ToolResult> {
    const keys = str(args, "keys") ?? str(args, "key");
    if (!keys) throw new ToolError('`keys` is required, e.g. "return" or "ctrl+s"');
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const payload: JSONObj = { hwnd: win.hwnd, keys };
    if (args.element_index !== undefined || args.coordinate !== undefined) {
      const ta = this.targetArgs(s, args, win);
      payload.element_index = ta.element_index;
      payload.coordinate = ta.coordinate;
    }
    return this.act(s, win, "key", payload);
  }

  private async scroll(s: Session, args: JSONObj): Promise<ToolResult> {
    const dir = (str(args, "direction") ?? "").toLowerCase();
    if (!["up", "down", "left", "right"].includes(dir)) throw new ToolError("`direction` must be up, down, left or right");
    const amount = clamp(num(args, "amount") ?? 3, 0.1, 100);
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const ta = this.targetArgs(s, args, win, "none");
    if (Array.isArray(ta.coordinate)) s.lastPoint.set(win.hwnd, ta.coordinate as [number, number]);
    return this.act(s, win, "scroll", { ...ta, direction: dir, amount });
  }

  private async drag(s: Session, args: JSONObj): Promise<ToolResult> {
    const modifiers = this.modifiers(args);
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const ta = this.targetArgs(s, args, win);
    const payload: JSONObj = { ...ta, modifiers };
    if (args.to_element_index !== undefined) {
      const i = int(args, "to_element_index");
      if (i === undefined || i < 1 || i > s.nodes.length) throw new ToolError("to_element_index is not in the last screenshot");
      payload.to_element_index = i;
    }
    const to = numbers(args, "to");
    if (to) {
      if (to.length < 2) throw new ToolError("`to` must be [x, y]");
      payload.to = [to[0], to[1]];
    }
    if (payload.to === undefined && payload.to_element_index === undefined) {
      throw new ToolError("drag needs `to` ([x, y]) or `to_element_index`");
    }
    const r = await this.act(s, win, "drag", payload);
    if (payload.to) s.lastPoint.set(win.hwnd, payload.to as [number, number]);
    return r;
  }

  private async menu(s: Session, args: JSONObj): Promise<ToolResult> {
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const payload: JSONObj = { hwnd: win.hwnd, list: bool(args, "list") ?? false };
    const path = args.path;
    if (Array.isArray(path)) payload.path = path.map((x) => String(x));
    else if (typeof path === "string") payload.path = path.split(">").map((x) => x.trim()).filter(Boolean);
    const res = await this.worker.call<ActionResult>("menu", payload, 20000);
    if (res.status !== "ok") return res.status === "unsupported" ? ToolResult.unsupported(res.text) : ToolResult.error(res.text);
    return ToolResult.plain(res.text);
  }

  private async zoom(s: Session, args: JSONObj): Promise<ToolResult> {
    const win = await this.resolveWindow(s, args, false);
    this.bind(s, win);
    const region = numbers(args, "region");
    if (!region || region.length !== 4) throw new ToolError("`region` must be [x, y, width, height] in frame coordinates");
    const scale = num(args, "scale") !== undefined ? clamp(num(args, "scale")!, 0.1, 1) : 1;
    const res = await this.worker.call<{ image: { data: string; mimeType: string }; text: string }>("zoom", {
      hwnd: win.hwnd,
      region,
      scale,
    });
    const out = ToolResult.plain(res.text + ". Read-only: coordinates for actions still come from the screenshot frame");
    out.extra = [{ type: "image", data: res.image.data, mimeType: res.image.mimeType }];
    return out;
  }

  private async find(s: Session, args: JSONObj): Promise<ToolResult> {
    if (!s.win || (s.nodes.length === 0 && s.texts.length === 0)) {
      throw new ToolError(`no elements cached for ${s.name}; take a screenshot first`);
    }
    let role = (str(args, "role") ?? "").toLowerCase();
    if (role.startsWith("controltype.")) role = role.slice(12);
    const roleAliases: Record<string, string> = { textarea: "textfield", edit: "textfield", hyperlink: "link", listitem: "row", treeitem: "row" };
    role = roleAliases[role] ?? role;
    const q = str(args, "title_contains")?.toLowerCase();
    if (!role && !q) throw new ToolError("pass role and/or title_contains");
    const matches = (n: Elem): boolean => {
      if (role && n.kind !== role) return false;
      if (q && !n.label.toLowerCase().includes(q) && !(n.value ?? "").toLowerCase().includes(q)) return false;
      return true;
    };
    const lines: string[] = [];
    s.nodes.forEach((n, i) => {
      if (matches(n)) lines.push(this.line(i + 1, n));
    });
    for (const n of s.texts) {
      if (matches(n)) lines.push(`text "${truncate(n.value ?? n.label, 60)}" @${n.x},${n.y} (no index; click by coordinate)`);
    }
    if (lines.length === 0) {
      return ToolResult.plain(
        `no match in the last screenshot (${s.nodes.length} elements, ${s.texts.length} texts); scroll or take a new screenshot`
      );
    }
    const extra = lines.length > 40 ? `\n+${lines.length - 40} more; narrow the search` : "";
    return ToolResult.plain(lines.slice(0, 40).join("\n") + extra);
  }

  private modifiers(args: JSONObj): string[] {
    const v = args.modifiers;
    if (v === undefined || v === null || v === "") return [];
    const names: string[] =
      typeof v === "string"
        ? v.toLowerCase().split(/[+, ]+/).filter(Boolean)
        : Array.isArray(v)
          ? v.map((x) => String(x).toLowerCase())
          : [];
    for (const n of names) {
      if (!MODIFIERS.has(n)) throw new ToolError("unknown modifier; use ctrl, shift, alt or win");
    }
    return names;
  }

  // MARK: batch

  private async batch(args: JSONObj): Promise<ToolResult> {
    const actions = args.actions;
    if (!Array.isArray(actions) || actions.length === 0) {
      throw new ToolError('`actions` must be a non-empty array of {"action": ...}');
    }
    if (actions.length > 30) throw new ToolError("at most 30 actions per batch");
    const result = new ToolResult();
    const content: ContentBlock[] = [];
    let lines: string[] = [];
    const flush = () => {
      if (lines.length) content.push({ type: "text", text: lines.join("\n") });
      lines = [];
    };
    for (let i = 0; i < actions.length; i++) {
      const a = actions[i] as JSONObj;
      const name = (str(a, "action") ?? str(a, "tool") ?? "").trim();
      const sub: JSONObj = { ...a };
      if (sub.app === undefined) sub.app = args.app;
      let r: ToolResult;
      if (name === "wait") {
        const ms = clamp(num(a, "ms") ?? 300, 0, 3000);
        await new Promise((res) => setTimeout(res, ms));
        r = ToolResult.ok(`waited ${Math.round(ms)} ms`);
      } else if (name === "" || name === "batch") {
        r = ToolResult.error(
          'each action needs "action": click, type, key, scroll, drag, menu, screenshot, zoom, find, open_app or wait'
        );
      } else {
        try {
          r = await this.run(name, sub);
        } catch (e) {
          r = e instanceof ToolError ? e.result : ToolResult.error(e instanceof Error ? e.message : String(e));
        }
      }
      lines.push(`${i + 1}. ${name}: ${r.text}`);
      if (r.extra.length) {
        flush();
        content.push(...r.extra);
      }
      if (r.status !== Status.ok) {
        result.status = r.status;
        if (i < actions.length - 1) lines.push(`stopped: ${actions.length - 1 - i} action(s) not run`);
        break;
      }
      if (i < actions.length - 1) await new Promise((res) => setTimeout(res, 30));
    }
    result.text = lines.join("\n");
    result.prefix = content;
    return result;
  }
}
