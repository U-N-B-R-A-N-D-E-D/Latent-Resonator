# Migración completa a Bespoke Synth — 2026-09-11

## Por qué

El canvas nativo (SwiftUI, custom `GraphAudioEngine` → `ExecutionPlan` → `DSPNode`) es la
fuente del dolor actual: UX pobre, sin fluidez de nodos, lag, trabas. Cuatro meses de
trabajo fueron a resolver un problema (patching visual en tiempo real) que ya está resuelto
hace 20+ años en otro lado. Lo que sí funciona y no tiene por qué tirarse es la mitad
"neuronal": el bridge Python a ACE-Step (15/15 tests) y el concepto de resonador
recursivo del whitepaper. Ver `docs/whitepaper.md` para la fórmula `S(i+1) = ACE(S(i) +
N(μ,σ), P, γ)`.

Decisión: migrar todo a **Bespoke Synth** (github.com/BespokeSynth/BespokeSynth, GPL-3,
activo — último update jun 2026) como base sobre la que corre **nuestro** proyecto.
Esto es un fork/build propio, no una contribución al proyecto de Cycling/BespokeSynth —
no se abre PR ni se coordina con su Discord. Ya existe precedente técnico directo del
patrón que necesitamos: un módulo **StableAudio3** (mayo 2026) genera audio desde un
prompt vía modelo neural, embebido como nodo del patch — lo usamos como referencia de
implementación real, no como aval de nadie.

Dato de arquitectura clave (confirmado con research, no supuesto): el cuello de botella
real es la inferencia de ACE-Step en sí (CPU local), no el host. Ningún entorno —Bespoke,
Cardinal, Pd— corre un modelo de difusión de audio en el audio callback. El patrón
validado por la industria (ver ANIRA, arXiv:2506.12665) es desacoplar la inferencia a un
thread pool y devolver el resultado a un ring buffer lock-free — exactamente lo que ya
hace `BridgeProcessManager.swift` de forma artesanal. Migrar no es resolver un problema
nuevo, es portar una solución que ya probamos, a un host con mejor UX.

Confirmado en el propio código fuente de Bespoke Synth (`Source/` del repo, vía API de
GitHub): ya trae **Python embebido de fábrica** —
`Source/ScriptModule_PythonInterface.i` (bindings SWIG) + `Source/cmake/bundle-python.cmake`
(empaqueta un runtime Python con la app). Python no es un invitado ahí, es parte del
build oficial. Esto abre una segunda vía de integración (ver Fase 3, opción B) además de la
vía por subprocess+HTTP que ya tenemos probada.

---

## Qué es "jugo real" (se preserva) vs. "spam" (se descarta)

### Real — se porta o se reusa tal cual

| Pieza | Ruta actual | Destino |
|---|---|---|
| Servidor del bridge (Flask/waitress, WAV codec, endpoints `/health` `/status` `/infer` `/shutdown`) | `LatentResonator/LatentResonator/Scripts/ace_bridge_server.py` (994 líneas) | Se copia **sin tocar** a un repo/carpeta nueva `ace-bridge/`. Es puro Python, cero dependencia de Swift. |
| Suite de tests del bridge (15/15) | `.../Scripts/test_bridge.py` | Se copia sin tocar. Sigue siendo el gate de regresión del lado Python, sin importar el host. |
| Setup/env | `requirements_bridge.txt`, `setup_ace_bridge.sh`, `.venv-ace-bridge/` | Sin tocar. |
| Modelo vendoreado | `ACE-Step/` (repo completo del proyecto upstream) | Sin tocar. |
| **Lógica de ciclo de vida del proceso** (descubrir modelo, instalar paquete si falta, descargar modelo si falta, poll de health-check, shutdown gracioso esperando inferencias en vuelo, kill-by-port de fallback) | `BridgeProcessManager.swift` (1097 líneas) | **No se porta el Swift** — se porta el *comportamiento*, ya validado en producción, a C++ dentro del nuevo módulo (Fase 3). Este archivo es la especificación, no el artefacto final. |
| Concepto del resonador recursivo, formalismo §3.3/§6.1 | `docs/whitepaper.md` (361 líneas) | Se mantiene como doc de diseño canónico; se adapta a README del módulo nuevo. |
| Prior art de comportamiento pinneado en tests Swift (21 TODOs deliberados, edge cases de `AudioPipelineValidator`/`ParameterRouterController`) | `LatentResonatorTests/*` | Se usa como checklist de verificación manual en Fase 4 — **no se porta código**, la mayoría de estos TODOs directamente dejan de aplicar (el grafo de Bespoke ya maneja disconnected-nodes, mixer, etc. nativamente). |

