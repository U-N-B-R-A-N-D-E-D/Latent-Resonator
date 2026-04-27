import CoreMIDI

print("=== TEST BUS 1 (Posible IAC) ===")
print("")

// Conectar a Bus 1 y escuchar
var client: MIDIClientRef = 0
MIDIClientCreate("Bus1Listener" as CFString, nil, nil, &client)

var inputPort: MIDIPortRef = 0
var messageCount = 0

MIDIInputPortCreateWithProtocol(client, "Bus1In" as CFString, ._1_0, &inputPort) { eventList, refCon in
    var packet = eventList.pointee.packet
    for _ in 0..<eventList.pointee.numPackets {
        if packet.wordCount >= 1 {
            let word = packet.words.0
            let messageType = (word >> 28) & 0xF
            let status = UInt8((word >> 16) & 0xFF)
            let data1 = UInt8((word >> 8) & 0xFF)
            let data2 = UInt8(word & 0xFF)
            
            if messageType == 0x2 {
                let statusNibble = status & 0xF0
                if statusNibble == 0xB0 {
                    print("📡 CC #\(data1) = \(data2)")
                    messageCount += 1
                } else if statusNibble == 0x90 {
                    print("🎹 Note On: \(data1)")
                    messageCount += 1
                }
            }
        }
        packet = MIDIEventPacketNext(&packet).pointee
    }
}

// Buscar y conectar a Bus 1
let sourceCount = MIDIGetNumberOfSources()
var bus1Source: MIDIEndpointRef = 0

for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    if deviceName == "Bus 1" {
        bus1Source = src
        print("✅ Conectado a: \(deviceName) (index \(i))")
    }
}

if bus1Source != 0 {
    MIDIPortConnectSource(inputPort, bus1Source, nil)
    print("⏱️ Escuchando Bus 1 por 10 segundos...")
    print("🎛️ MUEVE UN KNOB DEL MPC STUDIO")
    print("   (Si MPC Beats está enviando a Bus 1, verás mensajes)")
    print("")
    Thread.sleep(forTimeInterval: 10)
    print("")
    if messageCount == 0 {
        print("❌ No llegaron mensajes")
        print("   MPC Beats no está configurado para enviar a Bus 1")
    } else {
        print("✅ Llegaron \(messageCount) mensajes!")
    }
} else {
    print("❌ Bus 1 no encontrado")
}
