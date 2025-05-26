import * as React from 'react';

import { ExpoRedparkSerialViewProps } from './ExpoRedparkSerial.types';

export default function ExpoRedparkSerialView(props: ExpoRedparkSerialViewProps) {
  return (
    <div>
      <iframe
        style={{ flex: 1 }}
        src={props.url}
        onLoad={() => props.onLoad({ nativeEvent: { url: props.url } })}
      />
    </div>
  );
}
