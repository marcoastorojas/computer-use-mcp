import * as readline from "readline";
import { ConfigStore } from "./config";
import { PsWorker } from "./worker";
import { Tools, JSONObj, ToolResult } from "./tools";
import { ensureWorkerExe } from "./native";

const serverVersion = "0.2.0";

type ContentBlock = { type: string; text?: string; [k: string]: unknown };

function prop(type: string, description: string, extra: JSONObj = {}): JSONObj {
  return { type, description, ...extra };
}

const appProp = prop("string", "App name, exe/file name or pid. Must be in the allowed list (see list_apps).");
const targeting: JSONObj = {
  element_index: prop("integer", "Index [N] of an element from the last screenshot. Preferred."),
  coordinate: prop("array", "[x, y] in the frame of the last screenshot (window points, origin top-left).", { items: "number" }),
  target: prop("string", '"focused" = the element that has keyboard focus.', { enum: ["focused"] }),
};
const targetingNote =
  ' Target with element_index, coordinate or target:"focused"; with none, the point of the previous action in that window is used.';

function tool(name: string, description: string, props: JSONObj, required: string[] = ["app"], targeted = false): JSONObj {
  const p: JSONObj = { ...props };
  if (required.includes("app")) p.app = appProp;
  if (targeted) Object.assign(p, targeting);
  const schema: JSONObj = { type: "object", properties: p };
  if (required.length) schema.required = required;
  return { name, description: description + (targeted ? targetingNote : ""), inputSchema: schema };
}

const batchActionProps: JSONObj = {
  action: prop("string", "Tool to run.", { enum: ["click", "type", "key", "scroll", "drag", "menu", "screenshot", "zoom", "find", "open_app", "wait"] }),
  element_index: prop("integer", "Element [N] from the latest screenshot (including one taken earlier in this batch)."),
  coordinate: prop("array", "[x, y] in frame coordinates.", { items: "number" }),
  target: prop("string", '"focused"', { enum: ["focused"] }),
  text: prop("string", "Text for type."),
  keys: prop("string", "Keys for key."),
  direction: prop("string", "Direction for scroll.", { enum: ["up", "down", "left", "right"] }),
  amount: prop("number", "Ticks for scroll."),
  to: prop("array", "End point [x, y] for drag.", { items: "number" }),
  path: prop("array", "Menu path for menu.", { items: "string" }),
  button: prop("string", "Mouse button for click.", { enum: ["left", "right", "middle"] }),
  count: prop("integer", "Click count."),
  overwrite_existing: prop("boolean", "For type: replace the whole field."),
  region: prop("array", "[x, y, width, height] for zoom.", { items: "number" }),
  scale: prop("number", "Image scale for screenshot/zoom."),
  ms: prop("integer", "Milliseconds for wait (max 3000)."),
};