### Spam — se descarta sin culpa

- Todo el canvas SwiftUI: `PatchCanvasView`, `CableLayer`, `NodeCardChrome`, node cards
  (Oscillator/Delay/LadderFilter/Mixer/MasterOutput/etc.).
- El motor de grafo custom: `GraphAudioEngine`, `ExecutionPlan`, `DSPNode`, `NodeGraph`.
- `NeuralEngine.swift` (god-class), `ParameterRouterController.swift`,
  `AudioPipelineValidator.swift`, `MacroMixerController`, macro controllers, gesture recording,
  Motherbase/crossfader de escenas.
- `ACEStepBridge.swift` (el wrapper Swift del bridge — se reemplaza por el nuevo módulo C++).
- `stash@{0}` ("epitaxy: pre-switch") — confirmado muerto en la revisión anterior, se dropea.
- `LatentResonator.xcodeproj`, carpetas `dist/*.app` viejas — se archivan, no se migran.
- Los 122 tests Swift — no portables (prueban un motor que deja de existir). Se leen una
  vez como espec de comportamiento (Fase 4) y después se retiran con el resto del engine.

---

## Fases

### Fase 0 — Esto es nuestro fork, no una contribución a Bespoke

Bespoke no carga módulos externos — todo vive compilado dentro del propio binario. Eso
significa que técnicamente el único camino para tener `ModuleACEResonator` corriendo es
un **fork propio**, con nuestro módulo agregado a su árbol de fuentes y compilado como
parte de nuestro propio binario. Eso es exactamente lo que hicimos y lo que seguimos
haciendo — **no** hay intención de PR a `BespokeSynth/BespokeSynth`, ni de coordinar nada
en su Discord. Su código sigue siendo de ellos (GPL-3, Copyright Ryan Challinor); nosotros
mantenemos nuestro propio fork/build con el módulo agregado, para uso propio.

Implicancia real (no de comunidad, de licencia): Bespoke Synth es GPL-3. Si en algún
momento distribuimos un binario compilado de nuestro fork fuera de esta organización,
la GPL-3 nos obliga a poner el código fuente completo de ese fork a disposición de quien
lo reciba. Esto no bloquea nada hoy (todo el trabajo vive en nuestro propio repo, público),
pero es una obligación real a tener presente antes de un release binario, no un detalle
de cortesía.

### Fase 1 — Congelar el "jugo real" en un paquete host-agnóstico

- Extraer `ace_bridge_server.py`, `test_bridge.py`, `requirements_bridge.txt`,
  `setup_ace_bridge.sh` a una carpeta/repo independiente `ace-bridge/` (o repo propio,
  a decidir).
- Correr `test_bridge.py` de forma standalone, sin nada de Swift en el path — confirma
  que esta pieza **nunca dependió realmente del host**, lo cual valida que la migración
  de UI no arriesga esta parte.
- Congelar `docs/whitepaper.md` como está; no tocar la fórmula ni el fundamento teórico.

### Fase 2 — Bootstrap del build de Bespoke Synth (sanity check antes de programar)

```bash
git clone https://github.com/BespokeSynth/BespokeSynth   # o tu fork
cd BespokeSynth
git submodule update --init --recursive
cmake -Bignore/build -DCMAKE_BUILD_TYPE=Release
cmake --build ignore/build --parallel 4 --config Release
```

Confirmar que compila limpio ANTES de escribir el módulo nuevo. Mientras tanto, leer:
- `Source/IAudioProcessor.h` / `.cpp` — clase base de todo módulo de audio.
- `Source/ModuleContainer.h` — cómo el host registra/orquesta módulos.
- `Source/ScriptModule.cpp` / `ScriptModule_PythonInterface.i` — el Python embebido, para
  evaluar la opción B de la Fase 3.
- Un módulo comparable ya existente en su árbol de fuentes (ideal: el propio
  `StableAudio3`, o `SamplePlayer` como ya se usó) como referencia de estilo real,
  no inventado.

### Fase 3 — Portar el ciclo de vida del bridge a un módulo nuevo

Nuevo módulo: `Source/ModuleACEResonator.cpp/h`, hereda de `IAudioProcessor`.

**Opción A — subprocess + HTTP (recomendada para el primer landing, menor riesgo):**
- Reusa `ace_bridge_server.py` sin modificar.
- Porta *el comportamiento* (no el código) de `BridgeProcessManager.swift` a C++:
  descubrimiento de modelo, instalación/descarga si falta, poll de `/health`, `/infer`
  disparado en background thread (nunca en el audio callback — mismo patrón validado por
  ANIRA), shutdown gracioso vía `/shutdown` esperando inferencias en vuelo, kill-by-port
  de fallback. Usar `juce::ChildProcess` (Bespoke es JUCE-based) en vez de
  `Process`/`URLSession`.
