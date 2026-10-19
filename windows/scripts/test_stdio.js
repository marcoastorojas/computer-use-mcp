#!/usr/bin/env node
/*
 * End-to-end smoke test for the Windows backend over stdio.
 *
 *   node scripts/test_stdio.js                  # initialize + tools/list + list_apps
 *   node scripts/test_stdio.js --app notepad    # adds open_app, screenshot, find, menu, zoom, scroll
 *   node scripts/test_stdio.js --app notepad --write
 *                                               # types into a NEW Notepad tab (ctrl+n), checks the text
 *   node scripts/test_stdio.js --app calc --calc # 7 x 8 = 56 with the Calculator buttons
 *
 * The app must be in config.json -> allowed_apps (or point COMPUTER_USE_CONFIG at another file).
 */
const { spawn } = require("child_process");
const path = require("path");

const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
};
const appArg = arg("--app");
const doWrite = process.argv.includes("--write");
const doCalc = process.argv.includes("--calc");

const serverPath = path.join(__dirname, "..", "dist", "index.js");
const child = spawn(process.execPath, [serverPath], { stdio: ["pipe", "pipe", "inherit"] });

let buf = "";
const pending = new Map();
let nextId = 1;
let failures = 0;

child.stdout.setEncoding("utf8");
child.stdout.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message));
      else p.resolve(msg.result);
    }
  }
});

function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}

const text = (r) => (r.content || []).filter((c) => c.type === "text").map((c) => c.text).join("\n");

async function callTool(name, args, expectOk = true) {
  const r = await rpc("tools/call", { name, arguments: args });
  const images = (r.content || []).filter((c) => c.type === "image");
  console.log(`\n### ${name} ${JSON.stringify(args)}\n${text(r)}${images.map((c) => `\n[image ${c.mimeType} ${Math.round((c.data.length * 3) / 4 / 1024)} KB]`).join("")}`);
  if (expectOk && r.isError) {
    failures++;
    console.log("!!! unexpected error");
  }
  return r;
}

function check(cond, what) {
  console.log(`${cond ? "PASS" : "FAIL"}: ${what}`);
  if (!cond) failures++;
}

const indexOf = (r, re) => {
  const m = text(r).match(new RegExp(`^\\[(\\d+)\\] ${re}`, "m"));
  return m ? Number(m[1]) : undefined;
};

async function main() {
  const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
  console.log("initialize ->", JSON.stringify(init.serverInfo), "protocol", init.protocolVersion);
  const tools = await rpc("tools/list", {});
  check(tools.tools.length === 14, `tools/list has 14 tools (${tools.tools.map((t) => t.name).join(", ")})`);
  await callTool("list_apps", {});

  if (appArg) {
    await callTool("open_app", { app: appArg });
    await callTool("list_windows", { app: appArg });
    const shot = await callTool("screenshot", { app: appArg });
    check((shot.content || []).some((c) => c.type === "image"), "screenshot returns an image");
    await callTool("find", { app: appArg, role: "button" });
    await callTool("menu", { app: appArg, list: true }, false);
    await callTool("zoom", { app: appArg, region: [0, 0, 300, 120] });
    await callTool("scroll", { app: appArg, direction: "down", amount: 1 });

    if (doWrite) {
      // A new tab, so no existing document is touched (shortcuts are localized, the button is not hidden).
      const s = await callTool("screenshot", { app: appArg, scale: 0.5 });
      const newTab = indexOf(s, 'button "(Agregar nueva pestaña|Add new tab)"');
      if (!newTab) check(false, "found Notepad's new-tab button (the --write test is for Windows 11 Notepad)");
      else {
        await callTool("click", { app: appArg, element_index: newTab });
        await new Promise((r) => setTimeout(r, 800));
        const doc = indexOf(await callTool("screenshot", { app: appArg, scale: 0.5 }), "document");
        await callTool("type", { app: appArg, element_index: doc, text: "hola desde computer-use-mcp" });
        await callTool("key", { app: appArg, keys: "return" });
        await callTool("type", { app: appArg, element_index: doc, text: "segunda linea" });
        const after = await callTool("screenshot", { app: appArg, scale: 0.5 });
        // The value preview is cut at 30 chars: "hola desde computer-use-mcp⏎se…".
        check(/"hola desde computer-use-mcp⏎se/.test(text(after)), "the new tab holds both lines");
      }
    }

    if (doCalc) {
      const s = await callTool("screenshot", { app: appArg, scale: 0.5 });
      const seven = indexOf(s, 'button "(Siete|Seven)"');
      const times = indexOf(s, 'button "(Multiplicar por|Multiply by)"');
      const eight = indexOf(s, 'button "(Ocho|Eight)"');
      const equals = indexOf(s, 'button "(Es igual a|Equals)"');
      if (!seven || !times || !eight || !equals) check(false, "found the Calculator buttons");
      else {
        const r = await callTool("batch", {
          app: appArg,
          actions: [
            { action: "key", keys: "escape" },
            { action: "click", element_index: seven },
            { action: "click", element_index: times },
            { action: "click", element_index: eight },
            { action: "click", element_index: equals },
            { action: "wait", ms: 300 },
            { action: "screenshot", scale: 0.3 },
            { action: "find", title_contains: "56" },
          ],
        });
        check(/56/.test(text(r)), "7 x 8 = 56");
      }
    }
  }

  child.stdin.end();
  console.log(failures ? `\n${failures} check(s) failed` : "\nall checks passed");
  setTimeout(() => process.exit(failures ? 1 : 0), 300);
}

main().catch((e) => {
  console.error("TEST ERROR:", e);
  child.kill();
  process.exit(1);
});
