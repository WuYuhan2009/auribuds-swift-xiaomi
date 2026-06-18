import CoreBluetooth
import Foundation
import IOBluetooth

final class XiaomiDiagnostics {
    static let shared = XiaomiDiagnostics()

    private let lock = NSLock()
    private var deviceName = ""
    private var address = ""
    private var services: [String] = []
    private var characteristics: [String] = []
    private var descriptors: [String] = []
    private var rfcommChannels: [String] = []
    private var bleFrames: [String] = []
    private var sppFrames: [String] = []
    private var errors: [String] = []

    private init() {}

    func setDevice(name: String, address: String = "") {
        lock.lock(); defer { lock.unlock() }
        deviceName = name
        if !address.isEmpty { self.address = address }
    }

    func recordBLEServices(peripheralName: String, services: [CBService]) {
        lock.lock(); defer { lock.unlock() }
        deviceName = peripheralName
        for service in services { Self.appendUnique("service: \(service.uuid.uuidString)", to: &self.services) }
    }

    func recordBLECharacteristics(service: CBService, characteristics: [CBCharacteristic]) {
        lock.lock(); defer { lock.unlock() }
        for characteristic in characteristics {
            Self.appendUnique("service: \(service.uuid.uuidString) characteristic: \(characteristic.uuid.uuidString) properties: \(characteristic.properties.auribudsDescription)", to: &self.characteristics)
        }
    }

    func recordBLEDescriptors(characteristic: CBCharacteristic, descriptors: [CBDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        for descriptor in descriptors {
            Self.appendUnique("characteristic: \(characteristic.uuid.uuidString) descriptor: \(descriptor.uuid.uuidString)", to: &self.descriptors)
        }
    }

    func recordRFCOMM(device: IOBluetoothDevice, channels: [BluetoothRFCOMMChannelID]) {
        lock.lock(); defer { lock.unlock() }
        deviceName = device.name ?? deviceName
        address = device.addressString ?? address
        for channel in channels { Self.appendUnique("channel: \(channel)", to: &self.rfcommChannels) }
    }

    func recordBLEFrame(_ data: Data) { appendFrame(data.hexString, toBLE: true) }
    func recordSPPFrame(_ data: Data) { appendFrame(data.hexString, toBLE: false) }

    func recordError(_ error: String) {
        lock.lock(); defer { lock.unlock() }
        Self.appendUnique(error, to: &self.errors)
    }

    func export() throws -> URL {
        lock.lock()
        let payload: [String: Any] = [
            "deviceName": deviceName,
            "address": address,
            "services": services,
            "characteristics": characteristics,
            "descriptors": descriptors,
            "rfcommChannels": rfcommChannels,
            "bleFrames": bleFrames,
            "sppFrames": sppFrames,
            "errors": errors
        ]
        lock.unlock()

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AuriBuds-Xiaomi-Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func appendFrame(_ value: String, toBLE: Bool) {
        lock.lock(); defer { lock.unlock() }
        if toBLE { bleFrames.append(value); if bleFrames.count > 200 { bleFrames.removeFirst(bleFrames.count - 200) } }
        else { sppFrames.append(value); if sppFrames.count > 200 { sppFrames.removeFirst(sppFrames.count - 200) } }
    }

    private static func appendUnique(_ value: String, to array: inout [String]) {
        guard !array.contains(value) else { return }
        array.append(value)
    }
}

extension CBCharacteristicProperties {
    var auribudsDescription: String {
        var values: [String] = []
        if contains(.read) { values.append("read") }
        if contains(.write) { values.append("write") }
        if contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if contains(.notify) { values.append("notify") }
        if contains(.indicate) { values.append("indicate") }
        if contains(.broadcast) { values.append("broadcast") }
        return values.joined(separator: ",")
    }
}
