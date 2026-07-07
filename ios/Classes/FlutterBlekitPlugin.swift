import Flutter
import Foundation
#if os(iOS)
  import UIKit
#endif

/// Bridges the Pigeon-generated `BleHostApi`/`BleFlutterApi` channel to
/// SwiftBLEKit's `LiveCentralManager`/`BLEPeripheralProtocol`.
///
/// This class contains no Core Bluetooth logic of its own — every operation is
/// a direct translation to/from SwiftBLEKit's actual Core Bluetooth adapter
/// (vendored under `ios/SwiftBLEKit` and compiled into this pod).
public class FlutterBlekitPlugin: NSObject, FlutterPlugin, BleHostApi {

  private let central = LiveCentralManager(restoreIdentifier: "flutter_blekit.central")
  private let flutterApi: BleFlutterApi

  private let lock = NSLock()
  private var peripheralsById: [String: BLEPeripheralProtocol] = [:]
  private var cachedState: BleManagerStateMessage = .unknown
  private var scanTask: Task<Void, Never>?

  init(flutterApi: BleFlutterApi) {
    self.flutterApi = flutterApi
    super.init()
    observeStateUpdates()
    observeDisconnections()
    observeRestoration()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let flutterApi = BleFlutterApi(binaryMessenger: messenger)
    let instance = FlutterBlekitPlugin(flutterApi: flutterApi)
    BleHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
  }

  // MARK: - Peripheral registry

  private func remember(_ peripheral: BLEPeripheralProtocol) {
    lock.guarded { peripheralsById[peripheral.identifier.uuidString] = peripheral }
  }

  private func peripheral(for id: String) -> BLEPeripheralProtocol? {
    lock.guarded { peripheralsById[id] }
  }

  // MARK: - Event forwarding

  private func observeStateUpdates() {
    Task { [weak self] in
      guard let self else { return }
      for await state in central.stateUpdates() {
        let message = BleManagerStateMessage(state)
        self.lock.guarded { self.cachedState = message }
        await self.emit { self.flutterApi.onManagerStateChanged(state: message, completion: $0) }
      }
    }
  }

  private func observeDisconnections() {
    Task { [weak self] in
      guard let self else { return }
      for await event in central.disconnections() {
        let message = DisconnectionMessage(
          peripheralId: event.identifier.uuidString,
          error: event.error.map(BleErrorMessage.init)
        )
        await self.emit { self.flutterApi.onDisconnection(event: message, completion: $0) }
      }
    }
  }

  private func observeRestoration() {
    Task { [weak self] in
      guard let self else { return }
      for await restoration in central.restorationEvents() {
        for peripheral in restoration.peripherals { self.remember(peripheral) }
        var names: [String?] = []
        for peripheral in restoration.peripherals { names.append(await peripheral.name) }
        let message = RestorationMessage(
          peripheralIds: restoration.peripherals.map { $0.identifier.uuidString },
          peripheralNames: names,
          scanServiceUuids: restoration.scanServices.map(\.rawValue)
        )
        await self.emit { self.flutterApi.onRestoration(restoration: message, completion: $0) }
      }
    }
  }

  private func observeNotifications(for peripheralId: String, characteristic: BLEUUID, on peripheral: BLEPeripheralProtocol) {
    Task { [weak self] in
      guard let self else { return }
      for await data in peripheral.notifications(for: characteristic) {
        let message = NotificationMessage(
          peripheralId: peripheralId,
          characteristicUuid: characteristic.rawValue,
          value: FlutterStandardTypedData(bytes: data)
        )
        await self.emit { self.flutterApi.onNotificationValue(notification: message, completion: $0) }
      }
    }
  }

