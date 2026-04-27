import CoreMIDI
import Foundation

var client: MIDIClientRef = 0
let name = "ListDevices" as CFString
let status = MIDIClientCreate(name, nil, nil, &client)
guard status == noErr else {
    print("❌ Error creando cliente MIDI: \(status)")
    exit(1)
}

let sourceCount = MIDIGetNumberOfSources()
print("🎹 Fuentes MIDI disponibles: \(sourceCount)")
print("")

for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var nameRef: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &nameRef)
    let deviceName = nameRef?.takeRetainedValue() as String? ?? "Unknown"
    print("  [\(i)] \(deviceName)")
}
