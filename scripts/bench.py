#!/usr/bin/env python3
"""Banco de pruebas mecánico (sin modelo) del servidor computer-use.

Ejecútalo desde la terminal integrada de tu cliente MCP, con ese cliente activado en
Accesibilidad y Grabación de pantalla:

  ~/computer-use-mcp/scripts/bench.py [--runs 3]

Abre Calculadora y TextEdit en segundo plano (deja un documento sin guardar), mide cada
llamada y comprueba que nunca cambió la app del frente ni se movió el cursor.
Escribe el informe en bench/resultado-<fecha>.md.
"""
import argparse
import ctypes
import json
import os
import re
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_stdio import ROOT, Server  # noqa: E402


class _Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
_cg.CGEventCreate.restype = ctypes.c_void_p
_cg.CGEventCreate.argtypes = [ctypes.c_void_p]
_cg.CGEventGetLocation.restype = _Point
_cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]


def cursor():
    p = _cg.CGEventGetLocation(_cg.CGEventCreate(None))
    return round(p.x), round(p.y)


class Bench:
    def __init__(self):
        self.s = Server()
        self.s.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "bench", "version": "1"}})
        self.rows = []  # (tarea, paso, herramienta, ok, ms, detalle)
        self.times = {}  # herramienta -> [ms]

    def call(self, task, step, tool, args, expect="ok"):
        text, images, _, ms = self.s.call(tool, args)
        first = text.splitlines()[0] if text else ""
        ok = expect is None or first.startswith(expect)
        if tool == "screenshot":
            # Un screenshot sin imagen no es un acierto; se guarda la línea de tiempos para diagnosticar.
            extra = [l for l in text.splitlines() if l.startswith(("image: none", "timing:"))]
            ok = ok and bool(images)
            first = " · ".join(extra) or first
        self.rows.append((task, step, tool, ok, ms, first[:220]))
        self.times.setdefault(tool, []).append(ms)
        return ok, text, images

    def frontmost(self):
        text = self.s.call("list_apps")[0]
        return next((l.split(" (")[0].split(" ", 1)[1] for l in text.splitlines() if " frontmost" in l), "?")


def digits(s):
    return re.sub(r"\D", "", s)


def task_calculator(b, run):
    t = f"Calculadora #{run}"
    b.call(t, "abrir", "open_app", {"app": "Calculator"})
    b.call(t, "limpiar", "key", {"app": "Calculator", "keys": "escape escape"})
    ok, shot, _ = b.call(t, "screenshot", "screenshot", {"app": "Calculator"}, expect=None)
    labels = {}
    for line in shot.splitlines():
        m = re.match(r'\[(\d+)\] button "(.+?)"', line)
        if m:
            labels.setdefault(m.group(2), int(m.group(1)))
    for d in "127":
        if d not in labels:
            b.rows.append((t, f"botón {d}", "screenshot", False, 0, "no aparece en la lista de elementos"))
            return
        b.call(t, f"clic {d}", "click", {"app": "Calculator", "element_index": labels[d]})
    b.call(t, "× por teclado", "key", {"app": "Calculator", "keys": "*"})
    b.call(t, "8 por teclado", "key", {"app": "Calculator", "keys": "8"})
    b.call(t, "= por teclado", "key", {"app": "Calculator", "keys": "return"})
    time.sleep(0.2)
    b.call(t, "screenshot", "screenshot", {"app": "Calculator", "scale": 0.5}, expect=None)
    _, found, _ = b.call(t, "leer resultado", "find", {"app": "Calculator", "role": "text"}, expect=None)
    ok = "1016" in digits(found)
    b.rows.append((t, "resultado = 1016", "-", ok, 0, "" if ok else found[:110]))


