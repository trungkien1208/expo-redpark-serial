export type CableStatusChangedEventPayload = {
  status: boolean;
  message: string;
  error: string | null;
};

export type DataReceivedEventPayload = {
  data: string;
};

export type ErrorEventPayload = {
  message: string; // Error message string
};

export type TransactionProgressEventPayload = {
  isInProgress: boolean;
  status: TransactionStatus;
  command: string;
  reason?: string;
  errorCode?: string;
  attempt?: number;
};

export enum TransactionStatus {
  // Progress
  TransactionInitiated = 'transaction_initiated',
  SendingCommand = 'sending_command',
  CommandAckReceived = 'command_ack_received',
  CommandNakReceived = 'command_nak_received',
  ImplicitAckWithData = 'implicit_ack_with_data',
  TransactionResponseReceived = 'transaction_response_received',
  CommandAckTimeout = 'command_ack_timeout',
  CommandRetryAttempt = 'command_retry_attempt',
  TransactionCancelling = 'transaction_cancelling',

  // Terminal States
  TransactionSuccessful = 'transaction_successful',
  TransactionSuccessfulImplicitAck = 'transaction_successful_implicit_ack',

  // Failures & Timeouts
  FailedPortNotConnected = 'transaction_failed_port_not_connected',
  FailedInvalidHex = 'transaction_failed_invalid_hex',
  FailedMaxInvalidFrames = 'transaction_failed_max_invalid_frames',
  FailedResponseTimeout = 'transaction_failed_response_timeout',
  FailedAckTimeoutMaxRetries = 'transaction_failed_ack_timeout_max_retries',
  FailedUserCancelled = 'transaction_failed_user_cancelled',
  FailedModuleDestroyed = 'transaction_failed_module_destroyed',
  FailedPortDisconnected = 'transaction_failed_port_disconnected',
  FailedInternalStateError = 'transaction_failed_internal_state_error',
  FailedInternalError = 'transaction_failed_internal_error',
}

// Defines the events that the native module can send to JavaScript
// This type is primarily for use with NativeEventEmitter
export type ExpoRedparkSerialModuleEvents = {
  onCableStatusChanged: (event: CableStatusChangedEventPayload) => void;
  onDataReceived: (event: DataReceivedEventPayload) => void;
  onTransactionProgress: (event: TransactionProgressEventPayload) => void;
  onError: (event: ErrorEventPayload) => void;
};

// Defines the methods available on the native module instance
export interface ExpoRedparkSerialNativeModule {
  isCableConnected: () => Promise<boolean>;
  sendDataAsync: (hexDataString: string) => Promise<string>;
  sendDataAndAwaitFrameAsync: (hexDataString: string) => Promise<string>;
  manualStartDiscovery: () => Promise<boolean>;
  setTransactionResponseTimeout: (timeoutSeconds: number) => Promise<boolean>;
  cancelPendingTransaction: () => Promise<boolean>;
  isTransactionInProgress: () => Promise<boolean>;
  // Add other functions here if you re-add them to the Swift module, e.g.:
  // setBaudRate: (baudRate: number) => Promise<boolean>;
}

