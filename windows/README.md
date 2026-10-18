# computer-use-mcp — backend Windows

Servidor **MCP (stdio)** para que un agente controle apps de escritorio de **Windows** en segundo
plano: no trae la app al frente ni mueve tu cursor. Expone las **mismas 14 herramientas** que el
backend de macOS, con el mismo formato de resultados, así que un agente (o un prompt/skill) sirve
igual en los dos sistemas.

- **UI Automation** para leer y accionar elementos (Invoke, Toggle, Select, Expand, Value, Scroll).
- **PrintWindow** para capturar una ventana concreta aunque esté tapada.
- **Mensajes de ventana** para el ratón y el teclado de fondo, con el estado de modificadores
  (`ctrl`, `shift`, `alt`) puesto en el hilo de la app, así que los atajos funcionan sin foco.

## Requisitos

- Windows 10/11.
- **Node.js 18+** (probado con 24).
- Nada más: el worker nativo (`native/Worker.cs`) se compila con el compilador de C# que trae
  .NET Framework 4, incluido en Windows. No hace falta SDK ni Visual Studio.

## Compilar y probar

```powershell
cd windows
npm install
npm run build            # TypeScript + worker nativo (native/bin/cu-worker.exe)

node dist\index.js --doctor
node scripts\test_stdio.js                          # initialize + tools/list + list_apps
node scripts\test_stdio.js --app notepad --write    # escribe en una pestaña NUEVA de Notepad
node scripts\test_stdio.js --app calc --calc        # 7 × 8 = 56 con los botones de la Calculadora
```

Si cambias `native/Worker.cs`, el servidor lo recompila solo al arrancar (compara fechas).

## Registrar en tu cliente MCP

Lo más cómodo es el lanzador común de la raíz del repo: **el mismo comando sirve en macOS y en
Windows** (en cada sistema arranca su backend y usa su `config.json`):

```jsonc
{
  "mcp": {
    "computer-use": {
      "type": "local",
      "command": ["node", "C:/ruta/a/computer-use-mcp/bin/computer-use-mcp.js"],
      "enabled": true
    }
  }
}
```

También puedes registrar el backend directamente:
`["node", "C:/ruta/a/computer-use-mcp/windows/dist/index.js"]` con
`COMPUTER_USE_CONFIG` apuntando a `windows/config.json`.

## Configuración

`config.json` → `allowed_apps`: nombre del proceso (`notepad`, `excel`), nombre del exe
(`midapp.exe`) o la descripción que muestra `list_apps` (`"Calculadora"`). Los nombres de
lanzador conocidos cuentan como la app real: `calc` permite la Calculadora de Windows 11 aunque
su proceso se llame `CalculatorApp`. Las demás apps se rechazan, y `list_apps` no muestra los
títulos de sus ventanas. El archivo se relee solo.

Siempre bloqueadas, aunque las añadas: gestores de contraseñas, Seguridad de Windows,
Configuración (`SystemSettings`), UAC (`consent`), pantallas de credenciales.

| Clave | Por defecto | Descripción |
|---|---|---|
| `allowed_apps` | `[]` | Apps permitidas. |
| `max_elements` | `60` | Máximo de elementos listados por screenshot (el resto, con `find`). |
| `ax_budget_ms` | `400` | Tiempo máximo para recorrer el árbol de UI Automation. |
| `jpeg_quality` | `0.8` | Calidad del JPEG del screenshot. |
| `max_image_edge` | `1600` | Lado máximo de la imagen (se reescala; las coordenadas no cambian). |
| `phantom_cursor_idle_ms` | `0` | 0 = el cursor fantasma no se oculta solo; > 0 = ms de inactividad antes de ocultarlo. |

Variables de entorno:

| Variable | Descripción |
|---|---|
| `COMPUTER_USE_CONFIG` | Ruta a `config.json`. |
| `COMPUTER_USE_WORKER_EXE` | Usar otro `cu-worker.exe` (uso avanzado). |
| `COMPUTER_USE_NO_CURSOR` | `1` = no dibujar el cursor fantasma. |
| `COMPUTER_USE_DEBUG` | `1` = el worker escribe diagnósticos en stderr. |

