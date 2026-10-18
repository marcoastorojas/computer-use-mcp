#!/usr/bin/env python3
"""Prueba del servidor MCP por stdio.

  scripts/test_stdio.py                 initialize + tools/list + list_apps
  scripts/test_stdio.py --app Finder    además screenshot/find/menu/zoom de esa app (necesita permisos)
  scripts/test_stdio.py --app Finder --save /ruta/captura.jpg
  scripts/test_stdio.py --write         prueba de acciones en un documento nuevo de TextEdit
                                        (abre TextEdit en segundo plano y deja el documento sin guardar)

No pide permisos: si faltan, lo dice y sigue.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, ".build", "release", "computer-use-mcp")


class Server:
    def __init__(self):
        env = dict(os.environ, COMPUTER_USE_NO_PROMPT="1")
        self.proc = subprocess.Popen([BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.next_id = 0

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}
        start = time.perf_counter()
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        ms = (time.perf_counter() - start) * 1000
        if not line:
            raise SystemExit(f"FALLO: el servidor cerró la salida en {method}")
        reply = json.loads(line)
        assert reply.get("id") == self.next_id, reply
        return reply, ms

    def call(self, name, args=None):
        reply, ms = self.request("tools/call", {"name": name, "arguments": args or {}})
        result = reply["result"]
        text = "\n".join(c["text"] for c in result["content"] if c["type"] == "text")
        images = [c for c in result["content"] if c["type"] == "image"]
        return text, images, result.get("isError", False), ms

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def show(title, text, ms):
    print(f"\n── {title}  ({ms:.0f} ms ida y vuelta)")
    print(text)


def write_test(s):
    """Acciones reales sobre un documento nuevo de TextEdit. Necesita Accesibilidad."""
    app = "TextEdit"
    failures = []

    def step(title, name, args, expect):
        text, _, _, ms = s.call(name, dict(args, app=app))
        ok = text.startswith(expect)
        print(f"{'PASA ' if ok else 'FALLA'} {title}: {text.splitlines()[0][:150]}")
        if not ok:
            failures.append(title)
        return text

    if "Falta el permiso de Accesibilidad" in s.call("list_apps")[0]:
        print("OMITIDA la prueba de acciones: falta el permiso de Accesibilidad (ver nota de list_apps)")
        return
    step("abrir sin traer al frente", "open_app", {}, "ok")
    step("cmd+n por la barra de menús", "key", {"keys": "cmd+n"}, "ok")
    time.sleep(0.8)
    shot = step("screenshot con elementos", "screenshot", {}, "")
    area = next((l for l in shot.splitlines() if l.startswith("[") and "textarea" in l), None)
    if not area:
        print("FALLA no hay textarea en el resumen; no se sigue\n" + shot)
        return
    index = int(area[1:area.index("]")])
    step("clic por índice (enfoca)", "click", {"element_index": index}, "ok")
    step("escribir por índice", "type", {"element_index": index, "text": "hola desde MCP"}, "ok")
    step("escribir en el foco (añade)", "type", {"target": "focused", "text": " 123"}, "ok")
    step("seleccionar todo", "key", {"keys": "cmd+a"}, "ok")
    step("freno: no reemplaza todo", "type", {"target": "focused", "text": "x"}, "unsupported")
    step("reemplazo explícito", "type", {"target": "focused", "text": "reemplazado\nlinea 2", "overwrite_existing": True}, "ok")
    step("tecla suelta", "key", {"keys": "return"}, "ok")
    step("scroll", "scroll", {"direction": "down", "element_index": index}, "ok")
    step("menú: listar", "menu", {"list": True}, "menu bar")
    final = step("lote con captura final", "batch", {"actions": [
        {"action": "type", "target": "focused", "text": "fin"}, {"action": "screenshot", "scale": 0.5}]}, "1. type: ok")
    if "reemplazado" not in final:
        failures.append("el texto final no aparece en el resumen")
        print("FALLA el resumen final no muestra el texto escrito")
    print("\nAcciones: " + ("todas pasan" if not failures else f"{len(failures)} fallo(s): " + "; ".join(failures)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", help="app permitida y abierta para la prueba funcional")
    ap.add_argument("--save", help="guardar la captura en esta ruta")
    ap.add_argument("--runs", type=int, default=5, help="repeticiones de screenshot para medir latencia")
    ap.add_argument("--write", action="store_true", help="probar clic/escritura/teclas en TextEdit")
    opts = ap.parse_args()

    if not os.path.exists(BINARY):
        raise SystemExit(f"No existe {BINARY}; ejecuta ./build.sh")
    s = Server()

    reply, ms = s.request("initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "test_stdio", "version": "1"},
    })
    info = reply["result"]
    assert info["serverInfo"]["name"] == "computer-use" and "tools" in info["capabilities"], info
    print(f"initialize OK: {info['serverInfo']} protocolo {info['protocolVersion']} ({ms:.0f} ms)")
    s.notify("notifications/initialized")

    reply, ms = s.request("tools/list")
    tools = reply["result"]["tools"]
    names = [t["name"] for t in tools]
    expected = ["list_apps", "list_windows", "open_app", "screenshot", "click", "type", "key",
                "scroll", "drag", "menu", "zoom", "find", "batch"]
    assert names == expected, names
    for t in tools:
        schema = t["inputSchema"]
        assert schema["type"] == "object" and all(r in schema["properties"] for r in schema.get("required", [])), t["name"]
    size = len(json.dumps(tools))
    print(f"tools/list OK: {len(names)} herramientas, {size} bytes de esquema ({ms:.0f} ms)")

    reply, _ = s.request("no/existe")
    assert reply["error"]["code"] == -32601
    text, _, is_error, ms = s.call("screenshot", {"app": "Keychain Access"})
    assert is_error, text

    text, _, is_error, ms = s.call("list_apps")
    assert not is_error and "pid" in text, text
    show("list_apps", text, ms)

    if opts.app:
        app = opts.app
        text, _, _, ms = s.call("list_windows", {"app": app})
        show("list_windows", text, ms)

        times = []
        for _ in range(opts.runs):
            text, images, is_error, ms = s.call("screenshot", {"app": app})
            times.append(ms)
        show("screenshot", text, ms)
        print(f"latencia screenshot ({opts.runs} llamadas): " + ", ".join(f"{t:.0f}" for t in times)
              + f" ms; mediana {sorted(times)[len(times) // 2]:.0f} ms")
        if images:
            data = base64.b64decode(images[0]["data"])
            print(f"imagen: {images[0]['mimeType']}, {len(data) // 1024} KB")
            if opts.save:
                with open(opts.save, "wb") as f:
                    f.write(data)
                print(f"guardada en {opts.save}")
        else:
            print("imagen: ninguna (ver motivo arriba)")

        for name, args in [
            ("menu", {"app": app, "list": True}),
            ("find", {"app": app, "role": "button"}),
            ("zoom", {"app": app, "region": [0, 0, 300, 60]}),
            ("batch", {"app": app, "actions": [{"action": "wait", "ms": 50}, {"action": "screenshot", "scale": 0.3}]}),
        ]:
            text, images, _, ms = s.call(name, args)
            show(name, text + (f"\n[{len(images)} imagen(es)]" if images else ""), ms)

    if opts.write:
        write_test(s)

    s.close()
    print("\nTODO OK" if not (opts.app or opts.write) else "\nFin de la prueba funcional (revisa arriba lo que falte por permisos)")


if __name__ == "__main__":
    main()
