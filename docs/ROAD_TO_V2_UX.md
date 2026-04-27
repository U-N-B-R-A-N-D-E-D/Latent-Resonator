# Road to v2 — UX inspirada en Envion

> Estado: propuesta. Complementa (no reemplaza) `V3_GAP_REPORT_2026-04-14.md`.
> Nota de renombrado: los documentos `MIGRATION_V3_NODAL.md` y `V3_GAP_REPORT_2026-04-14.md` deben releerse como **"Road to v2"**, no v3. Latent Resonator aún no ha alcanzado v2; este plan *es* v2.

---

## 1. Por qué Envion funciona (y nosotros todavía no)

Envion (Emiliano Pennisi, Pure Data / PlugData) consigue coherencia a través de **restricción conceptual**:

- Un átomo único: el **triplete Dynatext** `(valor, tiempo, delay)` enviado a `vline~`. Todo en Envion es una envolvente.
- Módulos **nombrados y semánticos**, no genéricos: *Nuke*, *Fallout*, *Pan Mix*, *Tape Echo*, *Flat*, *Imprintape*, *Dynagran*, *Deepscan*, *Net-Audio*. Cada uno tiene identidad.
- **Matrix routing** como vista alternativa al patching libre — las conexiones existen en una grilla, no en un canvas infinito.
- Un **reservorio** (carpeta `/data`) con miles de tripletes pre-hechos: la librería ES el instrumento.
- Filosofía explícita de **lentitud**: "invitación a reducir la velocidad, ajuste fino micro, escucha paciente".

Latent Resonator tiene *más* poder técnico (feedback recursivo neural, ACE-Step, control-rate graph) pero hoy carece de un átomo conceptual equivalente al triplete. El nodo-gráfico genérico no *es* el instrumento — es la infraestructura. Envion nos muestra qué tipo de capa encima hace falta.

---

## 2. El átomo de Latent Resonator

Envion: `(valor, tiempo, delay)` → envolvente.
Latent Resonator: `S(i+1) = ACE(S(i) + F(S(i)), T(i))` → **el ciclo de retroalimentación**.

El átomo de LR ya existe en el código: `FeedbackLoopNode` en `Graph/Nodes/NeuralNodes.swift`. Todo lo demás — osciladores, filtros, delays, secuenciador — es *alrededor* del ciclo. La UX de Road to v2 debe hacer visible esta jerarquía.

**Regla:** ningún patch por defecto puede existir sin un `FeedbackLoopNode` visible. El ciclo no es opcional, es la identidad.

---

## 3. Seis préstamos concretos de Envion

Ordenados por costo de implementación, no por importancia.

### 3.1 Etapas nombradas en lugar de nodos genéricos

**Envion:** no hay "Distortion Module 1", hay **Nuke**.
**LR hoy:** `OscillatorNode`, `LadderFilterNode`, `SpectralChainNode`.
**Propuesta:** exponer en la UI una capa de *etapas* con nombre propio sobre los nodos primitivos. Cada etapa es un `MacroNode` con un título, un color y un ícono.

Candidatos iniciales para Road to v2 (tomando del dominio de LR, no copiando Envion):

| Etapa | Rol | Nodos internos |
|---|---|---|
| **Seed** | Fuente latente | `KoenigSeedNode` + `OscillatorNode` |
| **Resonator** | Núcleo neural | `FeedbackLoopNode` (el átomo) |
| **Spectra** | Esculpido espectral | `SpectralChainNode` (FFT→EQ→Sat→Noise→Mem→Gran→Freeze→IFFT) |
| **Ladder** | Filtrado analógico | `LadderFilterNode` + `AgitationNode` |
| **Echo** | Retroalimentación temporal | delay + feedback taps |
| **Flat** | Salida directa | `MasterOutputNode` |

Esto no requiere código nuevo — solo un campo `displayName` y `stageKind` en `MacroNode` y un mapping en el editor React.

**Costo:** bajo. **Ganancia:** enorme en identidad. **Fase:** parte de B (PERFORM) del gap report.

### 3.2 Topology Reservoir — librería de patches de fábrica

**Envion:** carpeta `/data` con miles de tripletes.
**LR hoy:** `KickstartTemplate.json` roto y solitario.
**Propuesta:** directorio `Resources/Topologies/` con JSONs nombrados (`road-to-v2/seed-feedback-flat.json`, `road-to-v2/spectra-resonator-echo.json`, etc.) y un *Reservoir Browser* en la UI.

Cada topología trae:
- nombre, autor, descripción corta (una oración)
- grafo completo (nodos + edges + parámetros)
- etiquetas (`drone`, `percussive`, `noise-wall`, `glitch`)

Esto ya estaba en Phase 7 del plan de migración; simplemente lo reencuadramos como *Envion reservoir*, no como "factory presets".

**Precondición:** Parte A del gap report (audio funcionando). Sin audio no hay reservorio que escuchar.

**Costo:** medio. Requiere arreglar la persistencia del grafo y escribir 6-10 topologías iniciales a mano.

### 3.3 Matrix routing como vista alternativa

