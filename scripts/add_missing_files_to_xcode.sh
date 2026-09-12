#!/bin/bash

# Script para agregar archivos faltantes al proyecto Xcode
# Uso: ./scripts/add_missing_files_to_xcode.sh

set -e

PROJECT_DIR="/Users/leolambertini/RLTNAS/LatentResonator"
PROJECT_FILE="$PROJECT_DIR/LatentResonator.xcodeproj"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Agregar archivos faltantes al proyecto Xcode"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Verificar que el proyecto existe
if [ ! -d "$PROJECT_FILE" ]; then
    echo "❌ ERROR: No se encontró el proyecto Xcode en $PROJECT_FILE"
    exit 1
fi

# Archivos que deben agregarse
MISSING_FILES=(
    "LatentResonator/Graph/Nodes/SequencerNodes.swift"
    "LatentResonator/Graph/ImplicitGraphBuilder.swift"
    "LatentResonator/Graph/Nodes/ReverbNode.swift"
)

# Verificar que los archivos existen en disco
echo "📁 Verificando archivos en disco..."
ALL_EXIST=true
for file in "${MISSING_FILES[@]}"; do
    FULL_PATH="$PROJECT_DIR/$file"
    if [ -f "$FULL_PATH" ]; then
        echo "   ✅ $file"
    else
        echo "   ❌ $file (NO EXISTE)"
        ALL_EXIST=false
    fi
done
echo

if [ "$ALL_EXIST" = false ]; then
    echo "❌ ERROR: Algunos archivos no existen en disco"
    exit 1
fi

# Verificar estado actual en el proyecto
echo "🔍 Verificando estado en proyecto Xcode..."
for file in "${MISSING_FILES[@]}"; do
    BASENAME=$(basename "$file")
    if grep -q "$BASENAME" "$PROJECT_FILE/project.pbxproj"; then
        echo "   ⚠️  $BASENAME ya está en el proyecto"
    else
        echo "   ❌ $BASENAME NO está en el proyecto"
    fi
done
echo

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  INSTRUCCIONES MANUALES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "⚠️  Modificar project.pbxproj programáticamente es arriesgado."
echo "    Sigue estos pasos en Xcode:"
echo
echo "1. Abre el proyecto:"
echo "   open \"$PROJECT_FILE\""
echo
echo "2. En el Project Navigator (⌘1), haz clic derecho en:"
echo "   • Carpeta 'Graph' → Add Files to \"LatentResonator\"..."
echo "   • Selecciona: ImplicitGraphBuilder.swift"
echo "   • ✅ Marca 'Add to targets: LatentResonator'"
echo "   • Click 'Add'"
echo
echo "3. Repite para la carpeta 'Nodes':"
echo "   • Carpeta 'Graph/Nodes' → Add Files to \"LatentResonator\"..."
echo "   • Selecciona: SequencerNodes.swift, ReverbNode.swift"
echo "   • ✅ Marca 'Add to targets: LatentResonator'"
echo "   • Click 'Add'"
echo
echo "4. Clean Build Folder:"
echo "   Shift+Cmd+K"
echo
echo "5. Build:"
echo "   Cmd+B"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Ofrecer abrir Xcode automáticamente
read -p "¿Abrir Xcode ahora? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "$PROJECT_FILE"
    echo "✅ Xcode abierto. Sigue las instrucciones arriba."
else
    echo "ℹ️  Puedes abrir Xcode manualmente con:"
    echo "   open \"$PROJECT_FILE\""
fi

echo
echo "Después de agregar los archivos, verifica con:"
echo "  cd LatentResonator && xcodebuild -project LatentResonator.xcodeproj -scheme LatentResonator -showBuildSettings | grep -i \"build\""
