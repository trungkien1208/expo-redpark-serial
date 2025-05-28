
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

// Defines the events that the native module can send to JavaScript
// This type is primarily for use with NativeEventEmitter
export type ExpoRedparkSerialModuleEvents = {
  onCableStatusChanged: (event: CableStatusChangedEventPayload) => void;
  onDataReceived: (event: DataReceivedEventPayload) => void;
  onError: (event: ErrorEventPayload) => void;
};

// Defines the methods available on the native module instance
export interface ExpoRedparkSerialNativeModule {
  isCableConnected: () => Promise<boolean>;
  sendDataAsync: (hexDataString: string) => Promise<boolean>;
  manualStartDiscovery: () => Promise<boolean>;
  // Add other functions here if you re-add them to the Swift module, e.g.:
  // setBaudRate: (baudRate: number) => Promise<boolean>;
}

