import { NativeModule, requireNativeModule } from 'expo';

import { ExpoRedparkSerialModuleEvents } from './ExpoRedparkSerial.types';

declare class ExpoRedparkSerialModule extends NativeModule<ExpoRedparkSerialModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ExpoRedparkSerialModule>('ExpoRedparkSerial');
