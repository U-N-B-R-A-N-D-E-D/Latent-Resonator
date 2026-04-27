# Xcode Project Setup — v2.0 Migration

## Critical: Missing Files in Xcode Project

Después de la migración a v2.0, algunos archivos Swift existen en el disco pero **NO están incluidos en el proyecto Xcode** (`.pbxproj`), lo que causa errores de compilación tipo `Cannot find type 'SequencerNode'`.

### Archivos que necesitan agregarse manualmente:

1. **`Graph/Nodes/SequencerNodes.swift`** — CRÍTICO
   - Define `SequencerNode`, usado en `SequencerEngine`, `NeuralEngine`, y UI views
   - Sin este archivo, el proyecto no compila

2. **`Graph/ImplicitGraphBuilder.swift`** — Necesario
   - Construye grafos desde presets v1.x (backward compatibility)
   - Usado por `MacroNode.fromPreset()`

3. **`Graph/Nodes/ReverbNode.swift`** — Opcional
   - Nodo de reverb Schroeder-Moorer
   - Puede agregarse si se planea usar reverb

---

## Cómo agregar archivos al proyecto Xcode

### Opción 1: Vía Xcode UI (Recomendado)

1. Abre el proyecto en Xcode:
   ```bash
   open LatentResonator/LatentResonator.xcodeproj
   ```

2. En el **Project Navigator** (⌘1), haz clic derecho en la carpeta **LatentResonator** → **Add Files to "LatentResonator"...**

3. Navega a cada archivo:
   - `LatentResonator/Graph/Nodes/SequencerNodes.swift`
   - `LatentResonator/Graph/ImplicitGraphBuilder.swift`
   - `LatentResonator/Graph/Nodes/ReverbNode.swift` (opcional)

4. En el diálogo de "Add Files":
   - ✅ **Copy items if needed** (desmarcado, ya están en el directorio correcto)
   - ✅ **Create groups** (seleccionado)
   - ✅ **Add to targets: LatentResonator** (marcado)

5. Haz clic en **Add**

### Opción 2: Verificar Target Membership

Si los archivos ya aparecen en el Project Navigator pero siguen dando error:

1. Selecciona el archivo en Xcode
2. Abre el **File Inspector** (⌥⌘1)
3. En la sección **Target Membership**:
   - ✅ Marca el checkbox del target `LatentResonator`

---

## Verificar que todo esté listo

### 1. Clean Build Folder

Después de agregar los archivos, limpia el build cache:

```bash
# Opción A: Vía Xcode
# Shift+Cmd+K (Clean Build Folder)

# Opción B: Vía Terminal
cd LatentResonator
rm -rf ~/Library/Developer/Xcode/DerivedData/LatentResonator-*
```

### 2. Build

```bash
# Cmd+B en Xcode
```

### 3. Errores esperados: NINGUNO

Si todo está correctamente configurado, el proyecto debe compilar sin errores.

---

## Troubleshooting

### Error: "Cannot find type 'SequencerNode'"

**Causa:** `SequencerNodes.swift` no está en el proyecto o no tiene target membership.

**Fix:**
1. Verifica que el archivo esté en el Project Navigator
2. Selecciona el archivo → File Inspector (⌥⌘1) → Target Membership: ✅ LatentResonator

### Error: "Cannot find type 'SpectralFeatureSnapshot'"

**Causa:** `SpectralProcessor.swift` no tiene target membership.

**Fix:**
1. Selecciona `SpectralProcessor.swift` en el Project Navigator
2. File Inspector (⌥⌘1) → Target Membership: ✅ LatentResonator

### Error: "Invalid redeclaration of 'updateMacroMixerState()'"

**Causa:** Cache de Xcode compilando contra versión vieja del archivo.

**Fix:**
```bash
# Clean Derived Data
rm -rf ~/Library/Developer/Xcode/DerivedData/LatentResonator-*

# En Xcode:
# Shift+Cmd+K (Clean Build Folder)
# Cmd+B (Build)
```

### Archivos fantasma: "Build input files cannot be found: ResonatorLane.swift"

**Causa:** Referencias a archivos eliminados siguen en `.pbxproj`.

**Fix:**
1. En Xcode Project Navigator, busca archivos en rojo (referencias rotas)
2. Clic derecho → **Delete** → **Remove Reference** (no mover a Trash)
3. Clean + Build

---

## Estado del Proyecto: v2.0 Canonical

### ✅ Archivos Correctamente Eliminados

- `ResonatorLane.swift` — Reemplazado por `MacroNode`
- `DSP/SpectralProcessorShim.swift` — v1.x compatibility layer (obsoleto)
- `Graph/ImplicitGraphBuilder.swift` referencias legacy (ya no necesita include) ❌ **CORRECCIÓN:** Este archivo ES necesario, debe incluirse

### ✅ Arquitectura v2.0 Completa

- **NodeGraph**: Fuente de verdad única (flat, no jerárquico)
- **MacroNode**: Reemplazo conceptual de "lane" (encapsula subgrafos)
- **SequencerNode**: Secuenciador gráfico (reemplaza step grid per-lane)
- **GraphSnapshot**: Persistencia de parámetros de nodos (reemplaza `LaneSnapshot`)

### ✅ Backward Compatibility (v1.x)

- `focusLane` / `focusLaneId`: Computed properties que mapean a `focusMacro` / `focusMacroId`
- `lanes` property: Ahora retorna `[MacroNode]` en lugar de `[ResonatorLane]`
- `ImplicitGraphBuilder`: Convierte presets v1.x a grafos v2.0

---

## Referencias

- **Migración completa:** `docs/MIGRATION_V3_NODAL.md`
- **Arquitectura v2.0:** `docs/ARCHITECTURE_v2_NODAL.md`
- **Whitepaper:** `docs/LATENT_RESONATOR_WHITEPAPER.md`

---

## ¿Todo listo?

Si después de:
1. Agregar archivos faltantes
2. Clean build folder
3. Build

...el proyecto compila sin errores, **el setup está completo y el proyecto está listo para testear**.
