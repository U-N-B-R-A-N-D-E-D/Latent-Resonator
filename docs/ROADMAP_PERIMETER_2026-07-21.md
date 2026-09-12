# Roadmap del Perímetro — 2026-07-21

## STATUS 2026-07-27: ALL ITEMS CLOSED

Todos los puntos P1–P3 y el apéndice abajo quedaron **ejecutados en el árbol de trabajo del 2026-07-27**. El texto original se conserva como registro histórico; cada bloque incluye una nota de cierre (implementación + test).

> Esto es un mapa, no una spec. Cada punto es perímetro **declarado pero no ejecutado**:
> el tipo existe, compila, a veces incluso tiene UI — pero no participa en el
> `ExecutionPlan` que de verdad suena. No implementar nada de esto como
> efecto secundario de otro trabajo. El núcleo pull-render (`GraphAudioEngine`
> → `ExecutionPlan` → `DSPNode`, crossfade de 80ms, ring buffer SPSC, plan swap
> atómico) es sólido y **no se toca** al ejecutar estos puntos — cada fix debe
> integrarse al patrón existente (`DelayLineNode` sigue siendo la referencia),
> no reemplazarlo.

Contexto: seis auditorías independientes (Sean Booth, Richard D. James,
Alessandro Cortini, Daito Manabe, trío openFrameworks, trío TouchDesigner)
convergieron en que el perímetro declarado es más ancho que el ejecutado.
Las atribuciones de auditoría abajo son una síntesis razonada por
especialidad de cada auditor, no citas textuales.

---

## P1 — `SpectralAnalyzerNode` no conforma `DSPNode`

**Dónde:** `Graph/Nodes/AnalysisNodes.swift:9` (clase), `:93` (`override func audioUnit() -> AVAudioNode?` — el hook muerto de la era `AudioGraphMapper`).

**Por qué está muerto:** no conforma `GraphNodeDSPProvider`/`DSPNode`, así que `ExecutionPlan.build` lo saltea en silencio. Sus puertos `centroid`/`flatness`/`flux` nunca llevan un valor real dentro del grafo de render. Es el nodo que la retórica de "cybernetic feedback" / "latente como filtro recursivo" (whitepaper §3.3) asume que existe.

**Desbloquea:** feedback cibernético real — `PromptEngineNode.updateFlatness` (§4.2.2, `Graph/MacroNode.swift:841`) ya está implementado pero sin este nodo no tiene de dónde leer flatness en vivo.

**Auditoría:** trío openFrameworks / trío TouchDesigner (arquitectura de grafo: puertos que no llevan señal) + Booth (retórica declarada-no-ejecutada; ver `.cursor/skills/whitepaper-alignment/SKILL.md` STEP 3B).

**Dirección del fix:** conformar `DSPNode`/`GraphNodeDSPProvider` copiando el patrón de `DelayLineNode`; el `render()` ya tiene la lógica FFT (`analyze`/`performFFT`/`computeSpectralFeatures`), sólo falta que un `render(inputs:output:...)` real la alimente con el buffer de entrada y exponga `centroid`/`flatness`/`flux` como controles evaluables.

**Cierre 2026-07-27:** `SpectralAnalyzerNode` conforma `DSPNode` y entra en `ExecutionPlan.build`; `LatentResonatorTests/SpectralAnalyzerNodeTests.swift`.

---

## P1 — `MacroNode.render` ignora `portMappings` de entrada

**Dónde:** `Graph/MacroNode.swift:316` (firma de `render(inputs:output:frameCount:sampleRate:controls:)`) — el parámetro `inputs` se declara pero no se lee en ningún punto del cuerpo (líneas 316–382); cada `inputsBuf` interno viene de `pool.buffer(at: step.inputBufferIndices[k])`, exclusivamente del `internalPlan` propio del macro.

**Por qué está muerto:** un macro colapsado que expone un puerto de entrada externo (vía `portMappings`, `Graph/MacroNode.swift:47`) no tiene forma de que esa señal externa llegue a su cadena interna — la señal que el grafo padre conecta al puerto de entrada del macro simplemente se descarta.

