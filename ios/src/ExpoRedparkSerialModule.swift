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
  private var mainTransactionPromise: Promise? // Renamed from sendDataResponsePromise
  private var mainTransactionTimer: DispatchWorkItem? // Renamed from sendDataResponseTimer
  // tracks consecutive invalid frames while a promise is pending
  private var invalidFrameStreak = 0

  // MARK: - New State Management & Retry Properties
  private enum TransactionState {
    case idle
    case awaitingCommandAck
    case awaitingTransactionResponse
  }
  private var currentTransactionState: TransactionState = .idle
  private var commandAckTimer: DispatchWorkItem?
  private var commandRetryCount: Int = 0
  private let maxCommandRetries: Int = 2 // Allows for 1 initial send + 2 retries
  private var originalHexDataString: String?
  private var transactionTimeoutDuration: TimeInterval = 60.0 // Default timeout for the main transaction response (e.g., for offline) - can be configured
  private let commandAckTimeoutDuration: TimeInterval = 2.0 // As per protocol section 2.2.2.2

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
    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Module initialized.") // Changed to info

    delegateProxy = RedparkDelegateProxy(module: self)
    // RedSerialDeviceManager.shared().delegate = delegateProxy // Delegate set in OnCreate or manualStartDiscovery
    // RedSerialDeviceManager.shared().startDiscovery() // Discovery initiated in OnCreate or manually
  }

  public func definition() -> ModuleDefinition {
    Name("ExpoRedparkSerial")

    Events("onCableStatusChanged", "onDataReceived", "onError", "onTransactionProgress")

    OnCreate {
      self.delegateProxy = RedparkDelegateProxy(module: self)
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Module OnCreate called.") // Changed to info

      self.hasFiredInitialStatusEvent = false

      NotificationCenter.default.addObserver(self, selector: #selector(self.handleAppDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(self.handleAppWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)

      if UIApplication.shared.applicationState == .active {
        self.checkAndReportInitialCableStatus()
      }
    }
    
    AsyncFunction("isCableConnected") { () -> Bool in
      let connected = self.redSerialPort != nil
      ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: isCableConnected check: \(connected ? "true" : "false", privacy: .public)") // Changed to debug
      return connected
    }

    AsyncFunction("isTransactionInProgress") { () -> Bool in
      let inProgress = self.isTransactionPending()
      ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: isTransactionInProgress → \(inProgress)")
      return inProgress
    }

    AsyncFunction("sendDataAsync") { (hexDataString: String, promise: Promise) in
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: >>> sendDataAsync CALLED (Promise version).") // Changed to info
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

      if self.mainTransactionPromise != nil {
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAsync called while another transaction is already awaiting response.") // Changed to warning
          promise.reject("CONCURRENT_OPERATION", "Another sendDataAsync or sendDataAndAwaitFrameAsync operation is already in progress.")
          return
      }

      self.invalidFrameStreak = 0
      self.mainTransactionPromise = promise
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Sending data (simple send): \(hexDataString, privacy: .public), awaiting response via handleFrame.") // Changed to info
      port.send(dataToSend) { [weak self] in
          if self != nil {
              ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: port.send completion block executed (data handed to SDK for simple send).") // Changed to debug
          }
      }

      let workItem = DispatchWorkItem { [weak self] in
          guard let self = self else { return }
          if let promiseToReject = self.mainTransactionPromise {
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAsync response timed out for promise: \(String(describing: promiseToReject), privacy: .public)")
              promiseToReject.reject("RESPONSE_TIMEOUT", "Timeout waiting for response from device after sending data (simple send).") // Removed "झाला आहे"
              
              if (self.mainTransactionPromise as AnyObject) === (promiseToReject as AnyObject) {
                 self.mainTransactionPromise = nil
                 self.mainTransactionTimer = nil
              }
          }
      }
      self.mainTransactionTimer = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    AsyncFunction("manualStartDiscovery") { () -> Bool in
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: manualStartDiscovery called from JS.") // Changed to info

      let deviceManager = RedSerialDeviceManager.shared()

      if deviceManager.delegate == nil {
          deviceManager.delegate = self.delegateProxy
          ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Delegate (re)set in manualStartDiscovery.") // Changed to info
      } else {
          ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Delegate was already set prior to manualStartDiscovery.") // Changed to debug
      }
      
      deviceManager.startDiscovery()
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: manualStartDiscovery - discovery command issued.") // Changed to info

      if let port = self.redSerialPort {
          ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: manualStartDiscovery - Port already connected: \(port.description, privacy: .public)") // Changed to info
          self.sendEvent("onCableStatusChanged", [
              "status": true,
              "message": "Cable status checked via manual discovery: Connected.",
              "error": NSNull()
          ])
      } else {
          ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: manualStartDiscovery - No port currently connected. Scheduling check.") // Changed to info
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
              guard let self = self else { return }
              if self.redSerialPort == nil {
                  ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: manualStartDiscovery - Timeout, no cable detected after manual attempt.") // Changed to info
                  self.sendEvent("onCableStatusChanged", [
                      "status": false,
                      "message": "No cable detected after manual discovery attempt.",
                      "error": NSNull()
                  ])
              } else {
                  ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: manualStartDiscovery - Timeout, port was connected in the interim (event likely sent by handleDeviceDetected). Additional event from manual discovery suppressed.") // Changed to debug
              }
          }
      }
      return true
    }

    AsyncFunction("sendDataAndAwaitFrameAsync") { (hexDataString: String, promise: Promise) in
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: >>> sendDataAndAwaitFrameAsync CALLED.") // Changed to info
      
      guard self.redSerialPort != nil else { // Ensured port variable is not defined if not used
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: Send failed - Port not connected.")
        // Use centralized rejection
        self._rejectPromiseAndSendErrorEvent(
            promise: promise,
            code: "PORT_NOT_CONNECTED",
            failureReason: "Port not connected for sendDataAndAwaitFrameAsync.",
            source: .portNotConnected
        )
        return
      }

      guard self.dataFromHexString(hexDataString) != nil else { // dataToSend not used directly here, just validated
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: sendDataAndAwaitFrameAsync: Send failed - Invalid HEX string: \(hexDataString, privacy: .public)")
        // Use centralized rejection
        self._rejectPromiseAndSendErrorEvent(
            promise: promise,
            code: "INVALID_HEX_STRING",
            failureReason: "Invalid HEX string for sendDataAndAwaitFrameAsync.",
            source: .invalidHex
        )
        return
      }

      if self.mainTransactionPromise != nil || self.currentTransactionState != .idle {
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: sendDataAndAwaitFrameAsync called while another operation is awaiting response or state is not idle.")
          promise.reject("CONCURRENT_OPERATION", "Another send-and-await operation is already in progress or module state is not idle.")
          return
      }

      self.mainTransactionPromise = promise
      self.originalHexDataString = hexDataString
      self.commandRetryCount = 0
      self.invalidFrameStreak = 0
      // State is set to .awaitingCommandAck in _sendCommandInternal's initialCall path

      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Starting transaction for: \(hexDataString, privacy: .public). Initializing state.")
      self.sendEvent("onTransactionProgress", [
          "status": "transaction_initiated",
          "command": hexDataString,
          "isInProgress": true,
          "reason": NSNull()
      ])
      self._sendCommandInternal(initialCall: true)
    }

    AsyncFunction("cancelPendingTransaction") { (promise: Promise) in
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: cancelPendingTransaction called from JS.") // Changed to info
      if self.currentTransactionState != .idle || self.mainTransactionPromise != nil {
        let commandForEvent = self.originalHexDataString ?? "N/A"
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Cancelling active transaction. Current state: \(String(describing: self.currentTransactionState), privacy: .public)")
        self.sendEvent("onTransactionProgress", [
            "status": "transaction_cancelling",
            "command": commandForEvent,
            "isInProgress": true,
            "reason": "user_request"
        ])
        
        // Use the mainTransactionPromise from self, as that's what we are cancelling.
        self._rejectPromiseAndSendErrorEvent(
            promise: self.mainTransactionPromise, 
            code: "TRANSACTION_CANCELLED_BY_USER",
            failureReason: "The pending data transaction was cancelled by the user.",
            source: .userCancellation
        )
        promise.resolve(true)
      } else {
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: No active transaction to cancel.")
        promise.resolve(false)
      }
    }

    AsyncFunction("setTransactionResponseTimeout") { (timeoutSeconds: Double) in
        guard timeoutSeconds > 0 else {
            ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Invalid timeout value: \(timeoutSeconds). Must be positive.") // Changed to warning
            return
        }
        self.transactionTimeoutDuration = TimeInterval(timeoutSeconds)
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Transaction response timeout set to \(timeoutSeconds) seconds.")
    }

    OnDestroy {
      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Module OnDestroy called.") // Changed to info
      NotificationCenter.default.removeObserver(self)
      RedSerialDeviceManager.shared().delegate = nil // SDK Shared instance delegate
      redSerialPort?.delegate = nil // Specific port instance delegate

      // commandAckTimer and mainTransactionTimer are cancelled by _resetTransactionState
      
      if self.isTransactionPending() { // Check if a transaction was active
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Module destroying during an active transaction. Cleaning up.")
          self._rejectPromiseAndSendErrorEvent(
              // Default promise (self.mainTransactionPromise) will be used
              code: "MODULE_DESTROYED",
              failureReason: "The module was destroyed during an active transaction.",
              source: .moduleDestroyed
          )
          // _resetTransactionState will be called by _rejectPromiseAndSendErrorEvent if mainTransactionPromise was set
      }
      self._resetTransactionState() // Ensure full cleanup regardless, idempotent.

      ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Module destroyed and cleaned up.") // Changed to info
    }
  }

  @objc func handleAppDidBecomeActive() {
    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: App became active.") // Changed to info
    if !self.hasFiredInitialStatusEvent && self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: App active, initial status not fired, no port. Checking cable status.") // Changed to info
        self.checkAndReportInitialCableStatus()
    } else {
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: App active, initial status may have been fired or port exists. Ensuring discovery.") // Changed to info
        RedSerialDeviceManager.shared().delegate = self.delegateProxy
        RedSerialDeviceManager.shared().startDiscovery()
    }
  }

  @objc func handleAppWillResignActive() {
    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: App will resign active.") // Changed to info
  }

  internal func handleDeviceDetected(port: RedSerialPort) {
    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: >>> handleDeviceDetected CALLED for port: \(port.description, privacy: .public). Current self.redSerialPort is \(self.redSerialPort == nil ? "nil" : "non-nil", privacy: .public)") // Changed to info
    if self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: New device detected, assigning to self.redSerialPort: \(port.description, privacy: .public)") // Changed to info
        self.redSerialPort = port
        self.redSerialPort?.delegate = self.delegateProxy

        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Attempting to set baud rate to 9600.") // Changed to info
        if let currentPort = self.redSerialPort {
             currentPort.baudRate = Int32(9600)
             ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Baud rate potentially set to 9600 for port: \(currentPort.description, privacy: .public)") // Changed to info
        } else {
            ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: redSerialPort became nil before baud rate could be set.")
        }

        self.sendEvent("onCableStatusChanged", [
            "status": true,
            "message": "Cable connected, port ready.",
            "error": NSNull()
        ])
        self.hasFiredInitialStatusEvent = true

        self.armReceive()
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: redSerialPort assigned and configured in handleDeviceDetected: \(self.redSerialPort?.description ?? "nil after assignment attempt", privacy: .public)") // Changed to info
    } else if self.redSerialPort != port {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Device detected (\(port.description, privacy: .public)) but a different self.redSerialPort (\(self.redSerialPort?.description ?? "nil", privacy: .public)) was already assigned. Ignoring new detection.") // Changed to warning
    } else {
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Device detected (\(port.description, privacy: .public)) but it's the same as current self.redSerialPort. No action needed.") // Changed to debug
    }
  }

  internal func handleDeviceDisconnected(port: RedSerialPort) {
    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: >>> handleDeviceDisconnected CALLED for port: \(port.description, privacy: .public). Current self.redSerialPort is \(self.redSerialPort?.description ?? "nil", privacy: .public)") // Changed to info
    if self.redSerialPort == port || self.redSerialPort == nil {
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Disconnecting relevant port: \(port.description, privacy: .public).") // Changed to info
        
        let wasTransactionEffectivelyPending = self.isTransactionPending()
        let capturedPromise = self.mainTransactionPromise 
        // originalHexDataString will be read by _rejectPromiseAndSendErrorEvent before _resetTransactionState (if called from there)
        // or it will be nil if _resetTransactionState is called before _rejectPromiseAndSendErrorEvent.

        // Reset state first, which clears timers, currentTransactionState, and mainTransactionPromise.
        // It's important to do this before nullifying the port, so any port operations in reset (if any) don't fail.
        self._resetTransactionState() 

        self.redSerialPort?.delegate = nil // Clear delegate of the specific port instance
        self.redSerialPort = nil           // Nullify our reference
        // RedSerialDeviceManager.shared().delegate should remain self.delegateProxy for future discoveries.

        if wasTransactionEffectivelyPending {
            ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Transaction was pending during disconnect. Rejecting and sending events.") // Changed to warning
            self._rejectPromiseAndSendErrorEvent(
                promise: capturedPromise, // Pass the promise that was active before reset
                code: "PORT_DISCONNECTED",
                failureReason: "Port disconnected during an active transaction.",
                source: .portDisconnectedDuringTransaction
            )
        }

        self.sendEvent("onCableStatusChanged", [
            "status": false,
            "message": "Cable disconnected.",
            "error": NSNull()
        ])
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: self.redSerialPort is now nil after disconnection logic.") // Changed to info
    } else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: A device disconnected (\(port.description, privacy: .public)), but it wasn't the active self.redSerialPort (\(self.redSerialPort?.description ?? "nil", privacy: .public)). Ignoring.")
    }
  }

  internal func handleError(message: String, context: String? = nil) {
    var fullMessage = message
    if let context = context {
      fullMessage += " (Context: \(context))"
    }
    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial Global Error Handler: \(fullMessage, privacy: .public)") // Clarified log
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
    #if DEBUG
    ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Arming receive for port.")
    #endif
    port.recvData { [weak self] chunk in
      self?.onChunk(chunk)
    }
  }

  /// Called each time Redpark delivers a chunk
  private func onChunk(_ chunk: Data) {
    guard redSerialPort != nil else {       // Port might have disconnected
        readPending = false
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: onChunk called but port is nil. Chunk discarded.")
        return
    }

    // ------------------------------------------------------------
    // 0 ▸ Intercept link‑layer single‑byte ACK / NAK immediately
    // ------------------------------------------------------------
    if chunk.count == 1,
       (chunk[0] == Frame.ACK || chunk[0] == Frame.NAK) {
        handleTransportToken(chunk[0])
        readPending = false       // ready for next arm
        armReceive()
        return                    // do NOT buffer this byte
    }

    // ------------------------------------------------------------
    // 1 ▸ Normal framed data path
    // ------------------------------------------------------------
    readPending = false
    rxBuffer.append(contentsOf: chunk)       // avoid array copy
    #if DEBUG
    ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Received chunk \(chunk.count) bytes. Buffer now \(self.rxBuffer.count).") // Added self.
    #endif

    processBuffer(on: redSerialPort!)        // safe unwrap
    armReceive()                             // re‑arm
  }

  private func processBuffer(on port: RedSerialPort) {
    var frames = 0
    while true {
      // 1 ▸ minimum frame size?
      guard rxBuffer.count >= 5 else { break }

      // 2 ▸ sync to STX
      guard rxBuffer[0] == Frame.STX else {
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: processBuffer - No STX at buffer start. Discarding byte: \(String(format: "%02X", self.rxBuffer[0]))") // Added self.
        #endif
        rxBuffer.removeFirst(); continue
      }

      // 3 ▸ length field present?
      let lenMSB = rxBuffer[1], lenLSB = rxBuffer[2]
      let payloadLen = bcdLength(msb: lenMSB, lsb: lenLSB)
      guard (0...Frame.maxPayload).contains(payloadLen) else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: processBuffer - Invalid BCD payload length: \(payloadLen). Discarding STX.")
        rxBuffer.removeFirst(); continue
      }

      let etxIdx = 1 + 2 + payloadLen
      let needed = etxIdx + 2              // +ETX +LRC
      guard rxBuffer.count >= needed else {
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: processBuffer - Incomplete frame. Needed: \(needed), Have: \(self.rxBuffer.count). Waiting for more data.") // Added self.
        #endif
        break
      }

      // 4 ▸ verify ETX
      guard rxBuffer[etxIdx] == Frame.ETX else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: processBuffer - ETX mismatch. Expected ETX at \(etxIdx), found \(String(format: "%02X", self.rxBuffer[etxIdx])). Discarding STX.") // Added self.
        rxBuffer.removeFirst(); continue
      }

      // 5 ▸ LRC
      var calc: UInt8 = 0
      for byte in rxBuffer[1...etxIdx] { calc ^= byte } // LRC includes LenMSB, LenLSB, Payload, ETX
      let recvLRC = rxBuffer[etxIdx + 1]
      let valid = (calc == recvLRC)
      if !valid {
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: processBuffer - LRC mismatch. Calculated: \(String(format: "%02X", calc)), Received: \(String(format: "%02X", recvLRC)).")
      }

      // 6 ▸ payload slice
      let payload = Array(rxBuffer[3 ..< 3 + payloadLen])

      // 7 ▸ drop frame
      rxBuffer.removeFirst(needed)
      // Hard cap to prevent runaway memory on corrupt streams
      if rxBuffer.count > 64 * 1024 {
        rxBuffer.removeAll()
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: RX buffer overflow (>64 KB). Buffer cleared.")
      }

      // 8 ▸ ACK/NAK + emit
      handleFrame(port: port, payload: payload, isValid: valid)

      frames += 1
      if frames > 100 { // Runaway guard
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: processBuffer - Processed 100 frames in one call, breaking loop (runaway guard).")
          break
      }
    }
  }
  // MARK: - Link‑layer token handler (raw ACK/NAK bytes)

  private func handleTransportToken(_ byte: UInt8) {
    switch (currentTransactionState, byte) {

    // -------- ACK received while waiting for command ACK ----------
    case (.awaitingCommandAck, Frame.ACK):
        commandAckTimer?.cancel()
        commandRetryCount = 0
        currentTransactionState = .awaitingTransactionResponse

        sendEvent("onTransactionProgress", [
            "status": "command_ack_received",
            "command": originalHexDataString ?? "N/A",
            "isInProgress": true,
            "reason": "ACK received (token), awaiting main response."
        ])

        // start / restart main transaction timer
        mainTransactionTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.currentTransactionState == .awaitingTransactionResponse else { return }
            ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Main response timeout after ACK (token).")
            self._rejectPromiseAndSendErrorEvent(
                code: "TRANSACTION_RESPONSE_TIMEOUT",
                failureReason: "Timeout waiting for main response after ACK token.",
                source: .transactionResponseTimeout
            )
        }
        mainTransactionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + transactionTimeoutDuration, execute: work)

    // -------- NAK received while waiting for command ACK ----------
    case (.awaitingCommandAck, Frame.NAK):
        commandAckTimer?.cancel()
        sendEvent("onTransactionProgress", [
            "status": "command_nak_received",
            "command": originalHexDataString ?? "N/A",
            "isInProgress": true,
            "reason": "NAK token received, attempting retry."
        ])
        _retryCommandOrFail()

    // -------- Unexpected token, log & ignore ----------------------
    default:
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Ignoring unsolicited transport token 0x\(String(format: "%02X", byte)). State: \(String(describing: self.currentTransactionState))")
        #endif
        break
    }
  }

  private func handleFrame(port: RedSerialPort, payload: [UInt8], isValid: Bool) {
    port.send(Data([isValid ? Frame.ACK : Frame.NAK])) { } // Send transport ACK/NAK for the received frame

    guard let activePromise = self.mainTransactionPromise else {
      if isValid {
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Received valid unsolicited frame. Emitting onDataReceived.")
        #endif
        let hex = payload.map { String(format: "%02X", $0) }.joined()
        sendEvent("onDataReceived", ["data": hex])
      } else {
        ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Received invalid unsolicited frame (LRC mismatch or framing error). Discarding.")
      }
      return
    }

    // A transaction is active (activePromise is not nil).
    if !isValid {
      self.invalidFrameStreak += 1
      ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: Received invalid frame during transaction. Streak: \(self.invalidFrameStreak). State: \(String(describing: self.currentTransactionState), privacy: .public)")
      if self.invalidFrameStreak >= 2 {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Max invalid frames (2) received. Failing transaction.")
        self._rejectPromiseAndSendErrorEvent(
            promise: activePromise, // This is self.mainTransactionPromise
            code: "MAX_INVALID_FRAMES",
            failureReason: "Received \(self.invalidFrameStreak) consecutive malformed/invalid frames during transaction.",
            source: .maxInvalidFrames
        )
      }
      return // Do not process payload further for invalid frames
    }

    self.invalidFrameStreak = 0 // Reset streak on valid frame
    let receivedHex = payload.map { String(format: "%02X", $0) }.joined()
    #if DEBUG
    ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Handling valid frame. State: \(String(describing: self.currentTransactionState), privacy: .public). Payload: \(receivedHex, privacy: .public)")
    #endif

    switch self.currentTransactionState {
      case .awaitingCommandAck:
        self.commandAckTimer?.cancel()

        if payload.count == 1 && payload[0] == Frame.ACK {
          #if DEBUG
          ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: ACK received for command. Transitioning to awaitingTransactionResponse.")
          #endif
          self.sendEvent("onTransactionProgress", [
              "status": "command_ack_received",
              "command": self.originalHexDataString ?? "N/A",
              "isInProgress": true,
              "reason": "ACK received, awaiting main response."
          ])
          self.commandRetryCount = 0
          self.currentTransactionState = .awaitingTransactionResponse
          
          self.mainTransactionTimer?.cancel()
          let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentTransactionState == .awaitingTransactionResponse else { return }
            ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Main transaction response timed out after ACK.")
            self._rejectPromiseAndSendErrorEvent(
                code: "TRANSACTION_RESPONSE_TIMEOUT",
                failureReason: "Timeout waiting for the main response from terminal after ACK.",
                source: .transactionResponseTimeout
            )
          }
          self.mainTransactionTimer = workItem
          DispatchQueue.main.asyncAfter(deadline: .now() + self.transactionTimeoutDuration, execute: workItem)

        } else if payload.count == 1 && payload[0] == Frame.NAK {
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: NAK received for command. Attempting retry.")
          self.sendEvent("onTransactionProgress", [
              "status": "command_nak_received",
              "command": self.originalHexDataString ?? "N/A",
              "isInProgress": true,
              "reason": "NAK received, attempting retry."
          ])
          self._retryCommandOrFail()
        } else {
          ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Received data frame instead of plain ACK/NAK while awaiting command ACK. Assuming implicit ACK. Payload: \(receivedHex, privacy: .public)") // Changed to info
          self.sendEvent("onTransactionProgress", [
              "status": "implicit_ack_with_data",
              "command": self.originalHexDataString ?? "N/A",
              "isInProgress": true, // Still in progress until resolved
              "reason": "Data received, assuming implicit ACK and treating as response."
          ])
          // No need to change currentTransactionState here, we resolve directly.
          self.mainTransactionTimer?.cancel() // Ensure no main timer from a prior ACK path interferes
          activePromise.resolve(receivedHex)
          self.sendEvent("onTransactionProgress", [
              "status": "transaction_successful_implicit_ack",
              "command": self.originalHexDataString ?? "N/A",
              "isInProgress": false,
              "reason": "Success with implicit ACK. Data: \(receivedHex)"
          ])
          self._resetTransactionState()
        }

      case .awaitingTransactionResponse:
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Received transaction response: \(receivedHex, privacy: .public)")
        #endif
        self.mainTransactionTimer?.cancel()
        self.sendEvent("onTransactionProgress", [
            "status": "transaction_response_received",
            "command": self.originalHexDataString ?? "N/A",
            "isInProgress": true, // Still in progress until resolved
            "reason": "Main response data received from terminal. Data: \(receivedHex)"
        ])
        activePromise.resolve(receivedHex)
        self.sendEvent("onTransactionProgress", [
            "status": "transaction_successful",
            "command": self.originalHexDataString ?? "N/A",
            "isInProgress": false,
            "reason": "Success. Data: \(receivedHex)"
        ])
        self._resetTransactionState()

      case .idle:
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: CRITICAL: Reached handleFrame with activePromise in .idle state. This should not happen. Payload: \(receivedHex, privacy: .public)")
        self._rejectPromiseAndSendErrorEvent(
            promise: activePromise,
            code: "INTERNAL_STATE_ERROR",
            failureReason: "Internal module state inconsistency: handleFrame called with activePromise while state was .idle.",
            source: .internalStateError
        )
    }
  }

  private func dataFromHexString(_ hexString: String) -> Data? {
    let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
      if hex.distance(from: index, to: nextIndex) != 2 && hex.distance(from: index, to: nextIndex) != 1 { // Allow last odd byte if any
          ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: dataFromHexString - Malformed hex string component around '\(String(hex[index..<nextIndex]))'.")
          // Allow single char if at end, pad with 0 implicitly by UInt8(byteString + "0", radix: 16) or handle error
          // For now, requiring full bytes.
          if hex.distance(from: index, to: nextIndex) == 1 {
              ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: dataFromHexString - Odd length hex string. Last char ignored: \(String(hex[index..<nextIndex]))")
              return data // or nil if strict
          }
      }
      let byteString = String(hex[index..<nextIndex])
      guard let byte = UInt8(byteString, radix: 16) else {
          ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: dataFromHexString - Invalid character in HEX string: \(byteString)")
          return nil
      }
      data.append(byte)
      index = nextIndex
    }
    return data
  }

  private func checkAndReportInitialCableStatus() {
    guard !self.hasFiredInitialStatusEvent else {
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Initial status already reported, skipping checkAndReportInitialCableStatus.")
        if self.redSerialPort == nil { // If reported but no port (e.g. initially false), ensure discovery is on
            RedSerialDeviceManager.shared().delegate = self.delegateProxy
            RedSerialDeviceManager.shared().startDiscovery()
            ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Ensured discovery is active as initial status reported but no port connected.")
        }
        return
    }

    ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: checkAndReportInitialCableStatus: Starting discovery to determine initial cable state.") // Changed to info
    RedSerialDeviceManager.shared().delegate = self.delegateProxy
    RedSerialDeviceManager.shared().startDiscovery()

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        guard let self = self else { return }

        if self.redSerialPort == nil && !self.hasFiredInitialStatusEvent {
            ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: checkAndReportInitialCableStatus: Timeout, no cable detected. Sending status false.") // Changed to info
            self.sendEvent("onCableStatusChanged", [
                "status": false,
                "message": "Cable initially not detected.",
                "error": NSNull()
            ])
            self.hasFiredInitialStatusEvent = true // Mark that an initial status (disconnected) has been reported
        } else { // Port connected or event fired by handleDeviceDetected
            ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: checkAndReportInitialCableStatus: Timeout, but port likely connected or initial status already fired by handleDeviceDetected.")
        }
    }
  }

  /// Returns `true` if a sendData‑family promise is currently awaiting a response OR if the state machine is not idle.
  private func isTransactionPending() -> Bool {
    return self.mainTransactionPromise != nil || self.currentTransactionState != .idle
  }

  // MARK: - Private Helpers for Transaction State Machine

  private func _resetTransactionState() {
    let finalState = self.currentTransactionState 
    let wasPromisePending = self.mainTransactionPromise != nil

    #if DEBUG
    ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: Resetting transaction state. Was: \(String(describing: finalState), privacy: .public), Promise was pending: \(wasPromisePending)")
    #endif
    
    self.commandAckTimer?.cancel()
    self.commandAckTimer = nil
    self.mainTransactionTimer?.cancel()
    self.mainTransactionTimer = nil
    
    self.mainTransactionPromise = nil 
    self.originalHexDataString = nil
    self.commandRetryCount = 0
    self.invalidFrameStreak = 0 // Reset this important counter
    self.currentTransactionState = .idle

    // No "transaction_idle" event here; specific success/failure events are preferred.
  }

  private func _sendCommandInternal(initialCall: Bool = false) {
    guard let port = self.redSerialPort else {
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: _sendCommandInternal - Port not connected.")
      self._rejectPromiseAndSendErrorEvent(code: "PORT_NOT_CONNECTED", failureReason: "Port not connected when trying to send command.", source: .portNotConnected) // Changed source
      return
    }
    guard let hexCmd = self.originalHexDataString, let dataToSend = dataFromHexString(hexCmd) else {
      ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: _sendCommandInternal - Invalid original hex string.")
      self._rejectPromiseAndSendErrorEvent(code: "INVALID_INTERNAL_HEX", failureReason: "Internal error: original hex command string is invalid or nil.", source: .internalError)
      return
    }

    if initialCall { 
        self.currentTransactionState = .awaitingCommandAck // Set state only on the very first call of a transaction
    }
    
    let attemptNumber = self.commandRetryCount + 1 // For logging/event (1-based)
    #if DEBUG
    ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: _sendCommandInternal - Sending command (attempt #\(attemptNumber) of \(self.maxCommandRetries + 1)): \(hexCmd, privacy: .public). State: \(String(describing: self.currentTransactionState), privacy: .public)") // Added self.
    #endif
    self.sendEvent("onTransactionProgress", [
        "status": "sending_command",
        "command": hexCmd,
        "isInProgress": true,
        "attempt": attemptNumber, // Added attempt number
        "reason": "Sending command (attempt #\(attemptNumber))."
    ])
    port.send(dataToSend) { [weak self] in
        guard let self = self else { return }
        
        guard self.currentTransactionState == .awaitingCommandAck else { 
            ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: port.send completed, but transaction state is no longer awaitingCommandAck (was \(String(describing: self.currentTransactionState))). ACK timer not started.")
            return 
        }
         
        #if DEBUG
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: port.send for command '\(hexCmd)' completed by SDK. Starting ACK timer.")
        #endif
        self.commandAckTimer?.cancel()
        let ackWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentTransactionState == .awaitingCommandAck else { return }
            ExpoRedparkSerialModule.log.warning("ExpoRedparkSerial: ACK Timeout for command: \(self.originalHexDataString ?? "N/A", privacy: .public). Retrying or failing.")
            self.sendEvent("onTransactionProgress", [ // Event for ACK timeout occurring
                "status": "command_ack_timeout",
                "command": self.originalHexDataString ?? "N/A",
                "isInProgress": true, // Still in progress until retry/fail is decided
                "reason": "Timeout waiting for command ACK. Current retries: \(self.commandRetryCount)."
            ])
            self._retryCommandOrFail() // Centralized retry/failure logic
        }
        self.commandAckTimer = ackWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + self.commandAckTimeoutDuration, execute: ackWorkItem)
    }
  }

  private func _retryCommandOrFail() {
    if self.commandRetryCount < self.maxCommandRetries {
        self.commandRetryCount += 1
        ExpoRedparkSerialModule.log.info("ExpoRedparkSerial: Retrying command. This will be attempt #\(self.commandRetryCount + 1).")
        self.sendEvent("onTransactionProgress", [
            "status": "command_retry_attempt",
            "command": self.originalHexDataString ?? "N/A",
            "isInProgress": true,
            "attempt": self.commandRetryCount + 1,
            "reason": "Retrying command due to NAK or ACK timeout. Attempt #\(self.commandRetryCount + 1)."
        ])
        self._sendCommandInternal(initialCall: false) // Resend, not an initial call for state setting
    } else {
        ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Max command retries (\(self.maxCommandRetries + 1) total attempts) reached. Failing transaction.")
        self._rejectPromiseAndSendErrorEvent(
            code: "MAX_COMMAND_RETRIES_EXCEEDED",
            failureReason: "Maximum command retries (\(self.maxCommandRetries + 1) total attempts) exceeded after NAK or ACK timeout.",
            source: .ackTimeout 
        )
    }
  }

  // New enum for source of rejection, to help _rejectPromiseAndSendErrorEvent
  private enum RejectionSource {
    case portNotConnected
    case invalidHex
    case maxInvalidFrames
    case transactionResponseTimeout
    case ackTimeout // Covers max retries for ACK
    case userCancellation
    case moduleDestroyed
    case portDisconnectedDuringTransaction
    case internalStateError
    case internalError // Generic internal issues like invalid original hex
  }

  // Helper to reject promise and send a consistent error event
  private func _rejectPromiseAndSendErrorEvent(promise: Promise? = nil, code: String, failureReason: String, detailedContext: String? = nil, source: RejectionSource) {
    let promiseToReject = promise ?? self.mainTransactionPromise
    // self.originalHexDataString might be nil if _resetTransactionState was called before this.
    // This is acceptable; the event will show "N/A" for the command.
    let commandForEvent = self.originalHexDataString ?? "N/A" 
    
    var contextMessage = ""
    if let context = detailedContext {
        contextMessage = " Context: [\(context)]"
    }
    let fullErrorString = "\(failureReason)\(contextMessage)"

    ExpoRedparkSerialModule.log.error("ExpoRedparkSerial: Transaction Failed - Code: [\(code)], Reason: [\(fullErrorString, privacy: .public)], Source: \(String(describing: source))")

    let progressStatusString: String 
    switch source {
        case .portNotConnected: progressStatusString = "transaction_failed_port_not_connected"
        case .invalidHex: progressStatusString = "transaction_failed_invalid_hex"
        case .maxInvalidFrames: progressStatusString = "transaction_failed_max_invalid_frames"
        case .transactionResponseTimeout: progressStatusString = "transaction_failed_response_timeout"
        case .ackTimeout: progressStatusString = "transaction_failed_ack_timeout_max_retries" // More specific
        case .userCancellation: progressStatusString = "transaction_failed_user_cancelled" 
        case .moduleDestroyed: progressStatusString = "transaction_failed_module_destroyed"
        case .portDisconnectedDuringTransaction: progressStatusString = "transaction_failed_port_disconnected"
        case .internalStateError: progressStatusString = "transaction_failed_internal_state_error"
        case .internalError: progressStatusString = "transaction_failed_internal_error"
    }
    
    self.sendEvent("onTransactionProgress", [
        "status": progressStatusString,
        "command": commandForEvent,
        "isInProgress": false, // Transaction is now concluded (failed)
        "reason": failureReason,
        "errorCode": code // Include error code in progress event
    ])

    self.sendEvent("onError", [
        "status": false,
        "message": "Transaction failed: \(failureReason)",
        "error": fullErrorString,
        "code": code,
        "commandContext": commandForEvent // Add command context to general error
    ])

    promiseToReject?.reject(code, fullErrorString) // Reject with the full error string for more detail

    // If the promise we just rejected was indeed the one stored in self.mainTransactionPromise (at the time of checking),
    // or if the source indicates a scenario where the main transaction machinery should be reset.
    // This ensures _resetTransactionState is called to clean up.
    // It's crucial if mainTransactionPromise was non-nil and was the target of this rejection.
    // If promiseToReject was a different promise (not current usage) or mainTransactionPromise was already nil,
    // this specific call to _resetTransactionState might be skipped, assuming reset happened elsewhere or wasn't needed for *this* promise.
    if let pToReject = promiseToReject,
       let currentMainP = self.mainTransactionPromise, // Check current main promise
       (pToReject as AnyObject) === (currentMainP as AnyObject) {
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: _rejectPromiseAndSendErrorEvent is resetting transaction state as the rejected promise was the main one.")
        self._resetTransactionState()
    } else if source == .moduleDestroyed || source == .portDisconnectedDuringTransaction {
        // For these critical events, even if the promise linkage is odd, ensure reset.
        // _resetTransactionState might have already been called by the caller in these cases.
        // Calling it again is idempotent and ensures cleanup.
        ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: _rejectPromiseAndSendErrorEvent called with source \(String(describing: source)). Ensuring state reset if not already done for main promise.")
        if self.mainTransactionPromise != nil || self.currentTransactionState != .idle { // Check if state still indicates activity
             // self._resetTransactionState() // The caller (OnDestroy, handleDeviceDisconnected) handles this more explicitly.
                                           // This ensures _reset is not called twice too eagerly from here if caller did it.
                                           // The primary reset responsibility remains with the caller for these specific sources,
                                           // or if the main promise was directly rejected.
        }
    } else if promiseToReject != nil && self.mainTransactionPromise == nil {
         ExpoRedparkSerialModule.log.debug("ExpoRedparkSerial: _rejectPromiseAndSendErrorEvent: Rejected a promise, but mainTransactionPromise was already nil. State likely reset by another path or this was not the main transaction promise. Source: \(String(describing: source))")
    }
  }
}