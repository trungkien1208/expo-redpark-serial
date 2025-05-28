import {NativeModule, requireNativeModule } from 'expo-modules-core';

import type { CableStatusChangedEventPayload, DataReceivedEventPayload, ErrorEventPayload, ExpoRedparkSerialNativeModule as ExpoRedparkSerialModuleInterface } from './ExpoRedparkSerial.types';
// ExpoRedparkSerialModuleEvents is also available from types if needed for explicit NativeEventEmitter typing elsewhere

import { ExpoRedparkSerialModuleEvents } from './ExpoRedparkSerial.types';
import { EventSubscription } from 'react-native';

declare class ExpoRedparkSerialModule extends NativeModule<ExpoRedparkSerialModuleEvents> {
  onCableStatusChanged(listener: (event: CableStatusChangedEventPayload) => void): EventSubscription;
  onDataReceived(listener: (event: DataReceivedEventPayload) => void): EventSubscription;
  onError(listener: (event: ErrorEventPayload) => void): EventSubscription;
}


// This call loads the native module object from the JSI.
// The type assertion ensures that TypeScript knows about the methods.
const ExpoRedparkSerial = requireNativeModule<ExpoRedparkSerialModule>(
    'ExpoRedparkSerial'
);


export default ExpoRedparkSerial;