**Desbloquea:** composición nodal real — encadenar macros (macro A → macro B) sin expandir B.

**Auditoría:** trío TouchDesigner (composición de nodos: un cable que no lleva señal) + trío openFrameworks.

**Dirección del fix:** en `render()`, usar `portMappings` para inyectar `inputs[i]` en el buffer interno del nodo/puerto mapeado antes de recorrer `plan.steps` — probablemente escribiendo en el `AudioBuffer` interno correspondiente al nodo mapeado antes de que su step se ejecute, respetando el contrato real-time (sin allocs, sin locks bloqueantes).

**Cierre 2026-07-27:** `MacroNode.render` inyecta entradas externas vía `portMappings` (incl. slots de audio externo); `LatentResonatorTests/MacroNodeRoutingTests.swift`.

---

## P2 — `ExecutionPlan.Step.controls` siempre vacío

**Dónde:** `Graph/Engine/ExecutionPlan.swift:40` (declaración: `let controls: [String: Float]`) y `:172` (`controls: [:] // Phase 1: control evaluation deferred`). Consumido tal cual en `Graph/Engine/GraphAudioEngine.swift:198,209` (`controls: step.controls`) y pasado a todo `DSPNode.render(...)` del proyecto.

**Por qué está muerto:** es un diccionario vacío por construcción, siempre. `ControlGraphEvaluator` (60Hz, `Graph/ControlGraphEvaluator.swift`) hace su trabajo de modulación por un camino totalmente distinto (escribe parámetros directamente vía `setParameter`/`setParam`), así que el "single clock" de control-rate que el campo `controls` prometía nunca se materializó — hoy hay dos relojes de control que no se hablan entre sí.

**Desbloquea:** que `Step.controls` sea información real en vez de placeholder — un solo punto de evaluación de control-rate en vez de dos mecanismos paralelos.

**Auditoría:** Richard D. James (integridad del "clock" de control vs. audio) + trío openFrameworks.

**Dirección del fix:** decidir UN mecanismo. O `ControlGraphEvaluator` escribe en una estructura que `ExecutionPlan.build` lee para poblar `Step.controls` antes de cada bloque, o se elimina el campo `controls` de `Step`/`DSPNode.render` y se documenta (como ya se hizo con `parameterDidChange`, ver `Graph/NodeGraph.swift`) que la modulación de control-rate vive enteramente en `ControlGraphEvaluator` + `setParam`.

**Cierre 2026-07-27:** se eliminó `ExecutionPlan.Step.controls` / el parámetro `controls` en `DSPNode.render`; contrato único vía `ControlGraphEvaluator` + `setParam`; `LatentResonatorTests/GraphNodeParamTests.swift`.

---

## P2 — `CoreMLInference` nunca se instancia

**Dónde:** `CoreMLInference.swift:32` (`final class CoreMLInference`). Cero sitios de instanciación (`CoreMLInference(`) en todo el target.

**Por qué está muerto:** existe una pipeline VAE/DiT on-device completa, pero la inferencia canónica sigue siendo `ACEStepBridge` + `Scripts/ace_bridge_server.py` sobre HTTP, exactamente como documenta el propio header del archivo.

**Desbloquea:** inferencia sin proceso Python externo, o manipulación de latentes on-device sin el roundtrip HTTP/WAV.

**Auditoría:** trío TouchDesigner (integración ML on-device es su terreno natural) + Cortini (si esto se toca, preservar la latencia de 30s como identidad, no "arreglarla" — ver preámbulo de esta tarea).

**Dirección del fix:** dos caminos válidos, elegir UNO — (a) instanciar `CoreMLInference` y wirearlo como ruta alternativa a `ACEStepBridge` detrás de un flag explícito, o (b) si el HTTP bridge sigue siendo la vía canónica indefinidamente, marcar `CoreMLInference.swift` como archivado/roadmap en su propio header en vez de dejarlo ambiguo.