## Cómo actúa

| Herramienta | En Windows |
|---|---|
| `screenshot` | PrintWindow (contenido DirectComposition incluido) en paralelo con el recorrido de UI Automation. Recorta los bordes invisibles, así que imagen y coordenadas coinciden. Los elementos tapados por scroll o fuera de su vista no se listan. Si la ventana estaba minimizada, la restaura sin activarla. |
| `click` | Invoke / Toggle / Select / Expand de UI Automation; si no hay, un clic de fondo al control hijo bajo el punto, con modificadores. Tras el clic informa de los elementos y ventanas (menús, popups, diálogos) que se abrieron. |
| `type` | En controles Edit/RichEdit inserta en el cursor con `EM_REPLACESEL` (se puede deshacer); en el resto, ValuePattern o teclas de fondo. Si el campo no tenía el cursor puesto, añade al final. Nunca escribe en campos de contraseña. |
| `key` | Atajos de edición en controles Edit/RichEdit como mensajes exactos (`ctrl+a/c/x/v/z`, `ctrl+home/end`); atajos de la barra de menús clásica ejecutan su comando; el resto, teclas de fondo con los modificadores en el estado del hilo de la app. `cmd` equivale a `ctrl`. |
| `scroll` | ScrollPattern (informa la posición nueva, 0–1); si no, rueda de fondo. |
| `menu` | Menús clásicos (HMENU) sin abrirlos en pantalla; menús WinUI/WPF por UI Automation (se abren un instante y se cierran). |
| `hide_cursor` | Desvanece el cursor fantasma. |

**Cursor fantasma**, como en macOS: una flecha violeta con borde blanco que se desliza hasta el
punto de cada `click`, `type`, `scroll` y `drag`; en los clics y arrastres hace una pequeña
pulsación con onda. Se queda visible toda la tarea hasta `hide_cursor` (o
`phantom_cursor_idle_ms`). Es una ventana transparente a los clics que nunca se activa: no roba
el foco, no tapa tu ratón y no sale en los screenshots de las ventanas.

**Foco:** si una app se pone delante sola al accionar un control (las apps UWP como la
Calculadora lo hacen en cada botón), el foco vuelve a la ventana que tenías; la app puede
asomar un instante.

## Limitaciones

- **Apps WinUI 3 / XAML Islands** (Explorador de Windows 11, partes de Notepad): leer, hacer clic
  y escribir en sus campos funciona, pero algunas teclas (p. ej. `return` en la barra de
  direcciones del Explorador) solo las recibe el campo con el foco real. Para abrir una carpeta,
  `open_app` con la ruta es más fiable.
- **Apps UWP** (Calculadora): los botones van perfectos por UI Automation; las teclas de fondo
  llegan solo en parte.
- **Render por GPU**: algunas ventanas (juegos, ciertos Chromium con aceleración) salen en negro
  con PrintWindow si no están delante; el texto lo avisa y la lista de elementos sigue valiendo.
- **Apps como administrador**: Windows (UIPI) bloquea la entrada desde un proceso no elevado.
  `list_apps` las marca y las acciones lo explican; ejecuta el cliente MCP como administrador si
  necesitas controlarlas.
- `drag` en segundo plano es lo menos fiable: confírmalo con un `screenshot`.
- Las coordenadas son píxeles físicos de la ventana (el proceso es *per-monitor DPI aware*).

## Arquitectura

```
src/index.ts       Servidor MCP: JSON-RPC por stdio, esquemas, --doctor.
src/tools.ts       Las 14 herramientas: sesiones por app, objetivos, formato de resultados, batch.
src/config.ts      allowed_apps, alias y apps siempre bloqueadas.
src/worker.ts      Lanza el worker y habla con él (una línea JSON por mensaje); lo reinicia si muere o se cuelga.
src/native.ts      Compila native/Worker.cs con el csc.exe de .NET Framework.
native/Worker.cs   Worker nativo: UI Automation con CacheRequest, captura, ratón/teclado de fondo, menús, cursor fantasma.
```

## Licencia

MIT
