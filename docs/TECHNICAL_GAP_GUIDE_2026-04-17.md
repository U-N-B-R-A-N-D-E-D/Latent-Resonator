# Latent Resonator — Guía Técnica para Cerrar Gaps

> **Fecha:** 2026-04-17
> **Objetivo:** Cerrar la brecha entre el estado actual y un instrumento tan poderoso como Envion, con inferencia ACE nativa y prompting ajustable por nodo.
> **Alineación:** 100% whitepaper — `S(i+1) = ACE(S(i) + N(μ,σ), P, γ)`

---

## 0. Diagnóstico: Dónde estamos vs. Dónde queremos estar

### Lo que Envion logra (y LR debe igualar o superar)

Envion es un ecosistema en Pure Data donde el átomo es el triplete Dynatext — miles de envolventes dinámicas esculpiendo micro-eventos. Su poder viene de la restricción conceptual + libertad topológica. No tiene inferencia neural; toda la complejidad emerge de la recursión y el enrutamiento.

LR tiene una ventaja estructural enorme: el feedback loop neural. Donde Envion manipula envolventes sobre samples, LR pasa audio entero por un modelo de difusión que lo transforma semánticamente. Pero esa ventaja está dormida porque el audio no fluye y la inferencia está atada a un bridge HTTP con PyTorch/MPS.

### Estado actual (verificado 2026-04-17)

| Componente | Estado | Bloqueante |
|---|---|---|
| 40+ nodos implementados | ✅ | — |
| NodeGraph.swift (1,038 líneas) | ✅ | — |
| AudioGraphMapper (496 líneas) | ⚠️ Untested, bugs A.1-A.7 | **SÍ** |
| ACEStepBridge HTTP client | ✅ Funcional | — |
| ace_bridge_server.py (Flask) | ✅ Funcional | — |
| React PATCH editor | ✅ Funcional | — |
| PerformanceMotherbaseView | ❌ 80-line stub | **SÍ** |
| KickstartTemplate.json | ❌ No deserializa | **SÍ** |
| MasterOutputNode | ❌ audioUnit() → nil | **SÍ** |
| Per-node prompting | ⚠️ PromptEngine existe, no wired | Parcial |
| MLX inference | ❌ No existe | Aspiracional |

---

## 1. FASE CERO — Audio Vivo (2-3 días)

Nada importa si no sale sonido. Esto ya está documentado en `ROAD_TO_V2_GAPS_2026-04-14.md` (fixes A.1→A.7). No lo repito completo, pero el orden es sagrado:

**A.1** ClosedRange<Float> Codable → **A.2** KickstartTemplate.json formato → **A.3** MasterOutputNode mixer → **A.4** isGraphConnected() → **A.5** Eliminar early-return silencioso → **A.6** loadGraphOrBootstrap() con logging → **A.7** Verificar que suena 220 Hz saw.

**Criterio de éxito:** App lanza → saw wave 220 Hz suena por los speakers.

---

## 2. FASE UNO — Prompting Ajustable por Nodo (1-2 semanas)

Esto es lo que separa a LR de todo lo demás. No es "un prompt global" — es que **cada nodo en el grafo puede influir semánticamente** en cómo ACE transforma el audio. Es la libertad del artista de conjugar cualquier instrumento virtualmente.

### 2.1 Arquitectura actual del PromptEngine

`NeuralNodes.swift` ya define `PromptEngineNode` con 3 fases evolutivas conducidas por spectral flatness. Esto es correcto pero incompleto:

**Lo que falta:**

**a) Prompt por MacroNode, no global.** Cada macro-nodo (el equivalente de lo que era un lane) necesita su propio PromptEngine con sus propias 3 fases. El `ACEStepInferenceNode` ya tiene un port `PROMPT` de tipo `text` — lo que falta es que el PATCH editor exponga un editor de texto por cada PromptEngine en el grafo, y que el usuario pueda escribir prompts distintos por macro.

**Implementación:**
```
MacroNode "MOOG BASS" → PromptEngine("ferrofluid, subharmonic, warm resonance")
MacroNode "ACID LEAD" → PromptEngine("acid, squelchy, TB-303, metallic")  
MacroNode "NOISE BED" → PromptEngine("granular entropy, white noise as structure")
```

**b) Semantic Profiles dinámicos.** `LRConstants.semanticProfiles` tiene 80+ entries hardcodeados. Necesitamos que el usuario pueda crear perfiles nuevos desde el prompt. Cuando el PromptEngine recibe un prompt, debería generar un perfil semántico (vector de 4 bandas) usando keyword matching o, mejor, un embedding ligero.

**c) UI de edición de prompts en PATCH editor.** Cada PromptEngineNode en el React Flow editor necesita un panel expandible donde el usuario escribe/edita las 3 fases del prompt y ajusta los thresholds de flatness.

### 2.2 Prompt Blending en el FeedbackLoop

Cuando el `FeedbackLoopNode` hace la inferencia recursiva `S(i+1) = ACE(S(i) + N(μ,σ), P, γ)`, el prompt `P` debería poder interpolarse entre fases suavemente, no con cortes duros. 