**Cierre 2026-07-27:** header `CoreMLInference.swift` marcado **ARCHIVED / ROADMAP**; inferencia canónica sigue en `ACEStepBridge`; `LatentResonatorTests/InferenceParamsTests.swift`.

---

## P3 — `MarkovSequencerNode` / `GestureRecorderNode` / `AudioInputNode` sin cablear

**Dónde:**
- `Graph/Nodes/ControlNodes.swift:624` — `MarkovSequencerNode`. Registrado en `NodeFactory` (`"markov_sequencer"`); sin conformancia `DSPNode`/control-evaluation más allá de su propio cuerpo de clase.
- `Graph/Nodes/ControlNodes.swift:916` — `GestureRecorderNode`. Registrado (`"gesture_recorder"`); ningún call site de UI alimenta su `record()` con un gesto real de XY pad/crossfader.
- `Graph/Nodes/SourceNodes.swift:242` — `AudioInputNode`. Mismo patrón muerto de `audioUnit()` que `SpectralAnalyzerNode`; poner "AUDIO IN" en el canvas no rutea el micrófono al grafo de render.

**Por qué está muerto:** los tres están declarados y son colocables en el canvas (pasan validación de grafo), pero ninguno tiene un consumidor real en el `ExecutionPlan` ni en la UI en vivo.

**Desbloquea:** secuenciación probabilística real (Xenakis), captura de gestos MPE para modulación compleja, y excitación desde audio externo (mic/line) en vez de sólo osciladores/Koenig Seed internos.

**Auditoría:** Daito Manabe (control gestual/sensor en vivo — su terreno) para `GestureRecorderNode`; trío openFrameworks para `MarkovSequencerNode`/`AudioInputNode` (wiring de grafo).

**Dirección del fix:** priorizar `AudioInputNode` primero (es el más simple — requiere sólo conformar `DSPNode` leyendo del `AVAudioInputNode` ya referenciado); `MarkovSequencerNode` requiere que `SpectralAnalyzerNode` (P1) exista primero para su "temperatura por flatness"; `GestureRecorderNode` requiere un gesto real en `PatchCanvasView`/`PerformanceMotherbaseView` que llame `record()`/`play()`.

**Cierre 2026-07-27:** nodos cableados en plan + UI; fix de categoría control en validación/factory; tests `AudioInputNodeTests.swift`, `MarkovSequencerNodeTests.swift`, `GestureRecorderNodeTests.swift`.

---

## Apéndice — hallazgos adicionales (mismo tema, no priorizados arriba)

Encontrados durante esta auditoría; no forman parte de los 5 puntos pedidos, se documentan para no perderlos:

- **`MacroNode.toggleExpansion()` / `NodeGraph.expand(macroId:)` sin gesto de UI.** `Views/Patch/` no tiene ningún call site para expandir/colapsar un macro desde el canvas — la interacción "double-click to expand" documentada en `Graph/MacroNode.swift` no está cableada en `PatchCanvasView`. Ver nota agregada en `Views/Patch/PatchTypes.swift`.  
  **Cierre 2026-07-27:** doble clic en `MacroCard` → `toggleExpansion`; `LatentResonatorTests/MacroCardGestureTests.swift`.
- **`LatentResonator/PatchEditor/` (proyecto React/TypeScript) sigue trackeado en git**, no sólo fuera del target de Xcode. `.cursor/skills/v2-node-graph/SKILL.md` afirma que fue "removed from the project entirely" — es cierto para el build, no para el repositorio. No se tocó en esta pasada (fuera del alcance pedido); ver resumen de la sesión.  
  **Cierre 2026-07-27:** eliminado del repositorio por decisión del owner (`git rm -r LatentResonator/PatchEditor`, recuperable desde git history); skills `v2-node-graph` y `latent-resonator-architecture` actualizados acorde.
- **`Config/Constants.swift` → `presetFallbackProfiles`** (línea ~904) está declarado pero sin ningún sitio de lectura en el código — no es uno de los 5 nodos pedidos, se menciona sólo por completitud.  
  **Cierre 2026-07-27:** símbolo `presetFallbackProfiles` eliminado de `Constants.swift`.
