import Flutter
import Foundation

// Conversions between SwiftBLEKit's platform-independent types and the
// Pigeon-generated wire messages.

extension BleManagerStateMessage {
  init(_ state: BLEManagerState) {
    switch state {
    case .unknown: self = .unknown
    case .resetting: self = .resetting
    case .unsupported: self = .unsupported
    case .unauthorized: self = .unauthorized
    case .poweredOff: self = .poweredOff
    case .poweredOn: self = .poweredOn
    }
  }
}

extension AdvertisementDataMessage {
  init(_ advertisement: AdvertisementData) {
    self.init(
      localName: advertisement.localName,
      serviceUuids: advertisement.serviceUUIDs.map(\.rawValue),
      manufacturerData: advertisement.manufacturerData.map { FlutterStandardTypedData(bytes: $0) },
      isConnectable: advertisement.isConnectable
    )
  }
}

extension BleErrorMessage {
  init(_ error: BLEError) {
    switch error {
    case .bluetoothUnavailable(let state):
      self.init(code: .bluetoothUnavailable, managerState: BleManagerStateMessage(state))
    case .connectionTimeout:
      self.init(code: .connectionTimeout)
    case .disconnected(let isExpected, let reason):
      self.init(code: .disconnected, message: reason, isExpectedDisconnect: isExpected)
    case .peripheralNotFound:
      self.init(code: .peripheralNotFound)
    case .serviceNotFound(let uuid):
      self.init(code: .serviceNotFound, uuid: uuid.rawValue)
    case .characteristicNotFound(let uuid):
      self.init(code: .characteristicNotFound, uuid: uuid.rawValue)
    case .reconnectionExhausted(let attempts):
      self.init(code: .reconnectionExhausted, attempts: Int64(attempts))
    case .cancelled:
      self.init(code: .cancelled)
    case .underlying(let message):
      self.init(code: .underlying, message: message)
    }
  }
}

/// Maps a thrown error into Pigeon's transport (`code`/`message`), so the
/// Dart side can reconstruct a typed `BleError` from `PlatformException`.
/// `code` matches `BleErrorCodeMessage`'s case names.
extension PigeonError {
  convenience init(_ error: Error) {
    guard let bleError = error as? BLEError else {
      self.init(code: "underlying", message: "\(error)", details: nil)
      return
    }
    let message = BleErrorMessage(bleError)
    self.init(
      code: String(describing: message.code),
      message: message.message ?? message.uuid,
      details: nil
    )
  }

  static var peripheralNotFound: PigeonError {
    PigeonError(BLEError.peripheralNotFound)
  }
}
