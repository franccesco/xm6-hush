import Foundation
import IOBluetooth

// Sets the system volume to `targetVolume` whenever the WH-1000XM6 switches into
// Ambient Sound (transparency) mode.
//
// Protocol (Sony MDR v2 over RFCOMM) and framing follow Gadgetbridge and
// github.com/Anneo22/xm6-control (MIT).
//
// Usage: xm6-volume [--volume N] [--verbose]

var targetVolume = 20
var verbose = false
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--volume":
        guard let value = args.first.flatMap({ Int($0) }), (0...100).contains(value) else {
            fputs("--volume needs a number from 0 to 100\n", stderr)
            exit(64)
        }
        targetVolume = value
        args.removeFirst()
    case "--verbose": verbose = true
    default:
        fputs("usage: xm6-volume [--volume N] [--verbose]\n", stderr)
        exit(64)
    }
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

func debug(_ message: String) {
    if verbose { log(message) }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Framing

enum Frame {
    static let header: UInt8 = 0x3e
    static let trailer: UInt8 = 0x3c
    static let escapeMarker: UInt8 = 0x3d
    static let escapeMask: UInt8 = 0b1110_1111

    static let ack: UInt8 = 0x01
    static let command1: UInt8 = 0x0c

    struct Message {
        let type: UInt8
        let seq: UInt8
        let payload: [UInt8]
    }

    static func encode(type: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type, seq]
        body += [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
        body += payload
        return [header] + escape(body) + escape([checksum(body)]) + [trailer]
    }

    static func decode(_ raw: [UInt8]) -> Message? {
        let bytes = unescape(raw)
        guard bytes.count >= 9, bytes.first == header, bytes.last == trailer else { return nil }
        let inner = Array(bytes[1..<(bytes.count - 2)])
        guard bytes[bytes.count - 2] == checksum(inner) else { return nil }
        let length = Int(UInt32(bytes[3]) << 24 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 8 | UInt32(bytes[6]))
        guard length == bytes.count - 9 else { return nil }
        return Message(type: bytes[1], seq: bytes[2], payload: Array(bytes[7..<(7 + length)]))
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }

    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { b -> [UInt8] in
            b == header || b == trailer || b == escapeMarker ? [escapeMarker, b & escapeMask] : [b]
        }
    }

    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == escapeMarker, i + 1 < bytes.count {
                i += 1
                out.append(bytes[i] | ~escapeMask)
            } else {
                out.append(bytes[i])
            }
            i += 1
        }
        return out
    }
}

/// Reassembles frames from an RFCOMM byte stream that may arrive fragmented.
struct FrameParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [Frame.Message] {
        buffer += data
        var messages: [Frame.Message] = []
        while let start = buffer.firstIndex(of: Frame.header) {
            buffer.removeFirst(start)
            guard let end = buffer.dropFirst().firstIndex(of: Frame.trailer) else { break }
            if let message = Frame.decode(Array(buffer[0...end])) { messages.append(message) }
            buffer.removeFirst(end + 1)
        }
        if buffer.first != Frame.header && !buffer.contains(Frame.header) { buffer.removeAll() }
        return messages
    }
}

// MARK: - Ambient sound

enum Opcode {
    static let initRequest: UInt8 = 0x00
    static let initReply: UInt8 = 0x01
    static let ambientGet: UInt8 = 0x66
    static let ambientRet: UInt8 = 0x67
    static let ambientNotify: UInt8 = 0x69
}

enum Mode: String {
    case off = "Off"
    case noiseCancelling = "Noise Cancelling"
    case ambient = "Ambient Sound"
}

/// Payload layouts:
/// - XM6 (subtype 0x19, 9 bytes): [opcode, 0x19, 0x01, enable, ambientFlag, av, level, naFlag, naSens]
/// - Older v2 dialects (subtypes 0x15, 0x17, 0x22): [opcode, subtype, ?, onOff, ambientFlag, (windByte), focusOnVoice, level]
func decodeAmbient(_ payload: [UInt8]) -> (mode: Mode, level: Int)? {
    guard payload.count >= 6, payload.count <= 9,
          payload[0] == Opcode.ambientRet || payload[0] == Opcode.ambientNotify else { return nil }
    let subtype = payload[1]
    if subtype == 0x19 {
        guard payload.count == 9 else { return nil }
        switch payload[3] {
        case 0x00: return (.off, Int(payload[6]))
        case 0x01: return (payload[4] == 0x01 ? .ambient : .noiseCancelling, Int(payload[6]))
        default: return nil
        }
    }
    guard [0x15, 0x17, 0x22].contains(subtype), payload.count <= 8 else { return nil }
    let hasWindByte = subtype == 0x17 && payload.count > 7
    let level = Int(payload[payload.count - 1])
    switch payload[3] {
    case 0x00:
        return (.off, level)
    case 0x01:
        if hasWindByte, payload[5] == 0x03 || payload[5] == 0x05 { return (.noiseCancelling, level) }
        if subtype == 0x22 { return (.ambient, level) }
        return (payload[4] == 0x01 ? .ambient : .noiseCancelling, level)
    default:
        return nil
    }
}

