import CoreMIDI
import Foundation

print("🎹 TEST MIDI - MPC Studio + MPC Beats")
print("======================================")
print("Mueve un knob/fader del MPC Studio...")
print("(Esperando 15 segundos)\n")

var client: MIDIClientRef = 0
MIDIClientCreate("MPCListener" as CFString, nil, nil, &client)

var inputPort: MIDIPortRef = 0
MIDIInputPortCreateWithProtocol(client, "MPCIn" as CFString, ._1_0, &inputPort) { eventList, refCon in
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
                switch statusNibble {
                case 0xB0:
                    print("📡 CC #\(data1) = \(data2)")
                case 0x90:
                    print("🎹 Note On: \(data1) vel:\(data2)")
                case 0x80:
                    print("🎹 Note Off: \(data1)")
                default:
                    print("📦 Status: 0x\(String(format: "%02X", status))")
                }
            }
        }
        packet = MIDIEventPacketNext(&packet).pointee
    }
}

// Conectar a todos los puertos MPC
let sourceCount = MIDIGetNumberOfSources()
for i in 0..<sourceCount {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
    let deviceName = name?.takeRetainedValue() as String? ?? "Unknown"
    
    if deviceName.contains("MPC") {
        MIDIPortConnectSource(inputPort, src, nil)
        print("✅ Conectado a: \(deviceName)")
    }
}

Thread.sleep(forTimeInterval: 15)
print("\n✅ Test completado")
