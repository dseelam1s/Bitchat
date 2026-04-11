import CoreBluetooth
import Foundation

/// iOS equivalent of the Android BleGattService.
/// Runs a BLE peripheral (GATT server) that advertises a custom service,
/// accepts writes from connected centrals, and sends notifications.
class BleGattService: NSObject, CBPeripheralManagerDelegate {

    // Must match Android UUIDs exactly for cross-platform mesh
    static let serviceUUID       = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let writeCharUUID     = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let notifyCharUUID    = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    private var peripheralManager: CBPeripheralManager?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var isAdvertising = false
    private var pendingStart = false
    private var isStarted = false // tracks user intent — lets us auto-recover on app resume

    // Callbacks to Flutter via EventChannel
    var onMessageReceived: ((_ data: [UInt8], _ address: String) -> Void)?
    var onDeviceConnected: ((_ address: String) -> Void)?
    var onDeviceDisconnected: ((_ address: String) -> Void)?

    func start() -> Bool {
        isStarted = true
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
            pendingStart = true
            // Actual setup happens in peripheralManagerDidUpdateState once BT is ready
            return true
        }

        if peripheralManager?.state == .poweredOn {
            setupService()
            startAdvertising()
            return true
        }

        pendingStart = true
        return true
    }

    func stop() {
        isStarted = false
        pendingStart = false
        if isAdvertising {
            peripheralManager?.stopAdvertising()
            isAdvertising = false
        }
        peripheralManager?.removeAllServices()
        subscribedCentrals.removeAll()
    }

    func sendToAll(_ data: Data) {
        guard let characteristic = notifyCharacteristic else { return }
        guard !subscribedCentrals.isEmpty else { return }

        // updateValue returns false if the transmit queue is full.
        // In that case, peripheralManagerIsReady(toUpdateSubscribers:) will fire.
        let sent = peripheralManager?.updateValue(
            data,
            for: characteristic,
            onSubscribedCentrals: nil // nil = all subscribers
        )

        if sent == false {
            // Queue is full — will retry in peripheralManagerIsReady
            // For simplicity we don't queue here; mesh messages are best-effort
        }
    }

    func getConnectedAddresses() -> [String] {
        return subscribedCentrals.map { $0.identifier.uuidString }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn && (pendingStart || isStarted) {
            // Either initial start or recovery after iOS suspended/killed the app
            pendingStart = false
            subscribedCentrals.removeAll()
            setupService()
            startAdvertising()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error = error {
            print("[BleGattService] Failed to add service: \(error.localizedDescription)")
        }
    }

    func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error = error {
            print("[BleGattService] Advertising failed: \(error.localizedDescription)")
            isAdvertising = false
        } else {
            isAdvertising = true
        }
    }

    // A central subscribed to our notify characteristic
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
            onDeviceConnected?(central.identifier.uuidString)
        }
    }

    // A central unsubscribed
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        onDeviceDisconnected?(central.identifier.uuidString)
    }

    // A central wrote data to our write characteristic
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            if request.characteristic.uuid == BleGattService.writeCharUUID,
               let data = request.value {
                let bytes = [UInt8](data)
                let address = request.central.identifier.uuidString
                onMessageReceived?(bytes, address)
            }
            // Always respond success
            peripheral.respond(to: request, withResult: .success)
        }
    }

    // Transmit queue has space again
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Could retry pending notifications here if we implemented a queue
    }

    // MARK: - Private

    private func setupService() {
        // Write characteristic — centrals write messages to us
        let writeChar = CBMutableCharacteristic(
            type: BleGattService.writeCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil, // nil = dynamic value
            permissions: [.writeable]
        )

        // Notify characteristic — we push messages to centrals
        let notifyChar = CBMutableCharacteristic(
            type: BleGattService.notifyCharUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        notifyCharacteristic = notifyChar

        let service = CBMutableService(
            type: BleGattService.serviceUUID,
            primary: true
        )
        service.characteristics = [writeChar, notifyChar]

        peripheralManager?.removeAllServices()
        peripheralManager?.add(service)
    }

    private func startAdvertising() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }

        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleGattService.serviceUUID],
            CBAdvertisementDataLocalNameKey: "BitChat"
        ])
    }
}