const toolList: JSONObj[] = [
  tool("list_apps", "List running apps with name, pid, exe and whether each one is allowed.", {}, []),
  tool("list_windows", "List the windows of an app with their window_id, title and size.", {}),
  tool("open_app", "Launch an app (or reopen its window) without bringing it to the front.", {}),
  tool(
    "hide_cursor",
    "Dismiss the floating agent cursor. It stays visible across the whole task; call this once when the task is finished so it does not linger on screen.",
    {},
    []
  ),
  tool(
    "screenshot",
    "Capture ONE window of an app (works even when it is covered by other windows) and list its actionable elements as numbered [N] lines with kind, name and center position. Positions and all later coordinates are window pixels in the reported frame, whatever the image scale. Without window_id it captures the app's active (or first) window.",
    {
      window_id: prop("integer", "Window to capture (the window_id from list_windows). Later actions stay on this window."),
      scale: prop("number", "0.1-1. Shrinks the image only; coordinates stay in the full frame."),
    }
  ),
  tool(
    "click",
    "Click an element or point. Uses the UI Automation action (invoke, toggle, select) when there is one, otherwise a background mouse event (PostMessage) to the window.",
    {
      button: prop("string", "Default left.", { enum: ["left", "right", "middle"] }),
      count: prop("integer", "1 (default), 2 for double click, 3 for triple."),
      modifiers: prop("string", 'Keys held during the click, e.g. "ctrl" or "shift+alt".'),
    },
    ["app"],
    true
  ),
  tool(
    "type",
    "Insert text into a text element at its caret (appends when the element was not focused). Never types into password fields. Use key for return/tab.",
    {
      text: prop("string", "Text to insert."),
      overwrite_existing: prop("boolean", "true = replace the whole content of the field. Default false."),
    },
    ["app", "text"],
    true
  ),
  tool(
    "key",
    'Press keys or shortcuts in the app, space-separated: "return", "tab", "escape", "down down", "ctrl+s", "ctrl+shift+z" ("cmd" is treated as ctrl). Shortcuts of a classic menu bar run their menu command directly. Optional element_index/coordinate targets that element.',
    {
      keys: prop("string", "Keys to press, in order."),
      element_index: prop("integer", "Focus this element first."),
      coordinate: prop("array", "Focus the element at [x, y] first.", { items: "number" }),
    },
    ["app", "keys"]
  ),
  tool(
    "scroll",
    "Scroll the scroll area under the target (default: the previous point, else the window center). Moves it through UI Automation when possible and reports the new position.",
    {
      direction: prop("string", "Scroll direction.", { enum: ["up", "down", "left", "right"] }),
      amount: prop("number", "Ticks, default 3. One tick is about 15% of the visible area."),
    },
    ["app", "direction"],
    true
  ),
  tool(
    "drag",
    "Drag with the left button from the target to `to` (or to_element_index) using background mouse events. Only inside one window.",
    {
      to: prop("array", "End point [x, y] in frame coordinates.", { items: "number" }),
      to_element_index: prop("integer", "End element [N] from the last screenshot."),
      modifiers: prop("string", "Keys held during the drag."),
    },
    ["app"],
    true
  ),
  tool(
    "menu",
    'Run a menu-bar command by titles (case-insensitive, "..." ignored), e.g. path ["File", "Save As"]. Classic menus run without opening on screen; menus of modern apps (WinUI, WPF) open briefly. With list:true, or when the path ends in a submenu, it lists the children instead (omit path to list the menu bar).',
    {
      path: prop("array", "Menu titles from the menu bar down to the item.", { items: "string" }),
      list: prop("boolean", "true = list the children of `path` instead of pressing."),
    }
  ),
  tool(
    "zoom",
    "Return a crop of the window at native pixel density, to read small text. Read-only; it does not change coordinates.",
    {
      region: prop("array", "[x, y, width, height] in frame coordinates.", { items: "number" }),
      scale: prop("number", "0.1-1, default 1 (native density)."),
    },
    ["app", "region"]
  ),
  tool(
    "find",
    "Search the elements of the last screenshot (including ones not listed and plain texts) by kind and/or label. Does not re-read the window.",
    {
      role: prop("string", "Kind as shown in the screenshot list: button, checkbox, textfield, row, link, combobox, menuitem, tab, text..."),
      title_contains: prop("string", "Case-insensitive substring of the label or value."),
    }
  ),
  tool(
    "batch",
    'Run several actions in order in one call; stops at the first result that is not ok. {"action":"screenshot"} can go in between and at the end, and later element_index values refer to that newest screenshot. {"action":"wait","ms":300} pauses.',
    {
      actions: {
        type: "array",
        description: "Actions to run, each with \"action\" plus that tool's arguments.",
        items: { type: "object", properties: batchActionProps, required: ["action"] },
      },
    },
    ["app", "actions"]
  ),
];

const serverInstructions = `Controls Windows desktop apps in the background: the app is not brought to the front and the user's cursor does not move (actions go through UI Automation and window messages). \
Loop: screenshot(app) -> act with element_index (preferred) or coordinate -> screenshot to verify. \
Coordinates are always window pixels in the frame reported by the last screenshot, whatever the image scale. \
Every action result starts with ok, unsupported(reason and what to use instead), ineffective(...) or error. \
Use menu for menu-bar commands and batch to chain steps in one call. \
A floating cursor follows your actions and stays visible for the whole task; call hide_cursor once when the task is finished. \
Some apps ignore background input, GPU-drawn windows can capture blank (the element list still works), and drags are the least reliable: verify with a screenshot. \
Password fields and apps outside the allowed list are refused: ask the user instead of working around it.`;

