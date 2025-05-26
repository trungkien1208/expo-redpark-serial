import { registerWebModule, NativeModule } from 'expo';

import { ExpoRedparkSerialModuleEvents } from './ExpoRedparkSerial.types';

class ExpoRedparkSerialModule extends NativeModule<ExpoRedparkSerialModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ExpoRedparkSerialModule, 'ExpoRedparkSerialModule');
