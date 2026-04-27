# v2.0 Nodal Architecture - Status & Testing Plan

## Status Actual (13 Apr 2026)

### ✅ FUNCIONANDO
| Componente | Status | Notas |
|------------|--------|-------|
| Bridge Swift ↔ JS | ✅ | Eventos sincronizados (`graph.sync`) |
| Creación de nodos | ✅ | Nodos aparecen en canvas |
| Renderizado React Flow | ✅ | Nodos visibles con UI |
| NodeFactory | ✅ | 28 tipos de nodos registrados |
| Graph serialization | ✅ | Guarda/carga de grafo |
| WebViewBridge | ✅ | Comunicación bidireccional estable |

### 🔧 COMPLETADO EN MIGRACIÓN
- [x] Eliminación de `ResonatorLane.swift`
- [x] Eliminación de `SpectralProcessorShim.swift`
- [x] Migración a `MacroNode` para encapsulación
- [x] `SequencerNode` reemplaza lane-based sequencing
- [x] `ImplicitGraphBuilder` stubbed (v1.x compat)
- [x] WebViewBridge actualizado para v2.0
- [x] Fix crítico: `graph.fullSync` → `graph.sync`

### ⚠️ PENDIENTE DE VERIFICACIÓN
| Componente | Prioridad | Riesgo |
|------------|-----------|--------|
| Conexiones audio entre nodos | Alta | AudioGraphMapper necesita testing |
| Conexiones control (CV) | Alta | ModulationEngine integración |
| Exposición de parámetros | Media | Macro binding UI |
| MacroNode encapsulate/expand | Media | Funcionalidad compleja |
| Audio routing real | Alta | Verificar que el audio fluye |
| Persistencia de escenas | Media | GraphSnapshot vs LaneSnapshot |

---

## Nodos Disponibles (28 tipos)

### 🔊 Fuentes (Sources)
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| Oscillator | `oscillator` | Sine/saw/square con pitch drift | ✅ Crea |
| Noise | `noise` | Colored noise (pink/brown/white) | ✅ Crea |
| Audio Input | `audio_input` | Mic/line input externo | ✅ Crea |
| Koenig Seed | `koenig_seed` | Generador semilla procedural | ✅ Crea |

### 🎛️ Filtros & Efectos (Filter/Effect)
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| Ladder Filter | `ladder_filter` | Moog-style resonant LPF | ✅ Crea |
| Comb Filter | `comb_filter` | Filtro peine para resonancias | ✅ Crea |
| Tunable Resonator | `tunable_resonator` | Resonador sintonizable | ✅ Crea |
| Bit Crusher | `bit_crusher` | Degradación digital | ✅ Crea |
| Waveshaper | `waveshaper` | Distorsión no-lineal | ✅ Crea |
| Delay Line | `delay_line` | Línea de retardo variable | ✅ Crea |

### 🌀 Espectral (Spectral)
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| FFT Analysis | `fft_analysis` | Análisis espectral entrada | ✅ Crea |
| Semantic EQ | `semantic_eq` | EQ por regiones semánticas | ✅ Crea |
| Spectral Saturation | `spectral_saturation` | Saturación por bandas | ✅ Crea |
| Spectral Noise | `spectral_noise` | Inyección de ruido espectral | ✅ Crea |
| Spectral Memory | `spectral_memory` | Memoria/buffer espectral | ✅ Crea |
| Spectral Granularity | `spectral_granularity` | Control granularidad FFT | ✅ Crea |
| Spectral Freeze | `spectral_freeze` | Congelamiento espectral | ✅ Crea |
| IFFT Synthesis | `ifft_synthesis` | Resíntesis IFFT | ✅ Crea |
| Spectral Chain | `spectral_chain` | Cadena espectral completa | ✅ Crea |

### 🧠 Neural (AI)
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| ACE Step Inference | `ace_step_inference` | Generación ML ACE-Step | ✅ Crea |
| Prompt Engine | `prompt_engine` | Motor de prompts semánticos | ✅ Crea |
| Feedback Loop | `feedback_loop` | Loop realimentación con AI | ✅ Crea |
| Prompt Bank | `prompt_bank` | Banco de prompts presets | ✅ Crea |

