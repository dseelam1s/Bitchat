import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var gattService: BleGattService?
    private var multipeerService: MultipeerService?
    var eventSink: FlutterEventSink?
    var multipeerEventSink: FlutterEventSink?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        gattService = BleGattService()
        multipeerService = MultipeerService()

        // Wire up callbacks so native events reach Flutter
        gattService?.onMessageReceived = { [weak self] data, address in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type": "message",
                    "data": data,
                    "address": address
                ])
            }
        }
        gattService?.onDeviceConnected = { [weak self] address in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type": "connected",
                    "address": address
                ])
            }
        }
        gattService?.onDeviceDisconnected = { [weak self] address in
            DispatchQueue.main.async {
                self?.eventSink?([
                    "type": "disconnected",
                    "address": address
                ])
            }
        }

        // MethodChannel — same name as Android
        let methodChannel = FlutterMethodChannel(
            name: "com.bitchat/ble_gatt",
            binaryMessenger: controller.binaryMessenger
        )
        methodChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "start":
                let success = self?.gattService?.start() ?? false
                result(success)
            case "stop":
                self?.gattService?.stop()
                result(true)
            case "sendToAll":
                if let args = call.arguments as? [String: Any],
                   let dataList = args["data"] as? [Int] {
                    let data = Data(dataList.map { UInt8($0 & 0xFF) })
                    self?.gattService?.sendToAll(data)
                    result(true)
                } else {
                    result(FlutterError(
                        code: "INVALID_DATA",
                        message: "No data provided",
                        details: nil
                    ))
                }
            case "getConnectedDevices":
                let addresses = self?.gattService?.getConnectedAddresses() ?? []
                result(addresses)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // EventChannel — same name as Android
        let eventChannel = FlutterEventChannel(
            name: "com.bitchat/ble_gatt_events",
            binaryMessenger: controller.binaryMessenger
        )
        eventChannel.setStreamHandler(BleEventStreamHandler(appDelegate: self))

        // ── MultipeerConnectivity ──────────────────────────────────────────────

        // Wire multipeer callbacks → event sink
        multipeerService?.onDataReceived = { [weak self] data, fromPubkey in
            let dataList = [UInt8](data).map { Int($0) }
            self?.multipeerEventSink?(["type": "received", "data": dataList, "fromPeer": fromPubkey])
        }
        multipeerService?.onPeerConnected = { [weak self] pubkey in
            self?.multipeerEventSink?(["type": "connected", "peerId": pubkey])
        }
        multipeerService?.onPeerDisconnected = { [weak self] pubkey in
            self?.multipeerEventSink?(["type": "disconnected", "peerId": pubkey])
        }

        // MultipeerConnectivity method channel
        let multipeerMethodChannel = FlutterMethodChannel(
            name: "com.bitchat/multipeer",
            binaryMessenger: controller.binaryMessenger
        )
        multipeerMethodChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "start":
                if let args = call.arguments as? [String: Any],
                   let pubkey = args["pubkey"] as? String {
                    let ok = self?.multipeerService?.start(pubkey: pubkey) ?? false
                    result(ok)
                } else {
                    result(false)
                }
            case "stop":
                self?.multipeerService?.stop()
                result(true)
            case "send":
                if let args = call.arguments as? [String: Any],
                   let dataList = args["data"] as? [Int] {
                    let data = Data(dataList.map { UInt8($0 & 0xFF) })
                    let ok = self?.multipeerService?.send(data: data) ?? false
                    result(ok)
                } else {
                    result(false)
                }
            case "getConnectedPeers":
                let peers = self?.multipeerService?.getConnectedPubkeys() ?? []
                result(peers)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // MultipeerConnectivity event channel
        let multipeerEventChannel = FlutterEventChannel(
            name: "com.bitchat/multipeer_events",
            binaryMessenger: controller.binaryMessenger
        )
        multipeerEventChannel.setStreamHandler(MultipeerEventStreamHandler(appDelegate: self))

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

/// Stream handler for the MultipeerConnectivity event channel.
class MultipeerEventStreamHandler: NSObject, FlutterStreamHandler {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        appDelegate?.multipeerEventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        appDelegate?.multipeerEventSink = nil
        return nil
    }
}

/// Stream handler for the BLE GATT event channel.
class BleEventStreamHandler: NSObject, FlutterStreamHandler {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        appDelegate?.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        appDelegate?.eventSink = nil
        return nil
    }
}