**Envion:** matriz N×N donde filas son fuentes y columnas son destinos; celdas marcan conexiones.
**LR hoy:** solo canvas React Flow libre.
**Propuesta:** en PATCH mode, añadir un toggle `Canvas ↔ Matrix`. La matriz muestra las etapas (§3.1) como filas/columnas y marca las conexiones existentes. Editar una celda añade/quita el edge en `NodeGraph`.

La matriz no reemplaza al canvas — lo complementa. Para patches pequeños (≤8 etapas) la matriz es más rápida de leer. Para patches grandes el canvas sigue siendo mejor.

**Costo:** medio-alto. Requiere un nuevo componente React que lea el mismo `GraphSnapshot`.
**Momento:** post Parte B. No bloqueante.

### 3.4 Envolventes de primera clase

**Envion:** el triplete *es* el documento editable. Toda la interacción es envelope-first.
**LR hoy:** los `MetaParameterNode` existen pero están escondidos — son un nodo más en el canvas.
**Propuesta:** panel lateral fijo en PERFORM mode con **todas las envolventes activas** del patch, editables en texto (formato triplete `valor, tiempo, delay` por línea) o gráficamente (breakpoint editor).

Esto usa infraestructura que ya existe (`MetaParameterNode`, `GestureRecorderNode`) y la expone al frente.

**Costo:** bajo-medio. El nodo ya existe; solo hay que levantarlo a un panel siempre-visible.

### 3.5 Triggers y sliders manuales prominentes

**Envion:** los transports y sliders manuales son la forma principal de *tocar* el instrumento durante la composición.
**LR hoy:** `PerformanceMotherbaseView` está reducido a un stub de 80 líneas.
**Propuesta:** reconstruir PERFORM usando `PerformLayoutEngine` (que ya existe y funciona) pero con estética Envion:

- Botones de trigger grandes, etiquetados con el nombre de la etapa (§3.1).
- Sliders XY asignables a cualquier `ExposedControl`.
- Indicadores de nivel en cada etapa activa.
- Sin pestañas de lanes — el layout es plano, el ojo ve todo el instrumento a la vez.
- Tipografía monoespaciada, paleta reducida (negro, un acento), mucho aire entre controles.

**Fuente de verdad:** `PerformanceMotherbaseView.swift.backup_v1` (1,273 líneas) como referencia de qué controles recuperar, pero *no* recuperando la pestañificación por lane.

**Costo:** medio. Es Parte B del gap report, reencuadrada con estética Envion.

### 3.6 Filosofía de restricción

**Envion:** "no es para hacer música rápida". La UI lo enuncia.
**LR:** necesita una declaración equivalente. Propuesta: en la pantalla de bienvenida, una sola frase:

> *"Latent Resonator es un instrumento recursivo. Cada parche es un bucle que se escucha a sí mismo. Escucha antes de ajustar."*

Y quitar cosas. Concretamente:
- Fuera los tooltips didácticos y wizards.
- Fuera los "quick start presets" que prometen sonido instantáneo.
- El reservorio (§3.2) sustituye la necesidad de wizards.

**Costo:** negativo — estamos borrando código.

---

## 4. Integración con el Gap Report

| Gap Report (Road to v2) | Adición Envion |
|---|---|
| **Parte A: First audio** (7 bugs) | sin cambios — bloqueante absoluto |
| **Parte B: First usable PERFORM** | reconstruir con §3.1 (etapas nombradas) + §3.5 (triggers/sliders Envion) + §3.6 (restricción) |
| **Parte C: Secuenciador** | sin cambios — `SequencerNode` ya es control-rate |
| **Nueva Parte E: Reservoir + Matrix** | §3.2 + §3.3 + §3.4 |

El orden no cambia. Envion no agrega trabajo nuevo al camino crítico — redirige el trabajo que ya está en Parte B hacia una estética y un vocabulario que tienen centro.

---

## 5. Qué hacer esta semana

1. **Parte A del gap report** — los 7 bugs de audio. Sin esto nada importa.
2. **Renombrar** `MIGRATION_V3_NODAL.md` → `ROAD_TO_V2.md` y `V3_GAP_REPORT_2026-04-14.md` → `ROAD_TO_V2_GAPS_2026-04-14.md`. Actualizar terminología "v3" → "Road to v2" en el texto.
3. **Añadir `displayName` y `stageKind`** a `MacroNode` (§3.1). Cambio mínimo, desbloquea el resto de la UX.
4. **Escribir 3 topologías de reservorio** a mano como prueba de que el formato JSON funciona — una vez Parte A esté verde.

Todo lo demás (matriz, panel de envolventes, Reservoir Browser completo) es post-audio.

---

## 6. Lo que NO copiamos de Envion

Para evitar mimetismo superficial:

- **PlugData / Pure Data.** LR es Swift + ACE-Step. No vamos a Pd.
- **Net-Audio / Deepscan.** La ingesta de archivos externos no es nuestra tesis; nuestra tesis es el bucle recursivo.
- **Los nombres literales** (Nuke, Fallout, Pan Mix). Son de Envion. LR necesita sus propios nombres (§3.1 propone seis).
- **La estética tipográfica exacta.** Inspirarse, no clonar.

Envion es el *qué se siente*, no el *qué se copia*.