### 🎹 Control (Modulation)
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| Agitation | `agitation` | LFO/modulación aleatoria | ✅ Crea |
| Peak | `peak` | Detector de picos | ✅ Crea |
| Manual Control | `manual_control` | Control manual UI | ✅ Crea |
| Meta Parameter | `meta_parameter` | Parámetro meta-abstracto | ✅ Crea |
| Markov Sequencer | `markov_sequencer` | Secuenciador Markov | ✅ Crea |
| Gesture Recorder | `gesture_recorder` | Grabadora de gestos XY | ✅ Crea |
| Step Sequencer | `step_sequencer` | Secuenciador pasos 16/32 | ✅ Crea |

### 📊 Análisis & Routing
| Nodo | Tipo | Descripción | Estado |
|------|------|-------------|--------|
| Mixer | `mixer` | Mezclador 4 canales | ✅ Crea |
| Master Output | `master_output` | Salida maestra | ✅ Crea |
| Passthrough | `passthrough` | Passthrough transparente | ✅ Crea |
| Silence | `silence` | Nodo silencio (null sink) | ✅ Crea |
| Spectral Analyzer | `spectral_analyzer` | Análisis/display espectral | ✅ Crea |
| Reverb | `reverb` | Reverberación Schroeder-Moorer | ✅ Crea |

---

## Plan de Testing Sistemático

### Fase 1: Creación de Nodos (IN PROGRESS)

**Procedimiento:**
1. Abrir vista PATCH
2. Desplegar menú de nodos (sidebar derecha)
3. Seleccionar cada tipo de nodo
4. Verificar:
   - Nodo aparece en canvas
   - UI de parámetros renderiza correctamente
   - Nodo tiene puertos de entrada/salida visibles
   - Posición inicial es válida (no NaN/Inf)

**Checklist:**
```
[ ] oscillator - UI renderiza, pitch drift funciona
[ ] noise - UI renderiza, tipo de ruido cambiable
[ ] audio_input - UI renderiza
[ ] ladder_filter - UI renderiza, cutoff/resonance presentes
[ ] comb_filter - UI renderiza
[ ] fft_analysis - UI renderiza
[ ] semantic_eq - UI renderiza
[ ] ace_step_inference - UI renderiza (aunque backend esté en passthrough)
[ ] reverb - UI renderiza, parámetros accesibles
[ ] mixer - UI renderiza, 4 canales visibles
[ ] step_sequencer - UI renderiza, grid de pasos visible
[ ] agitation - UI renderiza
[ ] manual_control - UI renderiza, knob XY funciona
```

### Fase 2: Conexiones (PENDING)

**Audio Connections:**
```
[ ] oscillator → ladder_filter (audio)
[ ] noise → comb_filter (audio)
[ ] ladder_filter → mixer (audio)
[ ] mixer → master_output (audio)
[ ] fft_analysis → spectral processing → ifft_synthesis
[ ] Verificar que edges aparecen en UI
[ ] Verificar que edge data persiste en node_graph.json
```

**Control Connections:**
```
[ ] agitation → oscillator.pitch (CV)
[ ] manual_control → ladder_filter.cutoff (CV)
[ ] step_sequencer → mixer.gain (CV)
[ ] Verificar que señales de control llegan al destino
```

### Fase 3: Exposición de Parámetros (PENDING)

```
[ ] Right-click en parámetro → "Expose"
[ ] Verificar que aparece en exposedControlsList
[ ] Verificar que se guarda en node_graph.json
[ ] Verificar que aparece en UI de PerformanceMotherbaseView
[ ] Test macro binding (un exposed control → múltiples targets)
[ ] Test unexpose (remove)
```

### Fase 4: MacroNode Operations (PENDING)

```
[ ] Seleccionar múltiples nodos
[ ] Encapsular → crear MacroNode
[ ] Verificar que nodos internos desaparecen del canvas principal
[ ] Verificar que MacroNode aparece con puertos apropiados
[ ] Expandir MacroNode → nodos vuelven al canvas
[ ] Persistencia: guardar/cargar con MacroNodes
```

### Fase 5: Audio Routing Real (PENDING)

```
[ ] Crear chain: oscillator → ladder_filter → master_output
[ ] Verificar que AudioGraphMapper crea AVAudioNodes correctamente
[ ] Verificar conexiones AVAudioEngine
[ ] Test playback con audio real
[ ] Test DSP en cada nodo (verificar que procesa audio)
```

