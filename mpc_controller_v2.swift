import CoreMIDI
import Foundation

var client: MIDIClientRef = 0
MIDIClientCreate("MPCController" as CFString, nil, nil, &client)

let sourceCount = MIDIGetNumberOfSources()
var mpcPublicSource: MIDIEndpointRef = 0

for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    print("   [\(i)] \(deviceName)")
    if deviceName.contains("MPC Public") {
        mpcPublicSource = src
    }
}

guard mpcPublicSource != 0 else {
    print("❌ MPC Public no encontrado")
    exit(1)
}

var outputPort: MIDIPortRef = 0
MIDIOutputPortCreate(client, "MPCOut" as CFString, &outputPort)

// Intentar diferentes combinaciones de sysex
let sysexVariants: [[UInt8]] = [
    // Variant 1: ProductID 0x3d (MPC Studio Black)
    [0xF0, 0x47, 0x7F, 0x3D, 0x62, 0x00, 0x01, 0x02, 0xF7],
    // Variant 2: Msg ID 61 (private mode) luego 02 (public)
    [0xF0, 0x47, 0x7F, 0x7F, 0x62, 0x00, 0x01, 0x61, 0xF7],
    // Variant 3: Ping primero (52)
    [0xF0, 0x47, 0x7F, 0x7F, 0x52, 0x00, 0x00, 0xF7],
]

print("\n📤 Enviando sysex variants...")
for (i, sysex) in sysexVariants.enumerated() {
    var packetList = MIDIPacketList()
    packetList.numPackets = 1
    packetList.packet.timeStamp = 0
    packetList.packet.length = UInt16(sysex.count)
    
    withUnsafeMutableBytes(of: &packetList.packet.data) { ptr in
        for (j, byte) in sysex.enumerated() {
            ptr[j] = byte
        }
    }
    
    let status = MIDISend(outputPort, mpcPublicSource, &packetList)
    print("   Variant \(i+1): \(status == noErr ? "✅" : "❌") (bytes: \(sysex.map { String(format: "%02X", $0) }.joined()))")
    Thread.sleep(forTimeInterval: 0.5)
}

print("\n⏱️ Esperando 3 segundos...")
Thread.sleep(forTimeInterval: 3)

print("\n🎛️ PRUEBA LOS KNOBS AHORA")
print("   Si no responden, el protocolo del MPC Studio original es diferente")
