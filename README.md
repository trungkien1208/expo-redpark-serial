# expo-redpark-serial

Wrapper Redpark SDK

**expo-redpark-serial** is an Expo module that enables your React Native application to communicate with Redpark serial cables (like the Redpark Serial Cable C2-DB9 or C2-TTL) on iOS devices. It provides an interface to detect cable connection, send and receive data, and manage the serial port.

## Key Features

*   **Cable Connection Management:**
    *   Detects when a Redpark serial cable is connected or disconnected.
    *   Provides an event (`onCableStatusChanged`) to notify your application of these changes.
    *   Allows checking the current connection status (`isCableConnectedAsync`).
*   **Data Transmission:**
    *   Send data to the serial device as a hexadecimal string (`sendDataAsync`, `sendDataAndAwaitFrameAsync`).
    *   Receive data from the serial device. Data is emitted via an event (`onDataReceived`) as a hexadecimal string.
*   **Request-Response Pattern:**
    *   Provides a promise-based function (`sendDataAndAwaitFrameAsync`) to send data and wait for a specific response frame from the device, with a timeout mechanism.
*   **Device Discovery:**
    *   Supports manual initiation of the device discovery process (`manualStartDiscoveryAsync`).
*   **Error Handling:**
    *   Emits an `onError` event for issues encountered during operations.
*   **Low-Level Communication Details:**
    *   Handles Redpark SDK specifics for port configuration (e.g., baud rate is set to 9600 by default within the native module).
    *   Implements a framing protocol (STX, ETX, BCD length, LRC checksum) for robust data packet exchange with the connected peripheral.

This module is essential for applications that need to interface with external hardware using a serial connection via Redpark's accessories on iOS.

# API documentation

- [Documentation for the latest stable release](https://docs.expo.dev/versions/latest/sdk/redpark-serial/)
- [Documentation for the main branch](https://docs.expo.dev/versions/unversioned/sdk/redpark-serial/)

# Installation in managed Expo projects

For [managed](https://docs.expo.dev/archive/managed-vs-bare/) Expo projects, please follow the installation instructions in the [API documentation for the latest stable release](#api-documentation). If you follow the link and there is no documentation available then this library is not yet usable within managed projects &mdash; it is likely to be included in an upcoming Expo SDK release.

# Installation in bare React Native projects

For bare React Native projects, you must ensure that you have [installed and configured the `expo` package](https://docs.expo.dev/bare/installing-expo-modules/) before continuing.

### Add the package to your npm dependencies

```
npm install expo-redpark-serial
```

### Configure for Android




### Configure for iOS

Run `npx pod-install` after installing the npm package.

# Contributing

Contributions are very welcome! Please refer to guidelines described in the [contributing guide]( https://github.com/expo/expo#contributing).
