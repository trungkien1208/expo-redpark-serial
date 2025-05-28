// Reexport the native module. On web, it will be resolved to ExpoRedparkSerialModule.web.ts
// and on native platforms to ExpoRedparkSerialModule.ts
export { default } from './ExpoRedparkSerialModule';
export * from  './ExpoRedparkSerial.types';
