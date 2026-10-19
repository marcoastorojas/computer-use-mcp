import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import * as readline from "readline";
import { ensureWorkerExe } from "./native";

interface Pending {
  resolve: (v: any) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

interface Proc {
  child: ChildProcessWithoutNullStreams;
  ready: Promise<void>;
  pending: Map<number, Pending>;
  dead: boolean;
}

/**
 * Long-lived automation worker (native/bin/cu-worker.exe). Requests and responses are
 * newline-delimited JSON. One process stays alive so UI Automation is not set up on every call; if it
 * dies or hangs (an app that stops responding can block a UI Automation call), the next call starts a
 * fresh one.
 */
export class PsWorker {
  private proc?: Proc;
  private nextId = 1;
  private exe?: string;

  constructor() {
    if (process.platform !== "win32") {
      throw new Error("The Windows backend requires Windows.");
    }
  }

  private start(): Proc {
    if (!this.exe) this.exe = ensureWorkerExe();
    const child = spawn(this.exe, [], { stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    const pending = new Map<number, Pending>();
    let readyResolve!: () => void;
    let readyReject!: (e: Error) => void;
    const ready = new Promise<void>((res, rej) => {
      readyResolve = res;
      readyReject = rej;
    });
    ready.catch(() => {});
    const p: Proc = { child, ready, pending, dead: false };

    child.stdout.setEncoding("utf8");
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      const t = line.trim();
      if (!t) return;
      let msg: any;
      try {
        msg = JSON.parse(t);
      } catch {
        process.stderr.write("[worker] non-json output: " + t.slice(0, 200) + "\n");
        return;
      }
      if (msg.event === "ready") {
        readyResolve();
        return;
      }
      const q = pending.get(msg.id);
      if (!q) return;
      pending.delete(msg.id);
      clearTimeout(q.timer);
      if (msg.ok) q.resolve(msg.result);
      else q.reject(new Error(String(msg.error ?? "worker error")));
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (d: string) => process.stderr.write("[worker] " + d));

    const die = (err: Error) => {
      if (p.dead) return;
      p.dead = true;
      readyReject(err);
      for (const q of pending.values()) {
        clearTimeout(q.timer);
        q.reject(err);
      }
      pending.clear();
      if (this.proc === p) this.proc = undefined;
    };
    child.on("error", (e) => die(e instanceof Error ? e : new Error(String(e))));
    child.on("exit", (code) => die(new Error(`the automation worker exited (code ${code}); it restarts on the next call`)));
    return p;
  }

  async call<T = any>(op: string, args: Record<string, unknown> = {}, timeoutMs = 30000): Promise<T> {
    if (!this.proc || this.proc.dead) this.proc = this.start();
    const p = this.proc;
    await p.ready;
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        p.pending.delete(id);
        // The worker is stuck (usually inside a call to an app that stopped responding): replace it.
        try {
          p.child.kill();
        } catch {}
        reject(new Error(`${op} timed out after ${timeoutMs} ms (the app may be hung); the worker was restarted`));
      }, timeoutMs);
      p.pending.set(id, { resolve, reject, timer });
      p.child.stdin.write(JSON.stringify({ id, op, args }) + "\n");
    });
  }

  dispose(): void {
    const p = this.proc;
    if (!p) return;
    try {
      p.child.stdin.end();
    } catch {}
    try {
      p.child.kill();
    } catch {}
  }
}