def task_textedit(b, run):
    t = f"TextEdit #{run}"
    app = "TextEdit"
    b.call(t, "abrir", "open_app", {"app": app})
    b.call(t, "cmd+n (vía menú)", "key", {"app": app, "keys": "cmd+n"})
    time.sleep(0.6)
    _, shot, _ = b.call(t, "screenshot", "screenshot", {"app": app}, expect=None)
    area = next((int(re.match(r"\[(\d+)\]", l).group(1)) for l in shot.splitlines() if re.match(r"\[\d+\] textarea", l)), None)
    if area is None:
        b.rows.append((t, "textarea", "screenshot", False, 0, "no hay textarea en la lista"))
        return
    b.call(t, "escribir por índice", "type", {"app": app, "element_index": area, "text": "prueba de banco"})
    b.call(t, "añadir en el foco", "type", {"app": app, "target": "focused", "text": " ok"})
    b.call(t, "return (AX newline)", "key", {"app": app, "keys": "return"})
    b.call(t, "delete (AX backspace)", "key", {"app": app, "keys": "delete"})
    b.call(t, "clic coord (AXRangeForPosition)", "click", {"app": app, "coordinate": [200, 180], "count": 2})
    b.call(t, "cmd+a", "key", {"app": app, "keys": "cmd+a"})
    b.call(t, "freno de reemplazo", "type", {"app": app, "target": "focused", "text": "x"}, expect="unsupported")
    long_text = "\n".join(f"línea {i}" for i in range(1, 121))
    b.call(t, "reemplazo explícito (120 líneas)", "type",
           {"app": app, "target": "focused", "text": long_text, "overwrite_existing": True})
    b.call(t, "scroll arriba", "scroll", {"app": app, "element_index": area, "direction": "up", "amount": 50}, expect=None)
    b.call(t, "scroll abajo", "scroll", {"app": app, "element_index": area, "direction": "down", "amount": 5})
    b.call(t, "menú: listar barra", "menu", {"app": app, "list": True}, expect="menu bar")
    _, found, _ = b.call(t, "leer valor", "find", {"app": app, "role": "textarea"}, expect=None)
    _, shot2, _ = b.call(t, "screenshot final", "screenshot", {"app": app}, expect=None)
    ok = "línea" in shot2 or "línea" in found
    b.rows.append((t, "texto visible en el resumen", "-", ok, 0, "" if ok else shot2.splitlines()[2][:110]))


def report(b, front0, front1, cur0, cur1, schema_bytes, started):
    ok = sum(1 for r in b.rows if r[3])
    lines = [
        f"# Banco computer-use — {time.strftime('%Y-%m-%d %H:%M')}",
        "",
        f"- Pasos correctos: **{ok}/{len(b.rows)}**",
        f"- App del frente: antes `{front0}`, después `{front1}` → {'sin cambios' if front0 == front1 else '**CAMBIÓ**'}",
        f"- Cursor: antes {cur0}, después {cur1} → {'sin cambios' if cur0 == cur1 else '**se movió** (¿lo moviste tú?)'}",
        f"- Esquema de herramientas: {schema_bytes} bytes (~{schema_bytes // 4} tokens)",
        f"- Duración total: {time.time() - started:.1f} s",
        "",
        "## Latencia por herramienta (ms, ida y vuelta)",
        "",
        "| herramienta | n | mediana | p95 | máx |",
        "|---|---|---|---|---|",
    ]
    for tool, ts in sorted(b.times.items()):
        ts = sorted(ts)
        p95 = ts[min(len(ts) - 1, int(len(ts) * 0.95))]
        lines.append(f"| {tool} | {len(ts)} | {statistics.median(ts):.0f} | {p95:.0f} | {ts[-1]:.0f} |")
    lines += ["", "## Pasos", "", "| tarea | paso | ok | ms | resultado |", "|---|---|---|---|---|"]
    for task, step, tool, good, ms, detail in b.rows:
        lines.append(f"| {task} | {step} | {'✅' if good else '❌'} | {ms:.0f} | {detail.replace('|', '/')[:220]} |")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    opts = ap.parse_args()
    started = time.time()
    b = Bench()
    if "Falta el permiso de Accesibilidad" in b.s.call("list_apps")[0]:
        raise SystemExit("Falta Accesibilidad para quien lanza el banco. Ejecútalo desde la terminal de tu cliente MCP "
                         "con ese cliente activado en Accesibilidad y Grabación de pantalla.")
    schema_bytes = len(json.dumps(b.s.request("tools/list")[0]["result"]["tools"]))
    front0, cur0 = b.frontmost(), cursor()
    for run in range(1, opts.runs + 1):
        task_calculator(b, run)
        task_textedit(b, run)
    front1, cur1 = b.frontmost(), cursor()
    b.s.close()

    out_dir = os.path.join(ROOT, "bench")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"resultado-{time.strftime('%Y%m%d-%H%M%S')}.md")
    text = report(b, front0, front1, cur0, cur1, schema_bytes, started)
    open(path, "w").write(text)
    print(text)
    print(f"Informe: {path}")


if __name__ == "__main__":
    main()