  /// Pigeon FlutterApi calls must happen on the main thread; SwiftBLEKit's
  /// callbacks arrive on its own dispatch queue.
  private func emit(_ send: @escaping (@escaping (Result<Void, PigeonError>) -> Void) -> Void) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        send { _ in continuation.resume() }
      }
    }
  }

  // MARK: - BleHostApi

  public func getState() throws -> BleManagerStateMessage {
    lock.guarded { cachedState }
  }

  public func startScan(serviceUuids: [String]?) throws {
    let services = serviceUuids?.map(BLEUUID.init)
    scanTask?.cancel()
    scanTask = Task { [weak self] in
      guard let self else { return }
      for await discovery in central.scan(services: services) {
        self.remember(discovery.peripheral)
        let name = await discovery.peripheral.name
        let message = DiscoveryMessage(
          peripheralId: discovery.peripheral.identifier.uuidString,
          peripheralName: name,
          advertisement: AdvertisementDataMessage(discovery.advertisement),
          rssi: Int64(discovery.rssi)
        )
        await self.emit { self.flutterApi.onDiscovery(discovery: message, completion: $0) }
      }
    }
  }

  public func stopScan() throws {
    scanTask?.cancel()
    scanTask = nil
    Task { await central.stopScan() }
  }

  public func connect(peripheralId: String, timeoutMs: Int64?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    let timeout = timeoutMs.map { TimeInterval($0) / 1000.0 }
    Task {
      do {
        try await central.connect(peripheral, timeout: timeout)
        completion(.success(()))
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func disconnect(peripheralId: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.success(()))
      return
    }
    Task {
      await central.disconnect(peripheral)
      completion(.success(()))
    }
  }

  public func retrievePeripheral(identifier: String, completion: @escaping (Result<PeripheralInfoMessage?, Error>) -> Void) {
    guard let uuid = UUID(uuidString: identifier) else {
      completion(.success(nil))
      return
    }
    Task {
      guard let peripheral = await central.retrievePeripheral(identifier: uuid) else {
        completion(.success(nil))
        return
      }
      self.remember(peripheral)
      let name = await peripheral.name
      completion(.success(PeripheralInfoMessage(peripheralId: peripheral.identifier.uuidString, name: name)))
    }
  }

  public func discoverServices(peripheralId: String, serviceUuids: [String]?, completion: @escaping (Result<[String], Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    Task {
      do {
        let services = try await peripheral.discoverServices(serviceUuids?.map(BLEUUID.init))
        completion(.success(services.map(\.rawValue)))
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func discoverCharacteristics(
    peripheralId: String,
    serviceUuid: String,
    characteristicUuids: [String]?,
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    Task {
      do {
        let characteristics = try await peripheral.discoverCharacteristics(
          characteristicUuids?.map(BLEUUID.init),
          for: BLEUUID(serviceUuid)
        )
        completion(.success(characteristics.map(\.rawValue)))
        // Now that the characteristic is known, start forwarding its
        // notifications; `setNotify(true, ...)` is a separate Dart-driven call.
        for characteristic in characteristics {
          self.observeNotifications(for: peripheralId, characteristic: characteristic, on: peripheral)
        }
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func readValue(peripheralId: String, characteristicUuid: String, completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    Task {
      do {
        let data = try await peripheral.readValue(for: BLEUUID(characteristicUuid))
        completion(.success(FlutterStandardTypedData(bytes: data)))
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func writeValue(
    peripheralId: String,
    characteristicUuid: String,
    value: FlutterStandardTypedData,
    withResponse: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    Task {
      do {
        try await peripheral.writeValue(value.data, for: BLEUUID(characteristicUuid), withResponse: withResponse)
        completion(.success(()))
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func setNotify(peripheralId: String, characteristicUuid: String, enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.failure(PigeonError.peripheralNotFound))
      return
    }
    Task {
      do {
        try await peripheral.setNotify(enabled, for: BLEUUID(characteristicUuid))
        completion(.success(()))
      } catch {
        completion(.failure(PigeonError(error)))
      }
    }
  }

  public func peripheralName(peripheralId: String, completion: @escaping (Result<String?, Error>) -> Void) {
    guard let peripheral = peripheral(for: peripheralId) else {
      completion(.success(nil))
      return
    }
    Task {
      completion(.success(await peripheral.name))
    }
  }
}

private extension NSLock {
  func guarded<T>(_ body: () -> T) -> T {
    lock(); defer { unlock() }
    return body()
  }
}
