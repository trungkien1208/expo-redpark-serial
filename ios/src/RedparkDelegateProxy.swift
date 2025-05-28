import Foundation
import RedSerial
import os
class RedparkDelegateProxy: NSObject, RedSerialDeviceManagerDelegate, RedSerialPortDelegate {
  weak var module: ExpoRedparkSerialModule?
  static let log = Logger(subsystem: "expo.modules.redparkserial.example", category: "RedparkDelegateProxy")
  init(module: ExpoRedparkSerialModule) {
    self.module = module
    RedparkDelegateProxy.log.error("RedparkDelegateProxy: Initialized.")
  }

  func deviceDetected(_ port: RedSerialPort) {
    print("RedparkDelegateProxy: Device detected. \(port)")
    RedparkDelegateProxy.log.error("RedparkDelegateProxy: Device detected. \(port)")
    module?.handleDeviceDetected(port: port)
  }

  func deviceDisconnected(_ port: RedSerialPort) {
    RedparkDelegateProxy.log.error("RedparkDelegateProxy: Device disconnected. \(port)")
    module?.handleDeviceDisconnected(port: port)
  }
}