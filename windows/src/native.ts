import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

/**
 * The automation worker is native/Worker.cs, compiled to native/bin/cu-worker.exe with the C# compiler
 * that ships with .NET Framework 4 (present on every Windows 10/11), so no SDK is needed. It is
 * rebuilt whenever the source is newer than the exe.
 */
const root = path.join(__dirname, "..");
export const workerSource = path.join(root, "native", "Worker.cs");
export const workerExe = path.join(root, "native", "bin", "cu-worker.exe");

function frameworkDir(): string {
  const win = process.env.WINDIR || process.env.SystemRoot || "C:\\Windows";
  for (const d of ["Framework64", "Framework"]) {
    const dir = path.join(win, "Microsoft.NET", d, "v4.0.30319");
    if (fs.existsSync(path.join(dir, "csc.exe"))) return dir;
  }
  throw new Error("the .NET Framework 4 C# compiler (csc.exe) was not found; it ships with Windows 10/11");
}

export function ensureWorkerExe(force = false): string {
  const env = process.env.COMPUTER_USE_WORKER_EXE;
  if (env && fs.existsSync(env)) return env;
  const exeTime = fs.existsSync(workerExe) ? fs.statSync(workerExe).mtimeMs : 0;
  if (!force && exeTime > 0 && (!fs.existsSync(workerSource) || exeTime >= fs.statSync(workerSource).mtimeMs)) return workerExe;
  if (!fs.existsSync(workerSource)) throw new Error(`missing ${workerSource}`);

  const fw = frameworkDir();
  const refs = [
    path.join(fw, "WPF", "UIAutomationClient.dll"),
    path.join(fw, "WPF", "UIAutomationTypes.dll"),
    path.join(fw, "WPF", "WindowsBase.dll"),
    path.join(fw, "System.Drawing.dll"),
    path.join(fw, "System.Web.Extensions.dll"),
    path.join(fw, "System.Core.dll"),
  ];
  fs.mkdirSync(path.dirname(workerExe), { recursive: true });
  const tmp = workerExe + ".tmp.exe";
  try {
    execFileSync(
      path.join(fw, "csc.exe"),
      ["/nologo", "/optimize+", "/codepage:65001", "/target:exe", "/platform:anycpu", `/out:${tmp}`, ...refs.map((r) => `/reference:${r}`), workerSource],
      { stdio: ["ignore", "pipe", "pipe"], windowsHide: true }
    );
  } catch (e) {
    const out = (e as { stdout?: Buffer }).stdout?.toString() ?? "";
    throw new Error(`could not compile the worker:\n${out.trim() || String(e)}`);
  }
  // Replace atomically-ish: a running worker keeps the old exe open, so rename it out of the way.
  try {
    if (fs.existsSync(workerExe)) fs.renameSync(workerExe, workerExe + `.old-${process.pid}-${Date.now()}`);
  } catch {}
  fs.renameSync(tmp, workerExe);
  for (const f of fs.readdirSync(path.dirname(workerExe))) {
    if (f.includes(".old-")) {
      try {
        fs.unlinkSync(path.join(path.dirname(workerExe), f));
      } catch {}
    }
  }
  return workerExe;
}

if (require.main === module) {
  try {
    console.log("built " + ensureWorkerExe(process.argv.includes("--force")));
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}