**Implementación:** Interpolar entre los embeddings de fase 1 y fase 2 usando el valor de flatness como `t`:
```
P_effective = lerp(P_phase1, P_phase2, smoothstep(flatness, threshold_low, threshold_high))
```

Esto ya es posible a nivel del bridge — el prompt es un string, pero ACE-Step internamente tokeniza y embede. Para interpolación real necesitaríamos exponer los embeddings del LLM planner, lo cual es un cambio en `ace_bridge_server.py`. Alternativa pragmática: concatenar ambos prompts con pesos textuales ("70% ferrofluid warm resonance, 30% spectral drift artifacts").

---

## 3. FASE DOS — MLX como Backend de Inferencia (2-4 semanas)

### 3.1 La oportunidad real

ACE-Step 1.5 **ya tiene backend MLX oficial** desde el repo principal. El script `start_api_server_macos.sh` hace `export ACESTEP_LM_BACKEND="mlx"`. Además existe un fork (`clockworksquirrel/ace-step-apple-silicon`) con un backend MLX-LM completo (567 líneas) que:

- Auto-convierte modelos Qwen3 a formato MLX en primer uso
- Soporta quantización 4-bit y 8-bit
- Cadena de fallback: MLX → PyTorch MPS → error

El pipeline completo en Apple Silicon es:
```
LLM Planner (Qwen3 0.6B) → MLX nativo, 2-3x más rápido que PyTorch MPS
DiT Diffusion Renderer    → PyTorch MPS (no hay port MLX del DiT aún)
VAE Decoder               → PyTorch MPS con tiling reducido para Metal
```

### 3.2 Qué cambiar en LR

**Opción A — Mínimo viable (recomendada): Actualizar el bridge server**

El `ace_bridge_server.py` actual usa `ACEStepPipeline` puro de PyTorch. El cambio es:

1. Actualizar ACE-Step a la versión que incluye `mlx_lm_backend.py`
2. Pasar `--backend mlx` al inicializar el pipeline
3. Verificar que `ACESTEP_LM_BACKEND="mlx"` está seteado en `BridgeProcessManager.swift` al spawnar el proceso Python

Esto acelera el componente LLM (planificación semántica) ~2-3x sin tocar nada de Swift.

**Benchmarks esperados en M1 Pro 16GB:**
- Turbo (8 steps, 30s audio): ~45 segundos
- SFT (32 steps, 30s audio): ~3 minutos
- LLM reasoning (0.6B): ~10 segundos (MLX) vs ~25 segundos (PyTorch MPS)

**Opción B — Ambiciosa: MLX nativo sin bridge HTTP**

Eliminar Flask/Waitress y usar MLX directamente desde Swift vía `mlx-swift` + un wrapper Python embebido. Esto eliminaría la latencia HTTP (~5-15ms por roundtrip) y el overhead de base64 WAV encoding.

**Por qué NO hacer esto ahora:** 
- El DiT (el componente pesado) sigue siendo PyTorch MPS — no hay port MLX del DiT de ACE-Step
- El overhead HTTP es despreciable comparado con 45+ segundos de inferencia
- Romper el bridge ahora reintroduciría inestabilidad cuando la prioridad es que el audio fluya

**Cuándo hacerlo:** Cuando alguien porte el DiT de ACE-Step a MLX nativo (y eso lo haría el upstream, no nosotros).

### 3.3 Lo que NO tiene sentido

- **CoreML:** Requiere conversión estática del modelo. ACE-Step usa diffusers con pasos dinámicos + LLM autoregresivo. La conversión a CoreML sería extremadamente compleja y perdería flexibilidad.
- **ONNX:** Mismo problema — el pipeline es demasiado dinámico para un grafo estático.
- **JavaScript/WebAssembly:** Ni de broma. Los modelos son de 2-6GB y requieren GPU compute.

---

## 4. FASE TRES — PERFORM Mode Funcional (2-3 semanas)

Documentado en `ROAD_TO_V2_GAPS_2026-04-14.md` secciones B.1→B.3. Lo más crítico:

### 4.1 Lo que hace a LR un instrumento (no un generador)

La diferencia entre LR y cualquier app de "AI music generation" es que LR es **performable en tiempo real**. El artista no escribe un prompt y espera — el artista manipula la topología, los parámetros DSP, y el prompting *mientras el feedback loop corre*.

Para lograr esto:

**a) XY Pad vinculado a parámetros del macro-nodo activo** (B.1.4)
- Eje X: cualquier parámetro expuesto (ej: `guidanceScale` de ACEStepInference)
- Eje Y: cualquier parámetro expuesto (ej: `inputStrength` del FeedbackLoop)
- El artista navega el espacio paramétrico en tiempo real

**b) Exposed controls auto-generados** (B.1.5)
- `PerformLayoutEngine.swift` (211 líneas) ya existe
- Lee los `exposedControls` del macro-nodo y genera knobs automáticamente
- El artista expone los controles que quiere en PATCH → aparecen en PERFORM

