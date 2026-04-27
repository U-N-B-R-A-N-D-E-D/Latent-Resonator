import CoreMIDI
import Foundation

// Buscar MPC Public
var client: MIDIClientRef = 0
let clientStatus = MIDIClientCreate("MPCController" as CFString, nil, nil, &client)
guard clientStatus == noErr else {
    print("❌ Error creando cliente: \(clientStatus)")
    exit(1)
}

let sourceCount = MIDIGetNumberOfSources()
var mpcPublicSource: MIDIEndpointRef = 0

for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    if deviceName.contains("MPC Public") {
        mpcPublicSource = src
        print("✅ Encontrado: MPC Public (index \(i))")
    }
}

guard mpcPublicSource != 0 else {
    print("❌ No se encontró MPC Public")
    exit(1)
}

// Crear puerto de salida
var outputPort: MIDIPortRef = 0
let portStatus = MIDIOutputPortCreate(client, "MPCOut" as CFString, &outputPort)
guard portStatus == noErr else {
    print("❌ Error creando puerto de salida: \(portStatus)")
    exit(1)
}

// Sysex para cambiar a modo Controller (Msg ID 62, modo 02)
let sysex: [UInt8] = [0xF0, 0x47, 0x7F, 0x7F, 0x62, 0x00, 0x01, 0x02, 0xF7]

// Crear paquete MIDI usando UnsafeMutablePointer
var packetListData = Data()
packetListData.append(contentsOf: sysex)

var packetList = MIDIPacketList()
packetList.numPackets = 1
packetList.packet.timeStamp = 0
packetList.packet.length = UInt16(sysex.count)

// Copiar bytes al paquete
withUnsafeMutableBytes(of: &packetList.packet.data) { ptr in
    for (i, byte) in sysex.enumerated() {
        ptr[i] = byte
    }
}

// Enviar
let sendStatus = MIDISend(outputPort, mpcPublicSource, &packetList)
if sendStatus == noErr {
    print("✅ Sysex enviado: modo Controller activado")
    print("   Bytes: \(sysex.map { String(format: "%02X", $0) }.joined(separator: " "))")
} else {
    print("❌ Error enviando sysex: \(sendStatus)")
}

// Esperar y verificar
print("\n⏱️ Esperando 3 segundos...")
Thread.sleep(forTimeInterval: 3)

print("\n🎛️ MUEVE UN KNOB DEL MPC STUDIO AHORA")
print("   Si el modo Controller está activo, los knobs enviarán CC messages")
