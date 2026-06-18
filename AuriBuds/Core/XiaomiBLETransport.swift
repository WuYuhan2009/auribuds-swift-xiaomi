import CoreBluetooth
import Foundation

enum XiaomiBLETransportError: Error, LocalizedError, Equatable {
    case bluetoothUnavailable(String)
    case deviceNotFound(String)
    case connectTimeout(String)
    case serviceNotFound
    case characteristicNotFound
    case writeFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let reason):
            return "Bluetooth LE unavailable: \(reason)"
        case .deviceNotFound:
            return "未发现设备"
        case .connectTimeout(let name):
            return "BLE connect timed out: \(name)"
        case .serviceNotFound:
            return "Xiaomi BLE service not found"
        case .characteristicNotFound:
            return "Xiaomi BLE write/notify characteristic not found"
        case .writeFailed(let reason):
            return "BLE write failed: \(reason)"
        case .notConnected:
            return "BLE peripheral is not connected"
        }
    }
}

final class XiaomiBLEConnection {
    private let peripheral: CBPeripheral
    private let writeCharacteristic: CBCharacteristic
    private let writeType: CBCharacteristicWriteType
    private let responseLock = NSLock()
    private let responseSemaphore = DispatchSemaphore(value: 0)
    private var responseStorage: [Data] = []
    private let onEvent: (String) -> Void

    init(
        peripheral: CBPeripheral,
        writeCharacteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        onEvent: @escaping (String) -> Void
    ) {
        self.peripheral = peripheral
        self.writeCharacteristic = writeCharacteristic
        self.writeType = writeType
        self.onEvent = onEvent
    }

    var responseCount: Int {
        responseLock.lock()
        defer { responseLock.unlock() }
        return responseStorage.count
    }

    var isOpen: Bool {
        peripheral.state == .connected
    }

    func appendResponse(_ data: Data) {
        responseLock.lock()
        responseStorage.append(data)
        responseLock.unlock()
        responseSemaphore.signal()
        XiaomiDiagnostics.shared.recordBLEFrame(data)
        onEvent("ble recv frame \(data.hexString)")
    }

    func responsesSince(_ index: Int) -> [Data] {
        responseLock.lock()
        defer { responseLock.unlock() }

        let startIndex = max(0, index)
        guard startIndex < responseStorage.count else { return [] }
        return Array(responseStorage[startIndex...])
    }

    func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw XiaomiBLETransportError.notConnected }
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: writeType)
        XiaomiDiagnostics.shared.recordBLEFrame(Data(bytes))
        onEvent("ble write queued \(bytes.hexString)")
    }

    func waitForResponses(since baseline: Int, timeout: TimeInterval) -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)

        while isOpen && Date() < deadline {
            if responsesSince(baseline).isEmpty {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                _ = responseSemaphore.wait(timeout: .now() + min(remaining, 0.25))
            } else {
                break
            }
        }

        return responsesSince(baseline)
    }
}

final class XiaomiBLETransport: NSObject, @unchecked Sendable {
    private let priorityUUIDFragments = ["AF00", "AF05", "AF06", "AF07", "AF08"]

