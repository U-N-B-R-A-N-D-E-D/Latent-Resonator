#!/usr/bin/env ruby
# Script para agregar archivos de recursos (JSON) al proyecto Xcode
# Modifica el project.pbxproj de forma segura

require 'securerandom'
require 'fileutils'

PROJECT_DIR = "/Users/leolambertini/RLTNAS/LatentResonator"
PBXPROJ = "#{PROJECT_DIR}/LatentResonator.xcodeproj/project.pbxproj"
BACKUP_FILE = "#{PBXPROJ}.backup_#{Time.now.to_i}"

# Archivo a agregar
RESOURCE_FILE = {
  path: "Resources/KickstartTemplate.json",
  name: "KickstartTemplate.json",
  group: "Resources"
}

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

def add_resource_to_project
  content = File.read(PBXPROJ)
  
  # Verificar que no esté ya agregado
  if content.include?(RESOURCE_FILE[:name])
    puts "⚠️  #{RESOURCE_FILE[:name]} ya está en el proyecto, omitiendo..."
    return false
  end
  
  puts "\n🔧 Modificando project.pbxproj..."
  
  # Generar UUIDs únicos
  file_uuid = generate_uuid
  
  # 1. Agregar PBXFileReference para el archivo JSON
  # Los archivos JSON de recursos usan lastKnownFileType = text.json
  file_ref = "\t\t#{file_uuid} /* #{RESOURCE_FILE[:name]} */ = {isa = PBXFileReference; lastKnownFileType = text.json; path = \"#{RESOURCE_FILE[:name]}\"; sourceTree = \"<group>\"; };"
  
  # Insertar después de la última PBXFileReference
  content.sub!(/(\t\t[A-F0-9]+ \/\* .+\.json \*\/ = \{isa = PBXFileReference;[^\}]+\};)?(\n(?:\n|\t)*\/\* End PBXFileReference)/) do
    "#{$1}#{file_ref}\n#{$2}"
  end
  
  # Si no había archivos JSON, insertar después de cualquier PBXFileReference
  unless content.include?(file_ref.strip)
    content.sub!(/(\t\t[A-F0-9]+ \/\* .+\.(swift|h|m|metal) \*\/ = \{isa = PBXFileReference;[^\}]+\};)(\n(?:\n|\t)*\/\* End PBXFileReference)/) do
      "#{$1}\n#{file_ref}#{$3}"
    end
  end
  
  # 2. Agregar al grupo Resources
  # Buscar el grupo Resources y agregar el children
  resource_children = "\t\t\t\t#{file_uuid} /* #{RESOURCE_FILE[:name]} */,"
  
  # Patrón para encontrar el grupo Resources
  if content.include?("/* Resources */")
    content.sub!(/(\/\* Resources \*\/ = \{[^;]+children = \([^)]*)(\n\t\t\t\);)/) do
      "#{$1}\n#{resource_children}#{$2}"
    end
    puts "   ✅ Agregado al grupo Resources"
  else
    # Si no existe grupo Resources, buscar el grupo principal y agregarlo ahí
    content.sub!(/(\/\* LatentResonator \*\/ = \{[^;]+children = \([^)]*)(\n\t\t\t\);)/) do
      "#{$1}\n#{resource_children}#{$2}"
    end
    puts "   ✅ Agregado al grupo principal"
  end
  
  # Escribir el archivo modificado
  File.write(PBXPROJ, content)
  
  puts "✅ project.pbxproj modificado exitosamente"
  return true
end

# Main execution
begin
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts "  Agregar archivo de recursos al proyecto Xcode"
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  
  # Verificar que el proyecto existe
  unless File.exist?(PBXPROJ)
    puts "❌ ERROR: No se encontró #{PBXPROJ}"
    exit 1
  end
  
  # Verificar que el archivo existe en disco
  puts "📁 Verificando archivo en disco..."
  full_path = "#{PROJECT_DIR}/LatentResonator/#{RESOURCE_FILE[:path]}"
  if File.exist?(full_path)
    puts "   ✅ #{RESOURCE_FILE[:name]}"
  else
    puts "   ❌ #{RESOURCE_FILE[:name]} (NO EXISTE en #{full_path})"
    exit 1
  end
  
  # Crear backup
  backup_project
  
  # Intentar modificar el proyecto
  success = add_resource_to_project
  
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
    puts "\n⚠️  El archivo ya estaba en el proyecto."
    puts "   Si hay errores, verifica manualmente en Xcode."
  end
  
rescue => e
  puts "\n❌ ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  
  if File.exist?(BACKUP_FILE)
    restore_backup
    puts "\n✅ Backup restaurado"
  end
  
  exit 1
end
