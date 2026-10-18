# Comparación con el computer use nativo de Claude

Dos niveles. El primero mide la herramienta sola; el segundo, el agente completo.

## 1. Mecánica (sin modelo)

- **Nuestro servidor:** `scripts/bench.py` desde la terminal integrada de Antigravity → `bench/resultado-*.md`.
- **Nativo de Claude:** Claude ejecuta las mismas dos tareas (Calculadora 127×8, TextEdit escribir/reemplazar/scroll) con sus herramientas y anota tiempo y resultado en la misma tabla.

## 2. Agente de punta a punta

El mismo texto a los dos agentes, empezando con las apps cerradas. Marco sigue usando el Mac mientras tanto (prueba de segundo plano).

1. «En Calculadora calcula 127 × 8 y dime el resultado.»
2. «Abre TextEdit, crea un documento y escribe una lista de compras de 5 cosas; pon el título en negrita.»
3. «En Notas crea una nota "Prueba MCP" con tres líneas y dime cuántas notas hay en esa carpeta.»
4. «En Vista Previa abre el último PDF de Descargas y dime cuántas páginas tiene.»
5. «En Finder busca los archivos .xlsx de Documentos modificados esta semana y dime sus nombres.»

## Planilla

| tarea | agente | ¿logrado? | tiempo | pasos (llamadas) | ¿te quitó el teclado/ratón? | notas |
|---|---|---|---|---|---|---|
| 1 | Antigravity + computer-use | | | | | |
| 1 | Claude nativo | | | | | |
| 2 | Antigravity + computer-use | | | | | |
| 2 | Claude nativo | | | | | |
| 3 | Antigravity + computer-use | | | | | |
| 3 | Claude nativo | | | | | |
| 4 | Antigravity + computer-use | | | | | |
| 4 | Claude nativo | | | | | |
| 5 | Antigravity + computer-use | | | | | |
| 5 | Claude nativo | | | | | |

Para decidir: ¿logrado? pesa más que el tiempo. Un fallo silencioso (dice «ok» y no pasó) cuenta peor que un `unsupported` claro.
Ojo: el nivel 2 compara también los modelos (Gemini contra Claude), no solo las herramientas. El nivel 1 aísla la herramienta.