    private var central: CBCentralManager!
    private var stateContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<XiaomiBLEConnection, Error>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var targetName = ""
    private var normalizedTargetName = ""
    private var pendingPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var discoveredServiceCount = 0
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var activeConnection: XiaomiBLEConnection?
    private var onEvent: ((String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect(
        deviceName: String,
        timeout: TimeInterval = 30,
        onEvent: @escaping (String) -> Void
    ) async throws -> XiaomiBLEConnection {
        self.onEvent = onEvent
        try await waitUntilPoweredOn(timeout: min(timeout, 4))

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectContinuation = continuation
                self.targetName = deviceName
                self.normalizedTargetName = XiaomiDeviceProfile.normalized(deviceName)
                self.writeCharacteristic = nil
                self.notifyCharacteristic = nil
                self.discoveredServiceCount = 0
                self.activeConnection = nil
                self.emit("ble connect pipeline start \(deviceName)")

                self.tryRetrievedConnectedPeripheralOrScan()

                self.connectTimeoutTask?.cancel()
                self.connectTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await MainActor.run {
                        self?.completeConnect(.failure(XiaomiBLETransportError.connectTimeout(deviceName)))
                    }
                }
            }
        }
    }

    func disconnect() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        if central.isScanning {
            central.stopScan()
        }
        if let pendingPeripheral, pendingPeripheral.state == .connected || pendingPeripheral.state == .connecting {
            central.cancelPeripheralConnection(pendingPeripheral)
        }
        pendingPeripheral = nil
        writeCharacteristic = nil
        activeConnection = nil
    }

    private func waitUntilPoweredOn(timeout: TimeInterval) async throws {
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff:
            throw XiaomiBLETransportError.bluetoothUnavailable("powered off")
        case .unsupported:
            throw XiaomiBLETransportError.bluetoothUnavailable("unsupported")
        case .unauthorized:
            throw XiaomiBLETransportError.bluetoothUnavailable("unauthorized")
        default:
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.main.async { [weak self] in
                    self?.stateContinuation = continuation
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        await MainActor.run {
                            if let continuation = self?.stateContinuation {
                                self?.stateContinuation = nil
                                continuation.resume(throwing: XiaomiBLETransportError.bluetoothUnavailable("state \(self?.central.state.rawValue ?? -1)"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func matches(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name, !normalizedTargetName.isEmpty else { return false }
        let normalizedPeripheralName = XiaomiDeviceProfile.normalized(name)
        return normalizedPeripheralName.contains(normalizedTargetName)
            || normalizedTargetName.contains(normalizedPeripheralName)
            || XiaomiDeviceProfile.isLikelyXiaomiAudioDevice(name)
    }

    private func tryRetrievedConnectedPeripheralOrScan() {
        let knownServices = priorityUUIDFragments.map { CBUUID(string: "0000\($0)-0000-1000-8000-00805F9B34FB") }
        let connected = central.retrieveConnectedPeripherals(withServices: knownServices)
        if let peripheral = connected.first(where: { matches($0) }) {
            emit("ble retrieveConnectedPeripherals matched \(peripheral.name ?? "unknown")")
            connect(peripheral)
            return
        }

        let identifiers = central.retrievePeripherals(withIdentifiers: connected.map(\.identifier))
        if let peripheral = identifiers.first(where: { matches($0) }) {
            emit("ble retrievePeripherals matched \(peripheral.name ?? "unknown")")
            connect(peripheral)
            return
        }

        emit("ble scanForPeripherals fallback")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ peripheral: CBPeripheral) {
        emit("ble peripheral \(peripheral.name ?? "unknown")")
        if central.isScanning {
            central.stopScan()
        }
        pendingPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    private func completeConnect(_ result: Result<XiaomiBLEConnection, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        if central.isScanning {
            central.stopScan()
        }

        switch result {
        case .success(let connection):
            activeConnection = connection
            continuation.resume(returning: connection)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func emit(_ event: String) {
        onEvent?(event)
    }
}

extension XiaomiBLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let continuation = stateContinuation else { return }

        switch central.state {
        case .poweredOn:
            stateContinuation = nil
            continuation.resume()
        case .poweredOff:
            stateContinuation = nil
            continuation.resume(throwing: XiaomiBLETransportError.bluetoothUnavailable("powered off"))
        case .unsupported:
            stateContinuation = nil
            continuation.resume(throwing: XiaomiBLETransportError.bluetoothUnavailable("unsupported"))
        case .unauthorized:
            stateContinuation = nil
            continuation.resume(throwing: XiaomiBLETransportError.bluetoothUnavailable("unauthorized"))
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matches(peripheral) else { return }
        emit("ble discovered \(peripheral.name ?? "unknown") rssi=\(RSSI)")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit("ble connected")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        completeConnect(.failure(error ?? XiaomiBLETransportError.deviceNotFound(targetName)))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        emit("ble disconnected")
    }
}

extension XiaomiBLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            completeConnect(.failure(error))
            return
        }

        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            completeConnect(.failure(XiaomiBLETransportError.serviceNotFound))
            return
        }

        discoveredServiceCount = services.count
        XiaomiDiagnostics.shared.recordBLEServices(peripheralName: peripheral.name ?? targetName, services: services)
        for service in services {
            emit("service: \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            completeConnect(.failure(error))
            return
        }

        guard let characteristics = service.characteristics else {
            completeConnect(.failure(XiaomiBLETransportError.characteristicNotFound))
            return
        }

        XiaomiDiagnostics.shared.recordBLECharacteristics(service: service, characteristics: characteristics)
        for characteristic in characteristics {
            emit("characteristic: \(characteristic.uuid.uuidString) properties: \(characteristic.properties.auribudsDescription)")
            peripheral.discoverDescriptors(for: characteristic)
            classify(characteristic, on: peripheral)
        }

        discoveredServiceCount -= 1
        if discoveredServiceCount <= 0 {
            finishCharacteristicDiscovery(for: peripheral)
        }
    }


    private func classify(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let properties = characteristic.properties
        let score = priorityScore(characteristic.uuid)
        if properties.contains(.notify) || properties.contains(.indicate) {
            if notifyCharacteristic == nil || score < priorityScore(notifyCharacteristic!.uuid) {
                notifyCharacteristic = characteristic
            }
            peripheral.setNotifyValue(true, for: characteristic)
            emit("ble notify characteristic \(characteristic.uuid.uuidString)")
        }

        if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
            if writeCharacteristic == nil || score < priorityScore(writeCharacteristic!.uuid) {
                writeCharacteristic = characteristic
                writeType = properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            }
            emit("ble write characteristic \(characteristic.uuid.uuidString)")
        }
    }

    private func finishCharacteristicDiscovery(for peripheral: CBPeripheral) {
        guard let writeCharacteristic else {
            completeConnect(.failure(XiaomiBLETransportError.characteristicNotFound))
            return
        }
        emit("ble rcsp candidate write=\(writeCharacteristic.uuid.uuidString) notify=\(notifyCharacteristic?.uuid.uuidString ?? "none")")
        let connection = XiaomiBLEConnection(
            peripheral: peripheral,
            writeCharacteristic: writeCharacteristic,
            writeType: writeType,
            onEvent: { [weak self] event in self?.emit(event) }
        )
        completeConnect(.success(connection))
    }

    private func priorityScore(_ uuid: CBUUID) -> Int {
        let value = uuid.uuidString.uppercased()
        return priorityUUIDFragments.firstIndex(where: { value.contains($0) }) ?? priorityUUIDFragments.count
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error { emit("descriptor error \(error.localizedDescription)"); return }
        XiaomiDiagnostics.shared.recordBLEDescriptors(characteristic: characteristic, descriptors: characteristic.descriptors ?? [])
        for descriptor in characteristic.descriptors ?? [] {
            emit("descriptor: \(descriptor.uuid.uuidString) characteristic: \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emit("ble notify error \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }
        activeConnection?.appendResponse(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emit("ble write failed \(error.localizedDescription)")
        } else {
            emit("ble write complete")
        }
    }
}
