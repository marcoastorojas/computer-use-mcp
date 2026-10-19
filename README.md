# computer-use-mcp

Servidor **MCP (stdio)** nativo en **Swift** para que un agente controle apps de escritorio de macOS **en segundo plano**: no trae la app al frente ni mueve tu cursor. Solo usa APIs públicas de macOS (Accesibilidad, ScreenCaptureKit, CGEvent).

Agnóstico al modelo/IDE: funciona con cualquier cliente MCP.

## Windows

El repositorio incluye un **backend para Windows** en `windows/` (Node.js + un worker nativo en C# que se compila solo, sin SDK) con las mismas 14 herramientas y el mismo formato de resultados: **UI Automation**, captura con **PrintWindow** e input de fondo por mensajes de ventana. Requisitos, compilación, configuración y limitaciones en [`windows/README.md`](windows/README.md).

## Un solo registro MCP para macOS y Windows

`bin/computer-use-mcp.js` arranca el backend que toca según el sistema (el binario Swift en macOS, `windows/` en Windows) y, si no defines `COMPUTER_USE_CONFIG`, usa el `config.json` de cada sistema (`config.json` en macOS, `windows/config.json` en Windows). Así la entrada del cliente MCP es la misma en las dos máquinas; solo cambia la ruta al repo:

```jsonc
{
  "mcp": {
    "computer-use": {
      "type": "local",
      "command": ["node", "/ruta/a/computer-use-mcp/bin/computer-use-mcp.js"],
      "enabled": true
    }
  }
}
```

Necesita Node.js en las dos máquinas. En macOS puedes seguir registrando el binario directamente como se explica abajo si prefieres no depender de Node.

El resto de este README describe el backend de macOS.

## Compilar

```bash
./build.sh
```

Deja el binario en `.build/release/computer-use-mcp`. Al arrancar, cada instancia se relanza desde su propia copia en la carpeta temporal: el servicio de captura de macOS reconoce a los clientes por la ruta, y dos instancias con la misma ruta se bloqueaban.

Regístralo en la configuración MCP de tu cliente. Ejemplo (config de OpenCode):

```jsonc
{
  "mcp": {
    "computer-use": {
      "type": "local",
      "command": ["/ruta/a/computer-use-mcp/.build/release/computer-use-mcp"],
      "environment": {
        "COMPUTER_USE_CONFIG": "/ruta/a/computer-use-mcp/config.json"
      },
      "enabled": true
    }
  }
}
```

## Permisos (los das tú a mano)

macOS atribuye los permisos al **proceso responsable**, no al binario: el responsable es el **cliente MCP** que lanza el servidor. En Configuración del Sistema → Privacidad y seguridad activa tu cliente MCP en:

1. **Accesibilidad** (clics, teclas, leer elementos).
2. **Grabación de pantalla y audio del sistema** (capturas). Después reinícialo.

Si falta alguno, la herramienta responde con el nombre exacto de la app a activar. Para comprobarlo tú mismo:

```bash
~/computer-use-mcp/.build/release/computer-use-mcp --doctor
```

(El responsable es el proceso que lo lanza: si lo ejecutas desde tu terminal, el responsable es esa terminal, no el cliente MCP.)

## Configuración

`config.json` → `allowed_apps` (nombre o bundle id). Las demás se rechazan. Se relee solo; no hace falta reiniciar. Llaveros, gestores de contraseñas y Configuración del Sistema están bloqueados siempre.

Otros ajustes: `max_elements` (60), `ax_budget_ms` (150), `jpeg_quality` (0.8), `max_image_edge` (1600), `phantom_cursor_idle_ms` (0 = nunca se auto-oculta; > 0 = ms de inactividad antes de ocultarlo).

Variables de entorno:

| Variable | Descripción |
|---|---|
| `COMPUTER_USE_CONFIG` | Ruta a `config.json` (tiene prioridad sobre la búsqueda automática). |
| `COMPUTER_USE_NO_PROMPT` | `1` para no mostrar diálogos de permiso. |

## Herramientas (14)

| Herramienta | Qué hace |
|---|---|
| `list_apps` | Apps abiertas y si están permitidas. |
| `list_windows(app)` | Ventanas con su `window_id`. |
| `open_app(app)` | Abre la app sin traerla al frente. |
| `hide_cursor` | Oculta el cursor fantasma al terminar la tarea (permanece visible hasta entonces). |
| `screenshot(app, window_id?, scale?)` | Imagen de UNA ventana (aunque esté tapada) + lista numerada `[N]` de elementos accionables. |
| `click` | Clic por `element_index`, `coordinate` o `target:"focused"`. |
| `type(text, overwrite_existing?)` | Inserta texto en el cursor; no reemplaza todo el campo salvo `overwrite_existing: true`. |
| `key(keys)` | Teclas y atajos (`"return"`, `"cmd+s"`); los atajos con cmd se pulsan por su ítem de menú. |
| `scroll(direction, amount?)` | Mueve la barra de scroll y dice la posición nueva. |
| `drag(to)` | Arrastre dentro de una ventana. |
| `menu(path \| list)` | Ejecuta o lista comandos de la barra de menús por título. |
| `zoom(region, scale?)` | Recorte a densidad completa, solo para leer. |
| `find(role?, title_contains?)` | Busca en los elementos del último screenshot. |
| `batch(actions[])` | Varias acciones en orden; para en el primer fallo; admite `screenshot` y `wait`. |

**Coordenadas:** siempre puntos de la ventana (origen arriba a la izquierda) en el marco que informa el último screenshot, aunque la imagen venga reducida con `scale`.

**Resultados:** `ok …`, `unsupported(motivo y qué usar)`, `ineffective(…)` o `error: …`, con la latencia al final (`[N ms]`).

**Cómo actúa:** primero accesibilidad (AXPress, foco, AXSelectedText/AXValue, valor de la barra de scroll, ítems de menú). Solo si no hay equivalente manda un evento de ratón o teclado dirigido al proceso; en ese caso el resultado lo dice y pide confirmar con un screenshot.

**Frenos:** apps fuera de la lista, campos de contraseña (no escribe en ellos) y reemplazo completo de un campo sin `overwrite_existing`.

## Pruebas

```bash
scripts/test_stdio.py                 # initialize + tools/list + list_apps
scripts/test_stdio.py --app Notes     # screenshot, menú, find, zoom y latencia (necesita permisos)
scripts/test_stdio.py --write         # clic/escritura/teclas en un documento nuevo de TextEdit
```

El permiso se mide para quien lanza la prueba: para probar lo que verá tu cliente MCP, ejecútalas desde su terminal integrada.

## Licencia

MIT
