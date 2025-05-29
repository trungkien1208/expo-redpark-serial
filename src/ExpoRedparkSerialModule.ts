import { NativeModule, requireNativeModule } from 'expo-modules-core';

import type { CableStatusChangedEventPayload, DataReceivedEventPayload, ErrorEventPayload, TransactionProgressEventPayload } from './ExpoRedparkSerial.types';
// ExpoRedparkSerialModuleEvents is also available from types if needed for explicit NativeEventEmitter typing elsewhere

import { EventSubscription } from 'react-native';
import { ExpoRedparkSerialModuleEvents } from './ExpoRedparkSerial.types';

declare class ExpoRedparkSerialModule extends NativeModule<ExpoRedparkSerialModuleEvents> {
  onCableStatusChanged(listener: (event: CableStatusChangedEventPayload) => void): EventSubscription;
  onDataReceived(listener: (event: DataReceivedEventPayload) => void): EventSubscription;
  onError(listener: (event: ErrorEventPayload) => void): EventSubscription;
  onTransactionProgress(listener: (event: TransactionProgressEventPayload) => void): EventSubscription;
  sendDataAndAwaitFrameAsync(hexDataString: string): Promise<string>;
  manualStartDiscovery(): Promise<boolean>;
  isCableConnected(): Promise<boolean>;
  sendDataAsync(hexDataString: string): Promise<string>;
  setTransactionResponseTimeout(timeoutSeconds: number): Promise<boolean>;
  cancelPendingTransaction(): Promise<boolean>;
  isTransactionInProgress(): Promise<boolean>;
}


// This call loads the native module object from the JSI.
// The type assertion ensures that TypeScript knows about the methods.
const ExpoRedparkSerial = requireNativeModule<ExpoRedparkSerialModule>(
    'ExpoRedparkSerial'
);


export default ExpoRedparkSerial;