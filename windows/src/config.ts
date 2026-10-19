import * as fs from "fs";
import * as path from "path";

export interface Config {
  allowedApps: string[];
  maxElements: number;
  budgetMs: number;
  jpegQuality: number;
  maxImageEdge: number;
  phantomCursorIdleMs: number;
}

const DEFAULTS: Config = {
  allowedApps: [],
  maxElements: 60,
  budgetMs: 400,
  jpegQuality: 0.8,
  maxImageEdge: 1600,
  phantomCursorIdleMs: 0,
};

/**
 * Windows apps that are never controlled, whatever `allowed_apps` says:
 * password managers, credential UI and security surfaces.
 */
export const HARD_DENIED: string[] = [
  "1password",
  "bitwarden",
  "lastpass",
  "dashlane",
  "keepass",
  "keeper",
  "nordpass",
  "roboform",
  "credentialui",
  "consent",
  "logonui",
  "winlogon",
  "lsass",
  "windowssecurity",
  "securityhealth",
  "sechealthui",
  "systemsettings",
  "secpol",
  "credwiz",
  "enpass",
  "protonpass",
  "password",
];

/**
 * Names that refer to the same app: the launcher name people write in `allowed_apps` and the process
 * that actually owns the window (Windows 11 Calculator runs as CalculatorApp.exe, for instance).
 */
const ALIASES: string[][] = [
  ["calc", "calculator", "calculatorapp", "calculadora"],
  ["notepad", "bloc de notas"],
  ["mspaint", "paint", "paintapp"],
  ["explorer", "file explorer", "explorador de archivos"],
  ["winword", "word"],
  ["excel"],
  ["powerpnt", "powerpoint"],
  ["msedge", "edge"],
  ["code", "vscode", "visual studio code"],
];

function expand(names: string[]): Set<string> {
  const out = new Set<string>();
  for (const n of names) {
    const l = n.toLowerCase().replace(/\.exe$/, "");
    out.add(l);
    for (const group of ALIASES) if (group.includes(l)) group.forEach((g) => out.add(g));
  }
  return out;
}

function findConfigPath(): string {
  const env = process.env.COMPUTER_USE_CONFIG;
  if (env && env.trim()) return env.trim();
  // dist/config.js -> ../config.json  and package.json sits next to it.
  const candidates = [
    path.join(__dirname, "..", "config.json"),
    path.join(__dirname, "config.json"),
    path.join(process.cwd(), "config.json"),
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return path.join(__dirname, "..", "config.json");
}

export class ConfigStore {
  static shared = new ConfigStore();
  readonly path: string;
  private cached: Config = DEFAULTS;
  private mtimeMs = 0;

  private constructor() {
    this.path = findConfigPath();
  }

  load(): Config {
    let mtimeMs = 0;
    try {
      mtimeMs = fs.statSync(this.path).mtimeMs;
    } catch {
      mtimeMs = 0;
    }
    if (mtimeMs !== 0 && mtimeMs === this.mtimeMs) return this.cached;

    const c: Config = { ...DEFAULTS };
    try {
      const raw = fs.readFileSync(this.path, "utf8");
      const j = JSON.parse(raw);
      if (Array.isArray(j.allowed_apps)) c.allowedApps = j.allowed_apps.filter((x: unknown) => typeof x === "string");
      if (typeof j.max_elements === "number") c.maxElements = clamp(Math.round(j.max_elements), 5, 400);
      if (typeof j.ax_budget_ms === "number") c.budgetMs = clamp(j.ax_budget_ms, 20, 2000);
      if (typeof j.jpeg_quality === "number") c.jpegQuality = clamp(j.jpeg_quality, 0.3, 1);
      if (typeof j.max_image_edge === "number") c.maxImageEdge = clamp(j.max_image_edge, 400, 4000);
      if (typeof j.phantom_cursor_idle_ms === "number") c.phantomCursorIdleMs = clamp(j.phantom_cursor_idle_ms, 0, 3_600_000);
    } catch {
      process.stderr.write(`[computer-use-mcp] could not read ${this.path}; no app is allowed\n`);
    }
    this.cached = c;
    this.mtimeMs = mtimeMs;
    return c;
  }

  /** null when allowed; otherwise the reason. `description` is the exe's FileDescription ("Calculadora"). */
  denial(name: string, exe?: string, description?: string): string | null {
    const exeBase = exe ? path.basename(exe).toLowerCase().replace(/\.exe$/, "") : "";
    const hay = `${name} ${exeBase} ${description ?? ""}`.toLowerCase().replace(/\s+/g, "");
    if (HARD_DENIED.some((d) => hay.includes(d))) {
      return `"${name}" handles passwords or security settings and is always blocked. Ask the user to do this step by hand.`;
    }
    const allowed = expand(this.load().allowedApps);
    const mine = [name, exeBase, description ?? ""].map((s) => s.toLowerCase()).filter(Boolean);
    if (mine.some((m) => allowed.has(m))) return null;
    return `"${name}"${exe ? ` (${exe})` : ""} is not in the allowed list. Only the user can allow it by adding its name to "allowed_apps" in ${this.path}. Do not look for another route.`;
  }

  /** Whether an allowed_apps entry refers to this app (used to list allowed apps that are not running). */
  static sameApp(entry: string, names: string[]): boolean {
    const e = expand([entry]);
    return names.some((n) => e.has(n.toLowerCase().replace(/\.exe$/, "")));
  }
}

export function clamp(v: number, lo: number, hi: number): number {
  return Math.min(Math.max(v, lo), hi);
}
