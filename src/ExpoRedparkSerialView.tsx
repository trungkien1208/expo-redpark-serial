import { requireNativeView } from 'expo';
import * as React from 'react';

import { ExpoRedparkSerialViewProps } from './ExpoRedparkSerial.types';

const NativeView: React.ComponentType<ExpoRedparkSerialViewProps> =
  requireNativeView('ExpoRedparkSerial');

export default function ExpoRedparkSerialView(props: ExpoRedparkSerialViewProps) {
  return <NativeView {...props} />;
}
