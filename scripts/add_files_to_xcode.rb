#!/usr/bin/env ruby
# Script para agregar archivos Swift faltantes al proyecto Xcode
# Modifica el project.pbxproj de forma segura

require 'securerandom'
require 'fileutils'

PROJECT_DIR = "/Users/leolambertini/RLTNAS/LatentResonator"
PBXPROJ = "#{PROJECT_DIR}/LatentResonator.xcodeproj/project.pbxproj"
BACKUP_FILE = "#{PBXPROJ}.backup_#{Time.now.to_i}"

# Archivos a agregar: [path_relativo, nombre_archivo, grupo_parent]
FILES_TO_ADD = [
  { path: "Graph/Nodes/SequencerNodes.swift", name: "SequencerNodes.swift", group: "Nodes" },
  { path: "Graph/ImplicitGraphBuilder.swift", name: "ImplicitGraphBuilder.swift", group: "Graph" },
  { path: "Graph/Nodes/ReverbNode.swift", name: "ReverbNode.swift", group: "Nodes" }
]

def generate_uuid
  SecureRandom.uuid.gsub('-', '').upcase[0..23]
end

def backup_project
  puts "📦 Creando backup: #{File.basename(BACKUP_FILE)}"
  FileUtils.cp(PBXPROJ, BACKUP_FILE)
end

def restore_backup
  puts "⚠️  Restaurando backup..."
  FileUtils.cp(BACKUP_FILE, PBXPROJ)
end

def add_files_to_project
  content = File.read(PBXPROJ)
  
  # Verificar que no estén ya agregados
  FILES_TO_ADD.each do |file|
    if content.include?(file[:name])
      puts "⚠️  #{file[:name]} ya está en el proyecto, omitiendo..."
      return false
    end
  end
  
  puts "\n🔧 Modificando project.pbxproj..."
  
  # Generar UUIDs únicos para cada archivo
  file_refs = FILES_TO_ADD.map do |file|
    {
      uuid: generate_uuid,
      build_uuid: generate_uuid,
      **file
    }
  end
  
  # 1. Agregar PBXFileReference entries
  pbx_file_refs = file_refs.map do |f|
    "\t\t#{f[:uuid]} /* #{f[:name]} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"#{f[:name]}\"; sourceTree = \"<group>\"; };"
  end.join("\n")
  
  # Insertar después de la última PBXFileReference
  content.sub!(/(\t\t[A-F0-9]+ \/\* .+\.swift \*\/ = \{isa = PBXFileReference;[^\}]+\};)\n((?:\n|\t)*\/\* End PBXFileReference)/) do
    "#{$1}\n#{pbx_file_refs}\n#{$2}"
  end
  
  # 2. Agregar a PBXGroup (Graph y Nodes)
  # Para Graph group
  graph_files = file_refs.select { |f| f[:group] == "Graph" }
  unless graph_files.empty?
    graph_children = graph_files.map { |f| "\t\t\t\t#{f[:uuid]} /* #{f[:name]} */," }.join("\n")
    content.sub!(/(\/\* Graph \*\/ = \{[^;]+children = \([^)]+)(\n\t\t\t\);)/) do
      "#{$1}\n#{graph_children}#{$2}"
    end
  end
  
  # Para Nodes group
  nodes_files = file_refs.select { |f| f[:group] == "Nodes" }
  unless nodes_files.empty?
    nodes_children = nodes_files.map { |f| "\t\t\t\t#{f[:uuid]} /* #{f[:name]} */," }.join("\n")
    content.sub!(/(\/\* Nodes \*\/ = \{[^;]+children = \([^)]+)(\n\t\t\t\);)/) do
      "#{$1}\n#{nodes_children}#{$2}"
    end
  end
  
  # 3. Agregar a PBXSourcesBuildPhase
  build_files = file_refs.map do |f|
    "\t\t#{f[:build_uuid]} /* #{f[:name]} in Sources */ = {isa = PBXBuildFile; fileRef = #{f[:uuid]} /* #{f[:name]} */; };"
  end.join("\n")
  
  content.sub!(/(\t\t[A-F0-9]+ \/\* .+\.swift in Sources \*\/ = \{isa = PBXBuildFile;[^\}]+\};)\n((?:\n|\t)*\/\* End PBXBuildFile)/) do
    "#{$1}\n#{build_files}\n#{$2}"
  end
  
  # Agregar a la lista de archivos a compilar
  build_refs = file_refs.map { |f| "\t\t\t\t#{f[:build_uuid]} /* #{f[:name]} in Sources */," }.join("\n")
  content.sub!(/(\/\* Sources \*\/ = \{[^;]+files = \([^)]+)(\n\t\t\t\);)/) do
    "#{$1}\n#{build_refs}#{$2}"
  end
  
  # Escribir el archivo modificado
  File.write(PBXPROJ, content)
  
  puts "✅ project.pbxproj modificado exitosamente"
  return true
end

# Main execution
begin
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts "  Agregar archivos Swift al proyecto Xcode"
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  
  # Verificar que el proyecto existe
  unless File.exist?(PBXPROJ)
    puts "❌ ERROR: No se encontró #{PBXPROJ}"
    exit 1
  end
  
  # Verificar que los archivos existen en disco
  puts "📁 Verificando archivos en disco..."
  missing = []
  FILES_TO_ADD.each do |file|
    full_path = "#{PROJECT_DIR}/LatentResonator/#{file[:path]}"
    if File.exist?(full_path)
      puts "   ✅ #{file[:name]}"
    else
      puts "   ❌ #{file[:name]} (NO EXISTE)"
      missing << file[:name]
    end
  end
  
  unless missing.empty?
    puts "\n❌ ERROR: Faltan archivos en disco: #{missing.join(', ')}"
    exit 1
  end
  
  # Crear backup
  backup_project
  
  # Intentar modificar el proyecto
  success = add_files_to_project
  
  if success
    puts "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "  ✅ COMPLETADO"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "\n📝 Próximos pasos:"
    puts "   1. Abre Xcode: open #{PROJECT_DIR}/LatentResonator.xcodeproj"
    puts "   2. Clean Build Folder (Shift+Cmd+K)"
    puts "   3. Build (Cmd+B)"
    puts "\n💾 Backup guardado en: #{File.basename(BACKUP_FILE)}"
    puts "   (Puedes eliminarlo si todo funciona correctamente)\n"
  else
    puts "\n⚠️  Algunos archivos ya estaban en el proyecto."
    puts "   Si hay errores de compilación, verifica manualmente en Xcode."
  end
  
rescue => e
  puts "\n❌ ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  
  if File.exist?(BACKUP_FILE)
    restore_backup
    puts "\n✅ Backup restaurado"
  end
  
  puts "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts "  INSTRUCCIONES MANUALES"
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts "\n⚠️  El script falló. Agrega los archivos manualmente:"
  puts "\n1. open #{PROJECT_DIR}/LatentResonator.xcodeproj"
  puts "2. Project Navigator → clic derecho en 'Graph' → Add Files..."
  puts "3. Selecciona: ImplicitGraphBuilder.swift"
  puts "4. Project Navigator → clic derecho en 'Nodes' → Add Files..."
  puts "5. Selecciona: SequencerNodes.swift, ReverbNode.swift"
  puts "6. Clean (Shift+Cmd+K) + Build (Cmd+B)\n"
  
  exit 1
end