### Fase 6: Persistencia (PENDING)

```
[ ] Guardar grafo complejo con todos los tipos de nodos
[ ] Cerrar app
[ ] Reabrir y verificar que grafo carga correctamente
[ ] Verificar que posiciones de nodos persisten
[ ] Verificar que conexiones persisten
[ ] Verificar que parámetros expuestos persisten
```

---

## Errores Conocidos / Workarounds

### 🚨 CRÍTICO - Arreglado
| Error | Fix | Archivo |
|-------|-----|---------|
| Nodos no aparecían en Patch Editor | Event name mismatch `graph.fullSync` → `graph.sync` | `App.tsx:224` |

### ⚠️ WARNING - Aceptable por ahora
| Warning | Impacto | Nota |
|---------|---------|------|
| `ImplicitGraphBuilder: v2.0 stub` | v1.x presets no cargan | Necesita rewrite completo para backward compat |
| `ace_step package not found` | Neural nodes en passthrough | Instalar `pip install ace-step` para ML |
| `OSC: TCP listener failed` | Puerto 1337 en uso | Solo afecta OSC TCP, UDP funciona |

### 🔧 TECH DEBT - Requiere atención futura
| Item | Prioridad | Nota |
|------|-----------|------|
| `ImplicitGraphBuilder.swift` | Media | Rewrite para v1.x preset compat |
| `AudioGraphMapper` testing | Alta | Necesita test exhaustivo de routing |
| `ModulationEngine` CV routing | Alta | Verificar que control signals funcionan |
| Error handling en bridge | Media | Mejorar mensajes de error al usuario |

---

## Archivos Clave v2.0

### Core Architecture
```
LatentResonator/Graph/
├── NodeGraph.swift          # Modelo central del grafo
├── GraphNode.swift          # Protocolo base GraphNode
├── BaseGraphNode.swift      # Implementación base con params
├── GraphEdge.swift          # Conexiones entre nodos
├── GraphMutation.swift      # Mutaciones transaccionales
├── MacroNode.swift          # Encapsulación de subgrafos
└── AudioGraphMapper.swift   # NodeGraph → AVAudioEngine

LatentResonator/Graph/Nodes/
├── SourceNodes.swift        # Oscillator, Noise, AudioInput
├── FilterEffectNodes.swift  # LadderFilter, CombFilter, etc
├── SpectralNodes.swift      # FFT, SemanticEQ, etc
├── NeuralNodes.swift        # ACEStep, PromptEngine
├── ControlNodes.swift       # Agitation, Peak, ManualControl
├── RoutingNodes.swift       # Mixer, MasterOutput
├── AnalysisNodes.swift      # SpectralAnalyzer
├── SequencerNodes.swift     # StepSequencer
└── ReverbNode.swift         # Schroeder-Moorer reverb

LatentResonator/WebView/
├── WebViewBridge.swift      # Swift side del bridge
└── PatchViewCoordinator.swift # WKWebView lifecycle

PatchEditor/src/
├── bridge.ts                # JS side del bridge
├── App.tsx                  # React Flow application
└── nodes/*.tsx              # Componentes UI de nodos
```

---

## Comandos Útiles

### Build PatchEditor
```bash
cd LatentResonator/PatchEditor
npm run build
```

### Clean & Build Xcode
```
⌘+Shift+K  # Clean Build Folder
⌘+B        # Build
⌘+R        # Run
```

### Debug Bridge
1. Safari → Develop → [Mac] → LatentResonator
2. Consola JS: verificar logs `[JS BRIDGE]` y `[JS INJECTED]`
3. Xcode Console: verificar logs `[PATCH DEBUG]`

### Verificar Graph Guardado
```bash
cat ~/Library/Application\ Support/LatentResonator/node_graph.json | jq .
```

---

## Próximos Pasos Sugeridos

1. **Completar Fase 1**: Probar creación de todos los 28 tipos de nodos
2. **Fase 2**: Probar conexiones audio básicas (osc → filter → mixer → master)
3. **Fase 3**: Probar exposición de parámetros y macro bindings
4. **Fase 4**: Verificar que el audio realmente fluye (test auditivo)
5. **Fase 5**: Test persistencia completa

---

*Documento generado: 13 Apr 2026*
*Versión: v2.0 Nodal Architecture - Post Bridge Fix*