- El resultado (WAV bytes) se decodifica y se escribe a un ring buffer lock-free que
  `Process()` drena en cada callback de audio — esta es la reimplementación real de
  `S(i+1) = ACE(S(i)+N(μ,σ), P, γ)` como nodo de Bespoke.
- UI mínima estilo Bespoke (ImGui): campo de prompt, knobs para γ/μ/σ, botón de trigger.

**Opción B — Python embebido nativo (explorar después, no bloquea el v1):**
- Usar el `ScriptModule` existente para llamar ACE-Step in-process, sin Flask ni subprocess.
- Riesgo real: el intérprete embebido de Bespoke tiene su propio Python empaquetado
  (`bundle-python.cmake`) — instalar torch + deps de ACE-Step ahí puede chocar con lo que
  ya tenemos andando en `.venv-ace-bridge/`. Se evalúa como v2 una vez que la Opción A esté
  funcionando de punta a punta en nuestro fork.

### Fase 4 — Validar contra el comportamiento viejo, no contra el código viejo

- Releer los 21 TODOs de producción de `ParameterRouterController.swift` /
  `AudioPipelineValidator.swift` / `NeuralEngine.swift` como checklist: confirmar cuáles
  ya no aplican (el grafo/mixer de Bespoke los resuelve nativamente) y cuáles, si alguno,
  siguen siendo responsabilidad del nuevo módulo.
- Gate de regresión: `test_bridge.py` sigue en 15/15, sin tocar.
- Smoke test manual: levantar Bespoke, agregar el módulo nuevo, disparar `/infer`, confirmar
  arranque/cierre limpio del subprocess sin huérfanos — la misma barra de verificación que
  ya se usó para el `.app` de Swift.

### Fase 5 — Nuestro propio fork/release, sin PR a nadie

- Pasar `clang-format` (el propio `.clang-format` del repo) — buena práctica de código,
  no un requisito de aprobación externa.
- Mantener el fork de Bespoke Synth con `ModuleACEResonator` agregado como el build que
  usamos y distribuimos nosotros. Documentar claramente en el README de ese fork que los
  pesos del modelo NO se bundlean (son locales, no van en git) — mismo criterio que ya
  usábamos para el repo Swift.
- Si en algún momento tiene sentido compartir el módulo con el proyecto original, es una
  decisión de producto a evaluar más adelante — no un paso de este plan.

### Fase 6 — Dar de baja el repo Swift

- Taguear el estado final (`v2.0-final-native-canvas`) antes de archivar — no se borra
  historia.
- Dropear `stash@{0}` (ya confirmado muerto en la revisión anterior).
- Retirar `LatentResonator.xcodeproj`, el canvas SwiftUI, el motor de grafo custom y los
  122 tests Swift asociados.
- Actualizar el `README.md` raíz para apuntar a nuestro fork de Bespoke Synth (con
  `ModuleACEResonator` incorporado) como proyecto vivo, enlazando `docs/whitepaper.md`
  como fundamento conceptual.

---

## Riesgos a vigilar

- **Licencia GPL-3 de Bespoke Synth**: al usar su código como base de nuestro fork,
  cualquier binario que distribuyamos de ese fork queda sujeto a GPL-3 — código fuente
  completo disponible para quien lo reciba. No es un tema de "pedir permiso", es una
  obligación legal a cumplir al momento de un release, no antes.
- **CPU local sigue siendo el techo real**: migrar de host no cambia la velocidad de
  inferencia de ACE-Step en CPU. Si la latencia por bloque sigue siendo alta, el patrón
  ring-buffer + thread pool la absorbe (no bloquea el audio), pero la "sensación" de
  resonador recursivo en vivo depende de conseguir GPU en algún momento — esto es
  independiente de la migración y no lo resuelve por sí sola.
- **Opción B (Python embebido) es la más incierta** — no evaluar hasta tener Opción A
  funcionando de punta a punta en nuestro fork.
- **Mantener un fork implica arrastrar sus futuros cambios manualmente** (rebase/merge
  periódico contra `BespokeSynth/BespokeSynth` upstream si queremos sus mejoras) — costo
  de mantenimiento a largo plazo que no existía con el canvas 100% propio, a cambio de no
  tener que mantener nosotros mismos un motor de UI de audio en tiempo real.