// MARK: - Volume

func osascript(_ script: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        log("osascript failed: \(error)")
        return nil
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func currentSystemVolume() -> Int? {
    osascript("output volume of (get volume settings)").flatMap { Int($0) }
}

func setSystemVolume(_ percent: Int) {
    _ = osascript("set volume output volume \(percent)")
    log("volume -> \(percent)%")
}

// MARK: - Session

final class Session: NSObject, IOBluetoothRFCOMMChannelDelegate {
    static let serviceUUIDv2 = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
    static let serviceUUIDv1 = "96CC203E-5068-46AD-B32D-E316F5E069BA"

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var seq: UInt8 = 0
    private var lastMode: Mode?
    private var gotInitReply = false
    /// Volume before ambient mode lowered it; nil while not in ambient mode.
    private var savedVolume: Int?

    /// Called on the main run loop when the session ends, so the caller can reconnect.
    var onClosed: (() -> Void)?

    func start() -> Bool {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("WH-1000XM6") }) else {
            log("No paired WH-1000XM6 found")
            return false
        }
        guard device.isConnected() else {
            debug("headset not connected")
            return false
        }
        self.device = device
        guard let record = serviceRecord(device, Self.serviceUUIDv2) ?? serviceRecord(device, Self.serviceUUIDv1) else {
            log("Sony control service not found in the headset's SDP records")
            return false
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            log("Could not read RFCOMM channel from SDP record")
            return false
        }
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess else {
            log("openRFCOMMChannelAsync failed (\(status)); another app may hold the control channel")
            return false
        }
        channel = opened
        return true
    }

    private func serviceRecord(_ device: IOBluetoothDevice, _ uuidString: String) -> IOBluetoothSDPServiceRecord? {
        guard var uuid = UUID(uuidString: uuidString)?.uuid else { return nil }
        let sdpUUID = withUnsafeBytes(of: &uuid) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: $0.count) }
        return device.getServiceRecord(for: sdpUUID)
    }

    private func send(type: UInt8, seq: UInt8, payload: [UInt8]) {
        guard let channel else { return }
        var bytes = Frame.encode(type: type, seq: seq, payload: payload)
        debug("TX \(hex(bytes))")
        let result = bytes.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        if result != kIOReturnSuccess { log("write failed (\(result))") }
    }

    private func handle(_ message: Frame.Message) {
        if message.type == Frame.ack {
            if message.seq != seq { seq = message.seq }
            return
        }
        guard !message.payload.isEmpty else { return }
        // Acknowledge every command from the headset with the flipped sequence bit.
        send(type: Frame.ack, seq: message.seq ^ 0x01, payload: [])
        debug("RX \(hex(message.payload))")

        if message.payload[0] == Opcode.initReply, !gotInitReply {
            gotInitReply = true
            // The headset answers whichever ambient-sound dialect it speaks and ignores the other.
            // These requests need the init command's ACK first, so they go out after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                send(type: Frame.command1, seq: seq, payload: [Opcode.ambientGet, 0x15])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    send(type: Frame.command1, seq: seq, payload: [Opcode.ambientGet, 0x17])
                }
            }
            return
        }

        guard let (mode, level) = decodeAmbient(message.payload) else { return }
        let previous = lastMode
        lastMode = mode
        log("mode: \(mode.rawValue)" + (mode == .ambient ? " (level \(level))" : ""))
        // Only act on transitions, so the initial state report on startup doesn't change the volume
        // and the volume can still be adjusted manually while a mode is active.
        guard let previous else { return }
        if mode == .ambient, previous != .ambient {
            savedVolume = currentSystemVolume()
            setSystemVolume(targetVolume)
        } else if mode != .ambient, previous == .ambient, let saved = savedVolume {
            savedVolume = nil
            setSystemVolume(saved)
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard rfcommChannel === channel else { return }
        guard error == kIOReturnSuccess else {
            log("RFCOMM open failed (\(error))")
            channel = nil
            onClosed?()
            return
        }
        log("connected to control channel")
        // The headset can drop the first write if it arrives right after the channel opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            send(type: Frame.command1, seq: seq, payload: [Opcode.initRequest, 0x00])
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard rfcommChannel === channel, let dataPointer else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        for message in parser.feed(bytes) { handle(message) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        log("control channel closed")
        channel = nil
        onClosed?()
    }
}

// MARK: - Run loop with reconnect

var session: Session?

func connect() {
    let next = Session()
    next.onClosed = {
        session = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: connect)
    }
    if next.start() {
        session = next
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: connect)
    }
}

log("xm6-volume: will set volume to \(targetVolume)% while Ambient Sound is on, then restore it")
DispatchQueue.main.async(execute: connect)
RunLoop.main.run()
