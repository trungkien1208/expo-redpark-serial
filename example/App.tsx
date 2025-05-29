  import { useEvent } from 'expo';
  import { useEffect, useState } from 'react';
  import { Button, SafeAreaView, ScrollView, Text, TextInput, View } from 'react-native';
  import ExpoRedparkSerial from 'expo-redpark-serial';
  import { decodeTerminalResponseHex, getNETSPurchaseMessage } from './NetsTerminal.services';


  export default function App() {
    const [isCableConnected, setIsCableConnected] = useState(false);
    const dataOnCableStatusChanged = useEvent(ExpoRedparkSerial, 'onCableStatusChanged');
    const [receivedData, setReceivedData] = useState('');
    const [messageSent, setMessageSent] = useState('');
    const handleCableConnected = () => {
      setIsCableConnected(true);
    };

    const handleCableDisconnected = () => {
      setIsCableConnected(false);
    };

    const sendData = async () => {
      try {
        const result = await ExpoRedparkSerial.sendDataAndAwaitFrameAsync(messageSent);
        console.log('Send data result:', result);
        setReceivedData(result);
      } catch (error) {
        console.error('Send data error:', error);
      }
    };

    const discovery = async () => {
      console.log('Discovery');
      const result = await ExpoRedparkSerial.manualStartDiscovery();
      console.log('Discovery result:', result);
      setIsCableConnected(result);
    };

    useEffect(() => {
      console.log('Data received event:', dataOnCableStatusChanged);
      setIsCableConnected(dataOnCableStatusChanged?.status || false);
    }, [dataOnCableStatusChanged]);

    useEffect(() => {
      async function checkCableConnection() {
        console.log('Checking cable connection');
        const isConnected = await ExpoRedparkSerial.isCableConnected();
        console.log('Cable connection status:', isConnected);
        setIsCableConnected(isConnected);
      }

      checkCableConnection();
    }, []);

    return (
      <SafeAreaView style={styles.container}>
        <ScrollView style={styles.container}>
          <Text style={styles.header}>Module API Example</Text>
          <Group name="Cable Status">
            <Text style={{ fontSize: 20, marginBottom: 20 }}>Status:
              <Text style={{ fontSize: 20, marginBottom: 20, color: isCableConnected ? 'green' : 'red', fontWeight: 'bold' }}>{isCableConnected ? 'Connected' : 'Disconnected'}</Text>
            </Text>
          </Group>
          <Group name="Generate Message">
            <TextInput
              style={styles.input}
              value={messageSent}
              onChangeText={setMessageSent}
              placeholder="Enter data to send"
            />
            <Button title="Generate Data" onPress={() => {
              setMessageSent(getNETSPurchaseMessage(20));
            }} />
          </Group>
          <Group name="Data Sent">
            <Button title="Send Data" onPress={sendData} />
          </Group>
          <Group name="Data Received">
            {Array.isArray(decodeTerminalResponseHex(receivedData ?? '')) && decodeTerminalResponseHex(receivedData ?? '').map((item) => (
              <Text>{item.label}: {item.data}</Text>
            ))}
          </Group>
        <Group name="Discovery"> 
            <Button title="Discovery" onPress={discovery} />
          </Group>
        </ScrollView>
      </SafeAreaView>
    );
  }

  function Group(props: { name: string; children: React.ReactNode }) {
    return (
      <View style={styles.group}>
        <Text style={styles.groupHeader}>{props.name}</Text>
        {props.children}
      </View>
    );
  }

  const styles = {
    header: {
      fontSize: 30,
      margin: 20,
    },
    groupHeader: {
      fontSize: 20,
      marginBottom: 20,
    },
    group: {
      margin: 20,
      backgroundColor: '#fff',
      borderRadius: 10,
      padding: 20,
    },
    container: {
      flex: 1,
      backgroundColor: '#eee',
    },
    view: {
      flex: 1,
      height: 200,
    },
    input: {
      height: 40,
      borderColor: 'gray',
      borderWidth: 1,
      marginBottom: 10,
      padding: 10,
    },
  };
