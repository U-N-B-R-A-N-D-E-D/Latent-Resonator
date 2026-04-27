import CoreMIDI

print("=== TEST ESTADO MIDI ===")
print("")

// 1. Fuentes (Inputs)
let sourceCount = MIDIGetNumberOfSources()
print("🎹 FUENTES MIDI (Inputs): \(sourceCount)")
var iacFound = false
for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    let status = deviceName.contains("IAC") ? "✅" : "  "
    if deviceName.contains("IAC") { iacFound = true }
    print("  \(status) [\(i)] \(deviceName)")
}

print("")

// 2. Destinos (Outputs)
let destCount = MIDIGetNumberOfDestinations()
print("🎹 DESTINOS MIDI (Outputs): \(destCount)")
for i in 0..<destCount {
    let dest = MIDIGetDestination(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    let status = deviceName.contains("IAC") ? "✅" : "  "
    if deviceName.contains("IAC") { iacFound = true }
    print("  \(status) [\(i)] \(deviceName)")
}

print("")
if iacFound {
    print("✅ IAC DRIVER ESTÁ ACTIVO")
    print("   Ahora configura MPC Beats para enviar MIDI a IAC")
} else {
    print("❌ IAC DRIVER NO ESTÁ ACTIVO")
    print("   Ve a Audio MIDI Setup → MIDI Studio → IAC Driver")
    print("   Marca 'El dispositivo esta en linea'")
}
