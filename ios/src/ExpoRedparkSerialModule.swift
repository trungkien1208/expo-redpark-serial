import ExpoModulesCore
import RedSerial
import Foundation
import os

public class ExpoRedparkSerialModule: Module {
  public static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ExpoRedparkSerial")
  private var redSerialPort: RedSerialPort?
  private var delegateProxy: RedparkDelegateProxy? // Hold a strong reference
  private var rxBuffer: [UInt8] = []
  private var readPending = false
  private var hasFiredInitialStatusEvent = false
  private var sendDataResponsePromise: Promise?
  private var sendDataResponseTimer: DispatchWorkItem?

  // MARK: - Framing constants
  private enum Frame {
    static let STX: UInt8 = 0x02
    static let ETX: UInt8 = 0x03
    static let ACK: UInt8 = 0x06
    static let NAK: UInt8 = 0x15
    static let maxPayload = 4096          // sanity upper‑bound
  }

  /// Convert 2‑byte BCD length (MSB, LSB) into an Int (0…9999)
  private func bcdLength(msb: UInt8, lsb: UInt8) -> Int {
    return Int((msb >> 4) & 0x0F) * 1000 +
           Int( msb       & 0x0F) * 100  +
           Int((lsb >> 4) & 0x0F) * 10   +
           Int( lsb       & 0x0F)
  }

  public required init(appContext: AppContext) {
    super.init(appContext: appContext)
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Module initialized.")

    delegateProxy = RedparkDelegateProxy(module: self)
    // It's crucial that the delegate is set for device detection to work.
    // We can set it here, or ensure manualStartDiscovery sets it.
    // RedSerialDeviceManager.shared().delegate = delegateProxy
    // ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Delegate set in init.")
    
    // Start discovery if a port is not already connected or being sought.
    // This might be better initiated by a manual call from JS after app setup.
    // RedSerialDeviceManager.shared().startDiscovery()
    // ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Initial discovery started from init.")
  }

