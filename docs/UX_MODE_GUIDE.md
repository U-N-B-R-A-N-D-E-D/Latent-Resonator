# Guía de los 3 Modos de Latent Resonator

## Resumen Visual

```
┌─────────────────────────────────────────────────────────────────────┐
│  SETUP MODE          →    PATCH MODE          →    PERFORM MODE      │
│  (Configuración)          (Ruteo Visual)          (Tocar en Vivo)  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  • Crear lanes           • Ver nodos de lanes      • Escenas A/B    │
│  • Ajustar parámetros    • Conectar señales       • Crossfader     │
│  • Modulación básica     • Exponer controles      • Step grid      │
│  • Elegir presets        • Crear macros           • Controles live │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## SETUP MODE (Turquesa)

**Propósito:** Configurar el sonido base de cada lane

**Qué hacer aquí:**
1. Crear lanes con el botón [+ ADD LANE]
2. Seleccionar presets (Drums, Bass, Synth, etc.)
3. Ajustar parámetros básicos (CFG, Feedback, Texture)
4. Configurar modulación (LFOs, envolventes)

**Flujo de trabajo típico:**
- Crear 3-4 lanes con diferentes sonidos
- Ajustar volumen/pan de cada uno
- Configurar modulación para movimiento
- Cuando suene bien → ir a PATCH

---

## PATCH MODE (Púrpura)

**Propósito:** Ruteo visual de señales entre nodos

**Qué hacer aquí:**
1. Ver los lanes como nodos MacroNode
2. Conectar salidas de un lane a entradas de otro
3. Agregar nodos de efectos (filtros, delay, etc.)
4. Exponer parámetros para PERFORM mode

**Flujo de trabajo típico:**
- Right-click en canvas → Add Node
- Arrastrar conexiones entre puertos
- Crear cadenas de efectos
- Exponer controles importantes
- Cuando el ruteo esté listo → ir a PERFORM

**Nota importante:**
Los lanes creados en SETUP aparecen automáticamente como nodos "macro" 
en PATCH. No empiezas de cero - los lanes ya están ahí como nodos.

---

## PERFORM MODE (Ámbar)

**Propósito:** Tocar música en vivo

**Qué hacer aquí:**
1. Cambiar entre escenas A/B (presets completos)
2. Usar el crossfader para transiciones
3. Programar secuencias en el step grid
4. Ajustar controles expuestos en tiempo real

**Flujo de trabajo típico:**
- Guardar escenas con configuraciones diferentes
- Programar secuencias rítmicas
- Tocar los knobs expuestos
- Grabar la performance

---

## Relación entre Modos

```
SETUP lanes ──────┐
                  │
PATCH nodes ──────┼──► NodeGraph (único source of truth)
                  │
PERFORM macros ───┘
```

**Datos que fluyen:**
- SETUP modifica parámetros del NodeGraph
- PATCH muestra la topología del NodeGraph
- PERFORM lee controles expuestos del NodeGraph

**Persistencia:**
- El NodeGraph se auto-guarda en cada cambio
- Los lanes se recrean al abrir la app
- Las conexiones PATCH se mantienen
- Las escenas PERFORM se mantienen

---

## Tips de Workflow

1. **Empezar en SETUP:** Crear lanes básicos primero
2. **Luego PATCH:** Si quieres efectos complejos entre lanes
3. **Finalmente PERFORM:** Cuando quieras tocar en vivo

4. **No es necesario usar PATCH:** Si solo quieres lanes básicos,
   puedes ir directo de SETUP a PERFORM.

5. **PATCH es opcional pero poderoso:** Permite routing complejo
   que no es posible en SETUP.
