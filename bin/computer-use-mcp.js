#!/usr/bin/env node
// One MCP command for both systems: on macOS it runs the Swift binary, on Windows the backend in
// windows/. Register `node /path/to/computer-use-mcp/bin/computer-use-mcp.js` in the MCP client and the
// same entry works on either machine. Without COMPUTER_USE_CONFIG, each system uses its own config
// (config.json on macOS, windows/config.json on Windows), since app names differ between them.
"use strict";
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const root = path.join(__dirname, "..");

function fail(msg) {
  process.stderr.write(`[computer-use-mcp] ${msg}\n`);
  process.exit(1);
}

if (process.platform === "win32") {
  const entry = path.join(root, "windows", "dist", "index.js");
  if (!fs.existsSync(entry)) fail(`not built yet: run "npm install" and "npm run build" in ${path.join(root, "windows")}`);
  if (!process.env.COMPUTER_USE_CONFIG) process.env.COMPUTER_USE_CONFIG = path.join(root, "windows", "config.json");
  require(entry);
} else if (process.platform === "darwin") {
  const bin = path.join(root, ".build", "release", "computer-use-mcp");
  if (!fs.existsSync(bin)) fail(`not built yet: run ./build.sh in ${root}`);
  const env = { ...process.env };
  if (!env.COMPUTER_USE_CONFIG) env.COMPUTER_USE_CONFIG = path.join(root, "config.json");
  const child = spawn(bin, process.argv.slice(2), { stdio: "inherit", env });
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => child.kill(sig));
  child.on("error", (e) => fail(e.message));
  child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
} else {
  fail(`unsupported platform ${process.platform}: there are backends for macOS and Windows`);
}