// MARK: JSON-RPC

const worker = new PsWorker();
const tools = new Tools(worker);
let outChain: Promise<void> = Promise.resolve();

function send(obj: JSONObj): void {
  outChain = outChain.then(() => {
    process.stdout.write(JSON.stringify(obj) + "\n");
  });
}
function reply(id: unknown, result: JSONObj): void {
  send({ jsonrpc: "2.0", id, result });
}
function fail(id: unknown, code: number, message: string): void {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(line: string): Promise<void> {
  let msg: JSONObj;
  try {
    msg = JSON.parse(line);
  } catch {
    fail(null, -32700, "parse error");
    return;
  }
  const method = typeof msg.method === "string" ? msg.method : "";
  const params = (msg.params as JSONObj) ?? {};
  const id = msg.id;
  if (id === undefined || id === null) return;

  switch (method) {
    case "initialize": {
      const supported = ["2025-06-18", "2025-03-26", "2024-11-05"];
      const asked = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
      reply(id, {
        protocolVersion: supported.includes(asked) ? asked : supported[0],
        capabilities: { tools: {} },
        serverInfo: { name: "computer-use", version: serverVersion },
        instructions: serverInstructions,
      });
      break;
    }
    case "ping":
      reply(id, {});
      break;
    case "tools/list":
      reply(id, { tools: toolList });
      break;
    case "tools/call": {
      const name = typeof params.name === "string" ? params.name : undefined;
      if (!name) {
        fail(id, -32602, "missing tool name");
        return;
      }
      const args = (params.arguments as JSONObj) ?? {};
      const r: ToolResult = await tools.call(name, args);
      reply(id, { content: r.content as ContentBlock[], isError: r.status === "error" });
      break;
    }
    case "resources/list":
      reply(id, { resources: [] });
      break;
    case "resources/templates/list":
      reply(id, { resourceTemplates: [] });
      break;
    case "prompts/list":
      reply(id, { prompts: [] });
      break;
    default:
      fail(id, -32601, "method not found: " + method);
  }
}

async function doctor(): Promise<number> {
  const cfg = ConfigStore.shared;
  console.log(`computer-use-mcp (Windows backend) ${serverVersion}`);
  console.log(`Node:   ${process.version} on ${process.platform}`);
  console.log(`Config: ${cfg.path}`);
  try {
    console.log(`Worker: ${ensureWorkerExe()}`);
    const pong = await worker.call<{ version: string; elevated: boolean }>("ping", {}, 20000);
    console.log(`UI Automation worker: OK (${pong.version})${pong.elevated ? ", running as administrator" : ""}`);
    const res = await worker.call<{ apps: { name: string; elevated: boolean }[] }>("list_apps", {});
    const apps = res.apps || [];
    console.log(`Running apps with windows: ${apps.length}`);
    const admin = apps.filter((a) => a.elevated).map((a) => a.name);
    if (admin.length && !pong.elevated) {
      console.log(`Apps running as administrator (input to them is blocked unless the MCP client also runs elevated): ${admin.join(", ")}`);
    }
    const allowed = ConfigStore.shared.load().allowedApps;
    console.log(`Allowed apps: ${allowed.length ? allowed.join(", ") : "(none: add names to allowed_apps)"}`);
    console.log("Ready. Register dist/index.js (or ../bin/computer-use-mcp.js) in your MCP client.");
    return 0;
  } catch (e) {
    console.error(`UI Automation worker: FAILED - ${e instanceof Error ? e.message : String(e)}`);
    return 1;
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv.includes("--version")) {
    console.log(serverVersion);
    process.exit(0);
  }
  if (argv.includes("--doctor")) {
    const code = await doctor();
    worker.dispose();
    process.exit(code);
  }

  void tools.prewarm();

  const rl = readline.createInterface({ input: process.stdin });
  let queue: Promise<void> = Promise.resolve();
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    queue = queue.then(() => handle(trimmed)).catch((e) => {
      process.stderr.write(`[computer-use-mcp] handler error: ${e}\n`);
    });
  });
  rl.on("close", () => {
    queue.then(() => {
      worker.dispose();
      process.exit(0);
    });
  });
}

main();