**c) Scene Crossfader** (B.2)
- Capturar snapshots de estados del grafo (scene A, scene B)
- Crossfadear entre ellos = morphing de todos los parámetros simultáneamente
- Esto es el equivalente de Envion's Dynatext pero a nivel de grafo neural completo

---

## 5. FASE CUATRO — Topología Completa del Whitepaper (1-2 semanas)

Una vez que las fases 0-3 están estables, upgradeamos KickstartTemplate al grafo completo:

```
KoenigSeed ──→ LadderFilter ──→ SpectralChain ──→ FeedbackLoopNode ──→ Mixer ──→ MasterOutput
                                                         ↑ feedback edge │
                                                         │               │
                                                   ACEStepInferenceNode  │
                                                         ↑               │
                                                   PromptEngine          │
                                                   (3 fases, flatness-driven)
                                                                         
SequencerNode ──→ (gate) ──→ KoenigSeed.trigger
SequencerNode ──→ (control) ──→ FeedbackLoopNode.feedbackAmount (P-Lock)
```

**Esto es el momento donde LR deja de ser un demo y se convierte en el instrumento del whitepaper.** El usuario escucha la tesis: excitación geométrica → transformación neural recursiva → emergencia del Machine Ghost.

---

## 6. FASE CINCO — Factory Macro-Nodes: El Catálogo de Instrumentos (3-4 semanas)

Cada macro-nodo es un instrumento virtual completo con su propia cadena DSP y su propio prompt semántico:

| Macro-Node | Cadena | Prompt Semántico |
|---|---|---|
| MOOG BASS | SAW → FFT → SemanticEQ → ... → LP 120Hz | "subharmonic warmth, analog saturation, Moog ladder" |
| TB-303 ACID | SQUARE → ... → LP 350Hz + resonance | "acid squelch, resonant filter sweep, 303 character" |
| BUCHLA PERC | KOENIG → ... → BP 1.4kHz | "metallic percussion, Buchla timbres, plucked resonance" |
| ROLAND PAD | SINE → ... → HP 400Hz | "ethereal pad, spectral shimmer, slow evolution" |
| NOISE SCAPE | NOISE → ... → HP 2.5kHz | "granular entropy, noise floor as structure, microsound" |

**Cada uno con su PromptEngine de 3 fases.** El artista puede cargar "MOOG BASS", editar el prompt a "ferrofluid bass, underwater resonance", y el modelo transformará el audio de manera completamente diferente. Esa es la libertad.

---

## 7. Roadmap Consolidado

| Fase | Duración | Entregable | Dependencias |
|---|---|---|---|
| 0 — Audio Vivo | 2-3 días | 220 Hz saw suena | Ninguna |
| 1 — Per-Node Prompting | 1-2 semanas | Prompts editables por macro en PATCH | Fase 0 |
| 2 — MLX Backend | 2-4 semanas | LLM planner 2-3x más rápido | Fase 0 |
| 3 — PERFORM Mode | 2-3 semanas | XY pad + knobs + crossfader | Fase 0 |
| 4 — Topología Whitepaper | 1-2 semanas | Grafo completo con feedback neural | Fases 0, 1 |
| 5 — Factory Macros | 3-4 semanas | 7 instrumentos virtuales con prompts | Fases 1, 3, 4 |

**Fases 1, 2 y 3 pueden ejecutarse en paralelo** después de Fase 0.

**Estimación total a instrumento completo:** ~10-14 semanas desde hoy.

---

## 8. Sobre LoopMaker (Signal vs. Noise)

**Veredicto: Noise.** No encontré nada técnicamente relevante. "LoopMaker" en el App Store son apps genéricas de loop-making (Kirstie Moffat, Gismart) — ni inferencia local, ni Apple Silicon optimization, ni nada comparable a lo que LR hace. Si hay algo interesante en ese post de Reddit específico, no pude acceder al contenido (Reddit bloqueado), pero por el contexto del subreddit (r/MacOSApps) es probable que sea una herramienta de consumo, no un instrumento de investigación.

LR no compite en esa categoría. LR compite con Envion en el espacio de instrumentos algorítmicos experimentales — con la ventaja diferencial de tener un modelo de difusión como procesador no-lineal. Nadie más está haciendo eso.

---

## 9. Sobre MLX vs. JavaScript (respuesta directa)

**MLX es el camino correcto.** ACE-Step ya lo soporta oficialmente para el LLM planner (Qwen3). El fork de clockworksquirrel demuestra que funciona en producción con quantización 4/8-bit.

**JavaScript nunca fue opción real.** Los modelos son de 2-6GB, requieren GPU compute (difusión iterativa), y WebAssembly/WebGPU no tiene el throughput necesario para inferencia de difusión en tiempo real.

**El plan pragmático:**
1. **Ahora:** Actualizar `ace_bridge_server.py` para usar `--backend mlx` en el LLM. Cambio de ~20 líneas.
2. **Cuando upstream lo soporte:** Migrar DiT a MLX nativo. Esto eliminará PyTorch como dependencia.
3. **Nunca:** CoreML, ONNX, JavaScript para este caso de uso.

---

*Alineado al whitepaper. Construido para el artista.*