  public func definition() -> ModuleDefinition {
    Name("ExpoRedparkSerial")

    Events("onCableStatusChanged", "onDataReceived", "onError")

    OnCreate {
      // It's good practice to initialize instance properties like delegateProxy here if they depend on `self`
      // or need to be set up when the module is officially created by Expo.
      self.delegateProxy = RedparkDelegateProxy(module: self)
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Module OnCreate called.") // Use static log

      self.hasFiredInitialStatusEvent = false // Reset on module creation

      NotificationCenter.default.addObserver(self, selector: #selector(self.handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(self.handleAppWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)

      if UIApplication.shared.applicationState == .active {
        // RedSerialDeviceManager.shared().delegate = self.delegateProxy // Delegate will be set in checkAndReportInitialCableStatus
        // RedSerialDeviceManager.shared().startDiscovery() // Discovery will be started in checkAndReportInitialCableStatus
        // ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Discovery started in OnCreate as app is active.")
        self.checkAndReportInitialCableStatus()
      }
    }
    
    AsyncFunction("isCableConnected") { () -> Bool in
      let connected = self.redSerialPort != nil
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: isCableConnected check: \(connected ? "true" : "false", privacy: .public)")
      return connected
    }

    AsyncFunction("sendDataAsync") { (hexDataString: String, promise: Promise) in
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: >>> sendDataAsync CALLED (Promise version).")
      guard let port = self.redSerialPort else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Send failed - Port not connected.")
        promise.reject("PORT_NOT_CONNECTED", "Port not connected or ready for sending.")
        return
      }

      guard let dataToSend = self.dataFromHexString(hexDataString) else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Send failed - Invalid HEX string: \(hexDataString, privacy: .public)")
        promise.reject("INVALID_HEX_STRING", "Invalid HEX string provided for sending.")
        return
      }

      // Check if another sendDataAsync is already awaiting a response
      if self.sendDataResponsePromise != nil {
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: sendDataAsync called while another is already awaiting response.")
          promise.reject("CONCURRENT_OPERATION", "Another sendDataAsync operation is already in progress and awaiting a response.")
          return
      }
      
      self.sendDataResponsePromise = promise
      ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Sending data: \(hexDataString, privacy: .public), awaiting response.")

      port.send(dataToSend) { [weak self] in
          guard let self = self else { return }
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: port.send completion block executed (data handed to SDK).")
          // This callback signifies that the Redpark SDK has accepted the data for sending.
          // The actual response from the peripheral will come via handleFrame.
      }

      // Set up a timeout for the response
      let workItem = DispatchWorkItem { [weak self] in
          guard let self = self else { return }
          if let promiseToReject = self.sendDataResponsePromise {
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAsync response timed out.")
              promiseToReject.reject("RESPONSE_TIMEOUT", "Timeout waiting for response from device after sending data.")
              self.sendDataResponsePromise = nil // Clear the promise
              self.sendDataResponseTimer = nil // Clear the timer item
          }
      }
      self.sendDataResponseTimer = workItem
      // Wait for 5 seconds for a response. Adjust this timeout as needed.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    AsyncFunction("manualStartDiscovery") { () -> Bool in
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: manualStartDiscovery called from JS.")

      let deviceManager = RedSerialDeviceManager.shared()
      // The previous guard let was removed because RedSerialDeviceManager.shared() returns a non-optional instance.
      // If there were a scenario where it could truly be unavailable,
      // the SDK's shared() method would need to return an Optional type.

      // Ensure delegate is set before starting discovery
      if deviceManager.delegate == nil {
          deviceManager.delegate = self.delegateProxy
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Delegate (re)set in manualStartDiscovery.")
      } else {
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Delegate was already set prior to manualStartDiscovery.")
      }
      
      deviceManager.startDiscovery()
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: manualStartDiscovery - discovery command issued.")

      // Check current connection state and report, or schedule a check
      if let port = self.redSerialPort {
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: manualStartDiscovery - Port already connected: \(port.description, privacy: .public)")
          self.sendEvent("onCableStatusChanged", [
              "status": true,
              "message": "Cable status checked via manual discovery: Connected.",
              "error": NSNull()
          ])
      } else {
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: manualStartDiscovery - No port currently connected. Scheduling check.")
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in // Using 2.5s timeout
              guard let self = self else { return }
              // If, after the delay, no port has been connected by handleDeviceDetected
              if self.redSerialPort == nil {
                  ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: manualStartDiscovery - Timeout, no cable detected after manual attempt.")
                  self.sendEvent("onCableStatusChanged", [
                      "status": false,
                      "message": "No cable detected after manual discovery attempt.",
                      "error": NSNull()
                  ])
              } else {
                  // If redSerialPort is not nil here, handleDeviceDetected would have already sent the true status event.
                  ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: manualStartDiscovery - Timeout, port was connected in the interim (event likely sent by handleDeviceDetected). Additional event from manual discovery suppressed.")
              }
          }
      }
      return true // Indicate the call was made and process initiated
    }

    AsyncFunction("sendDataAndAwaitFrameAsync") { (hexDataString: String, promise: Promise) in
      ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: >>> sendDataAndAwaitFrameAsync CALLED.")
      
      guard let port = self.redSerialPort else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: Send failed - Port not connected.")
        promise.reject("PORT_NOT_CONNECTED", "Port not connected for sendDataAndAwaitFrameAsync.")
        return
      }

      guard let dataToSend = self.dataFromHexString(hexDataString) else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: Send failed - Invalid HEX string: \(hexDataString, privacy: .public)")
        promise.reject("INVALID_HEX_STRING", "Invalid HEX string for sendDataAndAwaitFrameAsync.")
        return
      }

      // Critical section: Ensure only one send-and-await operation is active
      // This check uses the shared sendDataResponsePromise to ensure atomicity.
      if self.sendDataResponsePromise != nil {
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync called while another operation is awaiting response.")
          promise.reject("CONCURRENT_OPERATION", "Another send-and-await operation (e.g., sendDataAsync or another sendDataAndAwaitFrameAsync) is already in progress.")
          return
      }
      
      self.sendDataResponsePromise = promise // Assign the current promise to the shared property
      ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: Sending data: \(hexDataString, privacy: .public), awaiting framed response.")

      port.send(dataToSend) { [weak self] in
          // This callback from port.send merely indicates the SDK has accepted the data.
          // The actual device response will be processed by handleFrame.
          guard let self = self else { 
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: port.send completion block (self is nil).")
              return
          }
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: port.send completion block executed (data handed to SDK).")
      }

      // Cancel any pre-existing timer before starting a new one for this operation.
      self.sendDataResponseTimer?.cancel()

      // Set up a timeout for the response
      let workItem = DispatchWorkItem { [weak self] in
          guard let self = self else { return }
          // Check if the promise stored is still the one this timeout was for.
          // This is important if multiple calls could potentially race to set up timeouts,
          // though the sendDataResponsePromise check above should prevent that.
          if let promiseToReject = self.sendDataResponsePromise, (promiseToReject as AnyObject) === (promise as AnyObject) {
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync response timed out for its specific promise.")
              promiseToReject.reject("RESPONSE_TIMEOUT", "Timeout waiting for framed response from device for sendDataAndAwaitFrameAsync.")
              self.sendDataResponsePromise = nil // Clear the shared promise
              self.sendDataResponseTimer = nil // Clear the timer item itself
          } else if self.sendDataResponsePromise != nil {
              // This case means the timeout fired, but sendDataResponsePromise has since been changed (e.g., resolved or taken by another op that completed very fast)
              // or cleared by a successful response. The current workItem is stale.
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync timeout triggered, but the active sendDataResponsePromise is different or was already cleared.")
          } else {
              // sendDataResponsePromise is nil, meaning it was likely resolved and cleared.
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync timeout triggered, but no promise was pending. Likely resolved.")
          }
      }
      self.sendDataResponseTimer = workItem
      // Using a 5-second timeout. This can be adjusted as necessary.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    OnDestroy {
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Module OnDestroy called.")
      NotificationCenter.default.removeObserver(self)
      RedSerialDeviceManager.shared().delegate = nil
      redSerialPort?.delegate = nil

      // Clean up pending promise and timer
      self.sendDataResponseTimer?.cancel()
      self.sendDataResponseTimer = nil
      if let promise = self.sendDataResponsePromise {
          promise.reject("MODULE_DESTROYED", "The module was destroyed before a response was received.")
          self.sendDataResponsePromise = nil
      }

      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Module destroyed and cleaned up.")
    }
  }

  @objc func handleAppDidBecomeActive() {
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: App became active.")
    // RedSerialDeviceManager.shared().delegate = self.delegateProxy
    // RedSerialDeviceManager.shared().startDiscovery()
    if !self.hasFiredInitialStatusEvent && self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: App active, initial status not fired, no port. Checking cable status.")
        self.checkAndReportInitialCableStatus()
    } else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: App active, initial status fired or port exists. Ensuring discovery.")
        // Ensure delegate is set and discovery is running if app reactivates
        RedSerialDeviceManager.shared().delegate = self.delegateProxy
        RedSerialDeviceManager.shared().startDiscovery()
    }
  }

  @objc func handleAppWillResignActive() {
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: App will resign active.")
  }

  internal func handleDeviceDetected(port: RedSerialPort) {
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: >>> handleDeviceDetected CALLED for port: \(port.description, privacy: .public). Current self.redSerialPort is \(self.redSerialPort == nil ? "nil" : "non-nil", privacy: .public)")
    if self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: New device detected, assigning to self.redSerialPort: \(port.description, privacy: .public)")
        self.redSerialPort = port
        self.redSerialPort?.delegate = self.delegateProxy // Assign delegate to the port

        // Configure the port (baud rate, data bits, etc.)
        // These are examples, refer to RedSerial.h for actual available properties and methods
        // IMPORTANT: Check the RedSerial.xcframework headers for the correct API.
        // The following are placeholders and might be incorrect.
        // For example, if baudRate is a property:
        // self.redSerialPort?.baudRate = Int32(9600) // Example: 9600 baud
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Attempting to set baud rate to 9600.")
        if let currentPort = self.redSerialPort {
             // Assuming setBaudRate is the correct method. Adjust if it's a property.
             // No, the SDK uses properties directly: port.baudRate = 9600
             currentPort.baudRate = Int32(9600) // Example: 9600 baud
             ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Baud rate potentially set to 9600 for port: \(currentPort.description, privacy: .public)")

             // Placeholder for other configurations (Data bits, Parity, Stop bits)
             // e.g., port.setDataFormat(), port.setParity(), etc.
             // Check RedSerial.h for correct methods/properties.
             // For example, if dataSize is a property and enum:
             // currentPort.dataSize = .eightBits // Fictional example
        } else {
            ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: redSerialPort became nil before baud rate could be set.")
        }


        self.sendEvent("onCableStatusChanged", [
            "status": true,
            "message": "Cable connected, port ready.",
            "error": NSNull()
        ])
        self.hasFiredInitialStatusEvent = true // Mark that an initial status (connected) has been reported

        // Start receiving data continuously
        self.armReceive()
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: redSerialPort assigned and configured in handleDeviceDetected: \(self.redSerialPort?.description ?? "nil after assignment attempt", privacy: .public)")
    } else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Device detected but self.redSerialPort was already assigned. Detected: \(port.description, privacy: .public), Existing: \(self.redSerialPort?.description ?? "nil", privacy: .public)")
    }
  }

  internal func handleDeviceDisconnected(port: RedSerialPort) {
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: >>> handleDeviceDisconnected CALLED for port: \(port.description, privacy: .public). Current self.redSerialPort is \(self.redSerialPort?.description ?? "nil", privacy: .public)")
    // Check if the disconnected port is the one we are currently using OR if our current port is already nil (e.g. multiple disconnects)
    if self.redSerialPort == port || self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Disconnecting relevant port: \(port.description, privacy: .public). Setting self.redSerialPort to nil.")
        self.redSerialPort?.delegate = nil // Clear delegate first
        self.redSerialPort = nil
        self.sendEvent("onCableStatusChanged", [
            "status": false,
            "message": "Cable disconnected.",
            "error": NSNull()
        ])
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: self.redSerialPort is now nil after disconnection logic.")
    } else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: A device disconnected, but it wasn't the active self.redSerialPort. Disconnected: \(port.description, privacy: .public), Active: \(self.redSerialPort?.description ?? "nil", privacy: .public)")
    }
  }

  internal func handleError(message: String, context: String? = nil) {
    var fullMessage = message
    if let context = context {
      fullMessage += " (Context: \(context))"
    }
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: \(fullMessage, privacy: .public)")
    self.sendEvent("onError", [
        "status": false,
        "message": "An error occurred. Details: \(message)" + (context != nil ? " (Context: \(context!))" : ""),
        "error": fullMessage
    ])
  }

  // MARK: - Kick‑off one async read
  private func armReceive() {
    guard let port = redSerialPort, !readPending else { return }
    readPending = true

    port.recvData { [weak self] chunk in
      self?.onChunk(chunk)
    }
  }

  /// Called each time Redpark delivers a chunk
  private func onChunk(_ chunk: Data) {
    guard let port = redSerialPort else { return }
    readPending = false
    rxBuffer += chunk
    processBuffer(on: port)
    armReceive()                         // re‑arm for next chunk
  }

  private func processBuffer(on port: RedSerialPort) {
    var frames = 0
    while true {
      // 1 ▸ minimum frame size?
      guard rxBuffer.count >= 5 else { break }

      // 2 ▸ sync to STX
      guard rxBuffer[0] == Frame.STX else { rxBuffer.removeFirst(); continue }

      // 3 ▸ length field present?
      let lenMSB = rxBuffer[1], lenLSB = rxBuffer[2]
      let payloadLen = bcdLength(msb: lenMSB, lsb: lenLSB)
      guard (0...Frame.maxPayload).contains(payloadLen) else {
        rxBuffer.removeFirst(); continue
      }

      let etxIdx = 1 + 2 + payloadLen
      let needed = etxIdx + 2              // +ETX +LRC
      guard rxBuffer.count >= needed else { break }

      // 4 ▸ verify ETX
      guard rxBuffer[etxIdx] == Frame.ETX else {
        rxBuffer.removeFirst(); continue
      }

      // 5 ▸ LRC
      var calc: UInt8 = 0
      for byte in rxBuffer[1...etxIdx] { calc ^= byte }
      let recvLRC = rxBuffer[etxIdx + 1]
      let valid = (calc == recvLRC)

      // 6 ▸ payload slice
      let payload = Array(rxBuffer[3 ..< 3 + payloadLen])

      // 7 ▸ drop frame
      rxBuffer.removeFirst(needed)

      // 8 ▸ ACK/NAK + emit
      handleFrame(port: port, payload: payload, isValid: valid)

      frames += 1
      if frames > 100 { break }            // runaway guard
    }
  }

  private func handleFrame(port: RedSerialPort, payload: [UInt8], isValid: Bool) {
    port.send(Data([isValid ? Frame.ACK : Frame.NAK])) { }

    guard isValid else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Invalid frame received. Discarding.")
        // We are not rejecting the sendDataResponsePromise here on an invalid frame.
        // It will either be resolved by a subsequent valid frame or timeout.
        return
    }
    let hex = payload.map { String(format: "%02X", $0) }.joined()
    ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Valid frame processed. Payload: \(hex, privacy: .public)")

    if let promise = self.sendDataResponsePromise {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Resolving pending sendDataAsync promise with received data.")
        self.sendDataResponseTimer?.cancel() // Cancel the timeout
        self.sendDataResponseTimer = nil
        promise.resolve(hex)
        self.sendDataResponsePromise = nil // Clear the promise once resolved
    } else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: No pending sendDataAsync promise. Emitting onDataReceived event.")
        sendEvent("onDataReceived", ["data": hex])
    }
  }

  private func dataFromHexString(_ hexString: String) -> Data? {
    let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
      let byteString = String(hex[index..<nextIndex])
      guard let byte = UInt8(byteString, radix: 16) else { return nil }
      data.append(byte)
      index = nextIndex
    }
    return data
  }

  private func checkAndReportInitialCableStatus() {
    guard !self.hasFiredInitialStatusEvent else {
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Initial status already reported, skipping checkAndReportInitialCableStatus.")
        // If already reported, ensure discovery is on if there's no port connected yet (e.g. if this was called before port connected)
        if self.redSerialPort == nil {
            RedSerialDeviceManager.shared().delegate = self.delegateProxy
            RedSerialDeviceManager.shared().startDiscovery()
        }
        return
    }

    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: checkAndReportInitialCableStatus: Starting discovery to determine initial cable state.")
    RedSerialDeviceManager.shared().delegate = self.delegateProxy
    RedSerialDeviceManager.shared().startDiscovery()

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in // 2 second timeout
        guard let self = self else { return }

        // Check if a port was connected in the meantime OR if an initial event has already been fired by handleDeviceDetected
        if self.redSerialPort == nil && !self.hasFiredInitialStatusEvent {
            ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: checkAndReportInitialCableStatus: Timeout, no cable detected. Sending status false.")
            self.sendEvent("onCableStatusChanged", [
                "status": false,
                "message": "Cable initially not detected.",
                "error": NSNull()
            ])
            self.hasFiredInitialStatusEvent = true
        } else if self.redSerialPort != nil && !self.hasFiredInitialStatusEvent {
            // This case should ideally be covered by handleDeviceDetected setting the flag.
            // However, if handleDeviceDetected ran but somehow the flag wasn't set by the time this timer fires,
            // and a port IS connected, we should assume connected.
            // This situation is unlikely with current logic but good to be mindful.
            // For now, handleDeviceDetected is responsible for the 'true' event and flag.
            ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: checkAndReportInitialCableStatus: Timeout, port IS connected, but flag was not set. handleDeviceDetected should cover this.")
        } else {
            ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: checkAndReportInitialCableStatus: Timeout, but port connected or initial status already fired.")
        }
    }
  }
}