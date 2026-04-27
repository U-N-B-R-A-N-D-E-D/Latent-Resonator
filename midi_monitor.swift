#!/usr/bin/swift
import CoreMIDI
import Foundation

print("🔍 MIDI Monitor - Detectando todos los eventos MIDI")
print("=====================================================")

var midiClient: MIDIClientRef = 0
var inputPort: MIDIPortRef = 0

// Callback para recibir eventos MIDI (MIDI 2.0 Protocol)
let receiveBlock: MIDIReceiveBlock = { eventList, srcConnRefCon in
    var packet = eventList.pointee.packet
    for _ in 0..<eventList.pointee.numPackets {
        let wordCount = packet.wordCount
        if wordCount >= 1 {
            let word = packet.words.0
            let messageType = (word >> 28) & 0xF
            let status = UInt8((word >> 16) & 0xFF)
            let data1 = UInt8((word >> 8) & 0xFF)
            let data2 = UInt8(word & 0xFF)

            let source: String
            if let refCon = srcConnRefCon {
                source = String(cString: refCon.assumingMemoryBound(to: CChar.self))
            } else {
                source = "Unknown"
            }

            if messageType == 0x2 {  // MIDI 1.0 Channel Voice
                let statusNibble = status & 0xF0
                switch statusNibble {
                case 0xB0:
                    print("📡 [\(source)] CC #\(data1) = \(data2)")
                case 0x90:
                    print("🎹 [\(source)] Note On: nota=\(data1) velocity=\(data2)")
                case 0x80:
                    print("🎹 [\(source)] Note Off: nota=\(data1) velocity=\(data2)")
                case 0xE0:
                    let combined = (UInt16(data2) << 7) | UInt16(data1)
                    print("🎚️ [\(source)] Pitch Bend: \(combined)")
                default:
                    print("📦 [\(source)] Status: 0x\(String(format: "%02X", status)) Data1: \(data1) Data2: \(data2)")
                }
            } else {
                print("🔧 [\(source)] Message Type: \(messageType) Status: 0x\(String(format: "%02X", status))")
            }
        }
        packet = MIDIEventPacketNext(&packet).pointee
    }
}

// Crear cliente MIDI
let clientStatus = MIDIClientCreateWithBlock("MIDI Monitor" as CFString, &midiClient) { _ in }
guard clientStatus == noErr else {
    print("❌ Error creando cliente MIDI: \(clientStatus)")
    exit(1)
}

// Crear puerto de entrada con MIDI 2.0 Protocol
let portStatus = MIDIInputPortCreateWithProtocol(
    midiClient,
    "Monitor Input" as CFString,
    ._1_0,
    &inputPort,
    receiveBlock
)
guard portStatus == noErr else {
    print("❌ Error creando puerto de entrada: \(portStatus)")
    exit(1)
}

// Conectar a todas las fuentes
let sourceCount = MIDIGetNumberOfSources()
print("📍 Fuentes MIDI encontradas: \(sourceCount)")
print("")

var sourceNames: [String] = []

for i in 0..<sourceCount {
    let source = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name)
    let sourceName = name?.takeRetainedValue() as String? ?? "Desconocido"
    sourceNames.append(sourceName)

    print("  [\(i)] \(sourceName)")

    // Conectar a esta fuente
    let refCon = UnsafeMutablePointer<CChar>.allocate(capacity: sourceName.utf8.count + 1)
    strcpy(refCon, sourceName)
    let connectStatus = MIDIPortConnectSource(inputPort, source, refCon)
    if connectStatus == noErr {
        print("      ✓ Conectado")
    } else {
        print("      ✗ Error conectando: \(connectStatus)")
    }
}

print("")
print("🎛️ Mueve cualquier knob, fader o pad del AKAI MPC Studio...")
print("   (Presiona Ctrl+C para salir)")
print("")

// Mantener el script corriendo
RunLoop.main.run()
