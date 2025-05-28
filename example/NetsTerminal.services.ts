export interface ITransactionTypeIndicator {
  FIELD_CODE: string;
  DATA: {
    ALL_NETS_PURCHASE: string;
    NETS_PURCHASE_WITH_CASHBACK: string;
    CASHBACK: string;
    NETS_QR_PURCHASE: string;
  };
}

export interface ITransactionAmount {
  FIELD_CODE: string;
  DATA: string;
}

export interface IEnhancedECRReferenceNumber {
  FIELD_CODE: string;
}

export interface IAllNetsPurchaseTransaction {
  FUNCTION_CODE: string;
  VERSION_CODE: string;
  TRANSACTION_TYPE_INDICATOR: ITransactionTypeIndicator;
  TRANSACTION_AMOUNT: ITransactionAmount;
}

export interface ICreditCardSaleTransaction {
  FUNCTION_CODE: string;
  VERSION_CODE: string;
  TRANSACTION_AMOUNT: ITransactionAmount;
  ENHANCED_ECR_REFERENCE_NUMBER: IEnhancedECRReferenceNumber;
}

export interface ICardSettlementTransaction {
  FUNCTION_CODE: string;
  VERSION_CODE: string;
}

export interface IExampleTransaction {
  ECN: string;
  FUNCTION_CODE: string;
  RESPONSE_CODE: string;
  FIELD_CODE: string;
  DATA: string;
}

export interface ILogonTransaction {
  FUNCTION_CODE: string;
  VERSION_CODE: string;
}

export interface IMessageHeaderParams {
  ecn: string;
  functionCode: string;
  responseCode: string;
  rfu: string;
}

export interface IMessageDataParams {
  fieldCode: string;
  data: string;
}

export interface IResponseMessageParams {
  header: string;
  data?: string[];
}

export const RESPONSE_MESSAGE_CONFIG = {
  header: {
    ecn: {
      label: "ECN",
      length: 12,
    },
    functionCode: {
      label: "Function Code",
      length: 2,
    },
    responseCode: {
      label: "Response Code",
      length: 2,
    },
    rfu: {
      label: "RFU",
      length: 1,
    },
    separator: {
      label: "Separator",
      length: 1,
    },
  },
  data: {
    "02": {
      label: "Response Text",
      length: 40,
    },
    D0: {
      label: "Merchant Name and Address",
      length: 69,
    },
    "03": {
      label: "Transaction Date",
      length: 6,
    },
    "04": {
      label: "Transaction Time",
      length: 6,
    },
    "16": {
      label: "Terminal ID",
      length: 8,
    },
    D1: {
      label: "Merchant ID",
      length: 15,
    },
    "65": {
      label: "STAN",
      length: 6,
    },
    "01": {
      label: "Approval Code",
      length: 6,
    },
    D3: {
      label: "Retrieval Reference Number",
      length: 12,
    },
    L7: {
      label: "Card Name",
      length: 20,
    },
    "40": {
      label: "Transaction Amount",
      length: 12,
    },
    "42": {
      label: "Cashback Amount",
      length: 12,
    },
    "41": {
      label: "Service Fee",
      length: 12,
    },
    L5: {
      label: "POS Messages",
      length: 240,
    },
    R0: {
      label: "Response Message I",
      length: 20,
    },
    R1: {
      label: "Response Message II",
      length: 20,
    },
    L1: {
      label: "Loyalty Program Name",
      length: 24,
    },
    L8: {
      label: "Loyalty Program Exp Date",
      length: 8,
    },
    L2: {
      label: "Loyalty Type",
      length: 1,
    },
    L9: {
      label: "Loyalty Marketing Message",
      length: 143,
    },
    L3: {
      label: "Redemption Value",
      length: 12,
    },
    L4: {
      label: "Current Loyalty Balance",
      length: 12,
    },
    HC: {
      label: "Host Response Code",
      length: 2,
    },
    CN: {
      label: "Card Entry Mode",
      length: 2,
    },
    HD: {
      label: "Enhanced ECR Reference Number",
      length: 12,
    },
    RP: {
      label: "Receipt Text Format",
      length: null, // Variable length
    },
  },
};

import { Buffer } from "buffer";

const DEFAULT_RESPONSE_TRANSACTION = {
  STX: "02",
  ETX: "03",
  RFU: "0",
  SEPARATOR: "1C",
} as const;

const ALL_NETS_PURCHASE_TRANSACTION: IAllNetsPurchaseTransaction = {
  FUNCTION_CODE: "30",
  VERSION_CODE: "01",
  TRANSACTION_TYPE_INDICATOR: {
    FIELD_CODE: "T2",
    DATA: {
      ALL_NETS_PURCHASE: "01",
      NETS_PURCHASE_WITH_CASHBACK: "02",
      CASHBACK: "03",
      NETS_QR_PURCHASE: "04",
    },
  },
  TRANSACTION_AMOUNT: {
    FIELD_CODE: "40",
    DATA: "0000000000000000", // 12 digits
  },
};

const CREDIT_CARD_SALE_TRANSACTION: ICreditCardSaleTransaction = {
  FUNCTION_CODE: "I0",
  VERSION_CODE: "01",
  TRANSACTION_AMOUNT: {
    FIELD_CODE: "40",
    DATA: "0000000000000000", // 12 digits
  },
  ENHANCED_ECR_REFERENCE_NUMBER: {
    FIELD_CODE: "HD",
  },
};

const CARD_SETTLEMENT_TRANSACTION: ICardSettlementTransaction = {
  FUNCTION_CODE: "I5",
  VERSION_CODE: "01",
};

// const EXAMPLE_TRANSACTION: IExampleTransaction = {
//   ECN: "A1234567890B",
//   FUNCTION_CODE: "CC",
//   RESPONSE_CODE: "00",
//   FIELD_CODE: "FC",
//   DATA: "DATA",
// };

const LOGON_TRANSACTION: ILogonTransaction = {
  FUNCTION_CODE: "80",
  VERSION_CODE: "01",
};

// const hexToEscapedByteString = (hexString: string): string => {
//   return (hexString.match(/.{1,2}/g) || []) // Split hex into pairs
//     .map((byte) => `\\x${byte}`) // Add escaped \x
//     .join("");
// };

const convertToHex = (str: string): string => {
  return new TextEncoder()
    .encode(str)
    .reduce((acc, byte) => acc + byte.toString(16).padStart(2, "0"), "");
};

const calculateBytes = (hexString: string): number => {
  return hexString.length / 2;
};

const calculateLRC = (hexString: string): string => {
  const bytes =
    hexString
      .match(/.{1,2}/g) // Split hex into byte pairs
      ?.map((byte) => parseInt(byte, 16)) || []; // Convert to decimal

  let lrc = 0x00; // Initialize LRC as 0
  bytes.forEach((byte) => {
    lrc ^= byte; // XOR operation
  });

  return lrc.toString(16).toUpperCase().padStart(2, "0"); // Return LRC in uppercase hex
};

// const communicateWithTerminal = (message: string): string => {
//   return `echo "${message}" | xxd -r -p | nc 192.168.1.49 8800`;
// };

const generateECNBaseonDateTime = (): string => {
  const date = new Date();
  const year = date.getFullYear().toString().slice(-2);
  const month = (date.getMonth() + 1).toString().padStart(2, "0");
  const day = date.getDate().toString().padStart(2, "0");
  const hour = date.getHours().toString().padStart(2, "0");
  const minute = date.getMinutes().toString().padStart(2, "0");
  const second = date.getSeconds().toString().padStart(2, "0");
  return `${year}${month}${day}${hour}${minute}${second}`;
};

const generateECNReferenceNumber = (prefix: string): string => {
  return `${prefix}${generateECNBaseonDateTime()}`;
};

const getMessageHeader = ({
  ecn,
  functionCode,
  responseCode,
  rfu,
}: IMessageHeaderParams): string => {
  return `${ecn}${functionCode}${responseCode}${rfu}`;
};

const getMessageData = ({ fieldCode, data }: IMessageDataParams): string => {
  const fieldLength = data.length.toString().padStart(4, "0"); // 4 digits
  return `${convertToHex(fieldCode)}${fieldLength}${convertToHex(data)}`;
};

const getResponseMessage = ({ header, data = [] }: IResponseMessageParams) => {
  const headerWithSeparator = `${convertToHex(header)}${DEFAULT_RESPONSE_TRANSACTION.SEPARATOR}`;
  const dataWithSeparator = data
    .map((byte) => `${byte}${DEFAULT_RESPONSE_TRANSACTION.SEPARATOR}`)
    .join("");

  const messageLength = calculateBytes(
    `${headerWithSeparator}${dataWithSeparator}`,
  )
    .toString()
    .padStart(4, "0");

  const messageWithoutSTX = `${messageLength}${headerWithSeparator}${dataWithSeparator}${DEFAULT_RESPONSE_TRANSACTION.ETX}`;

  const lrc = calculateLRC(messageWithoutSTX);

  const message = `${DEFAULT_RESPONSE_TRANSACTION.STX}${messageWithoutSTX}${lrc}`;

  return message;
};

// const getMessageExample = (): string => {
//   const header = getMessageHeader({
//     ecn: EXAMPLE_TRANSACTION.ECN,
//     functionCode: EXAMPLE_TRANSACTION.FUNCTION_CODE,
//     responseCode: EXAMPLE_TRANSACTION.RESPONSE_CODE,
//     rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
//   });

//   Logger.info({ componentName: "NetsTerminal" }, "header", header);

//   const data = getMessageData({
//     fieldCode: EXAMPLE_TRANSACTION.FIELD_CODE,
//     data: EXAMPLE_TRANSACTION.DATA,
//   });

//   Logger.info({ componentName: "NetsTerminal" }, "data", data);

//   return getResponseMessage({ header, data: [data] });
// };

export const getNETSPurchaseMessage = (amountMoney: number): string => {
  const ecn = generateECNBaseonDateTime();
  const functionCode = ALL_NETS_PURCHASE_TRANSACTION.FUNCTION_CODE;
  const versionCode = ALL_NETS_PURCHASE_TRANSACTION.VERSION_CODE;

  const header = getMessageHeader({
    ecn,
    functionCode,
    responseCode: versionCode,
    rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
  });

  const transactionTypeIndicator = getMessageData({
    fieldCode:
      ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_TYPE_INDICATOR.FIELD_CODE,
    data: ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_TYPE_INDICATOR.DATA
      .ALL_NETS_PURCHASE,
  });

  // 20.00SDG
  const dataTransactionAmount = String(amountMoney * 100).padStart(12, "0");
  const transactionAmount = getMessageData({
    fieldCode: ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_AMOUNT.FIELD_CODE,
    data: dataTransactionAmount,
  });

  const data = [transactionTypeIndicator, transactionAmount];

  return getResponseMessage({ header, data });
};

export const getNETSPurchaseQRMessage = (amountMoney: number): string => {
  const ecn = generateECNBaseonDateTime();
  const functionCode = ALL_NETS_PURCHASE_TRANSACTION.FUNCTION_CODE;
  const versionCode = ALL_NETS_PURCHASE_TRANSACTION.VERSION_CODE;

  const header = getMessageHeader({
    ecn,
    functionCode,
    responseCode: versionCode,
    rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
  });

  const transactionTypeIndicator = getMessageData({
    fieldCode:
      ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_TYPE_INDICATOR.FIELD_CODE,
    data: ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_TYPE_INDICATOR.DATA
      .NETS_QR_PURCHASE,
  });

  // 20.00SDG
  const dataTransactionAmount = String(amountMoney * 100).padStart(12, "0");
  const transactionAmount = getMessageData({
    fieldCode: ALL_NETS_PURCHASE_TRANSACTION.TRANSACTION_AMOUNT.FIELD_CODE,
    data: dataTransactionAmount,
  });

  const data = [transactionTypeIndicator, transactionAmount];

  return getResponseMessage({ header, data });
};

export const getCreditCardSaleMessage = (amountMoney: number): string => {
  const ecn = generateECNBaseonDateTime();
  const functionCode = CREDIT_CARD_SALE_TRANSACTION.FUNCTION_CODE;
  const versionCode = CREDIT_CARD_SALE_TRANSACTION.VERSION_CODE;

  const header = getMessageHeader({
    ecn,
    functionCode,
    responseCode: versionCode,
    rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
  });

  // 20.00SDG
  const dataTransactionAmount = String(amountMoney * 100).padStart(12, "0");

  const transactionAmount = getMessageData({
    fieldCode: CREDIT_CARD_SALE_TRANSACTION.TRANSACTION_AMOUNT.FIELD_CODE,
    data: dataTransactionAmount,
  });

  getMessageData({
    fieldCode: CREDIT_CARD_SALE_TRANSACTION.TRANSACTION_AMOUNT.FIELD_CODE,
    data: dataTransactionAmount,
  });

  const enhancedECRReferenceNumber = getMessageData({
    fieldCode:
      CREDIT_CARD_SALE_TRANSACTION.ENHANCED_ECR_REFERENCE_NUMBER.FIELD_CODE,
    data: generateECNReferenceNumber("CREDITCARDSALE"),
  });

  const data = [transactionAmount, enhancedECRReferenceNumber];

  return getResponseMessage({ header, data });
};

export const cardSettlementMessage = (): string => {
  const ecn = generateECNBaseonDateTime();
  const functionCode = CARD_SETTLEMENT_TRANSACTION.FUNCTION_CODE;
  const versionCode = CARD_SETTLEMENT_TRANSACTION.VERSION_CODE;

  const header = getMessageHeader({
    ecn,
    functionCode,
    responseCode: versionCode,
    rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
  });

  return getResponseMessage({ header, data: [] });
};

export const getLogonMessage = (): string => {
  const ecn = generateECNBaseonDateTime();
  const functionCode = LOGON_TRANSACTION.FUNCTION_CODE;
  const versionCode = LOGON_TRANSACTION.VERSION_CODE;

  const header = getMessageHeader({
    ecn,
    functionCode,
    responseCode: versionCode,
    rfu: DEFAULT_RESPONSE_TRANSACTION.RFU,
  });

  return getResponseMessage({ header, data: [] });
};

// export const convertHexToByteString = (hexString: string): Buffer => {
//   // Then create a buffer from it
//   const buffer = Buffer.from(hexString, "hex");
//   return buffer;
// };

export const parseTerminalResponse = (
  buffer:
    | string
    | Buffer
    | { data: number[] }
    | ArrayBuffer
    | Uint8Array
    | null,
): ({ label: string; data: string } | null)[] => {
  if (!buffer) return [];

  let hexData = "";

  try {
    if (typeof buffer === "string") {
      hexData = Buffer.from(buffer).toString("hex");
    } else if (Buffer.isBuffer(buffer)) {
      hexData = buffer.toString("hex");
    } else if (buffer instanceof ArrayBuffer) {
      hexData = Buffer.from(new Uint8Array(buffer)).toString("hex");
    } else if (buffer instanceof Uint8Array) {
      hexData = Buffer.from(buffer).toString("hex");
    } else if ("data" in buffer && Array.isArray(buffer.data)) {
      hexData = Buffer.from(buffer.data).toString("hex");
    } else {
      console.warn("Unsupported buffer format:", buffer);
      return [];
    }
    return decodeTerminalResponseHex(hexData);
  } catch (err) {
    console.error("❌ Failed to parse buffer:", err);
    return [];
  }
};

/**
 * Extracts field data from a hex string based on the field code
 * @param fieldCode - The field code to look for
 * @param hexData - The hex string containing the data
 * @returns The extracted field data with label
 */
const extractFieldData = (
  fieldCode: string,
  hexData: string,
): { label: string; data: string } | null => {
  // Use type assertion with a more specific type
  type ResponseDataKey = keyof typeof RESPONSE_MESSAGE_CONFIG.data;
  const fieldConfig =
    RESPONSE_MESSAGE_CONFIG.data[fieldCode as ResponseDataKey];

  // Check if field configuration exists and has a length property
  if (!fieldConfig)
    return {
      label: "Unknown Field",
      data: hexData,
    };

  const fieldLabel = fieldConfig.label || "";
  // Handle the case where length might not exist on some field configs
  if ("length" in fieldConfig) {
    const fieldLength = fieldConfig.length;

    if (fieldLength === null) {
      const extractedData = hexData;
      return {
        label: fieldLabel,
        data: extractedData,
      };
    }
    const extractedData = hexData.slice(0, fieldLength);

    return {
      label: fieldLabel,
      data: extractedData,
    };
  }

  return null;
};

const parseHeaderData = (headerString: string) => {
  const ecnNumber = headerString.slice(0, 12);
  const functionCode = headerString.slice(12, 14);
  const responseCode = headerString.slice(14, 16);
  const rfu = headerString.slice(16, 17);

  return [
    { label: "ECN", data: ecnNumber },
    { label: "Function Code", data: functionCode },
    { label: "Response Code", data: responseCode },
    { label: "RFU", data: rfu },
  ];
};

const parseMessageFields = (
  fieldStrings: string[],
): ({ label: string; data: string } | null)[] => {
  return fieldStrings.map((fieldString) => {
    const fieldCode = fieldString.slice(0, 2);
    const fieldData = fieldString.slice(2);

    return extractFieldData(fieldCode, fieldData);
  });
};

export const decodeTerminalResponseHex = (hexString: string) => {
  // Extract message body (skip length prefix and LRC suffix)
  const messageBody = hexString

  // Process the message body
  const upperCaseMessage = messageBody.toUpperCase();

  // Split by separator and convert to ASCII
  const messageParts = upperCaseMessage
    .split(DEFAULT_RESPONSE_TRANSACTION.SEPARATOR)
    .map((part) => {
      const buffer = Buffer.from(part, "hex");

      const data = buffer.toString("ascii");
      const cleanDecodedText = data.replace(
        // eslint-disable-next-line no-control-regex
        /[\x00\x01\x02\x03\x04\x05\x06\x07\x08\x0B\x0C\x0E-\x1F\x7F]/g,
        "",
      );
      return cleanDecodedText;
    });

  // Parse header and data fields
  const headerString = messageParts[0];
  const headerData = parseHeaderData(headerString);

  const dataFields = messageParts.slice(1);
  const data = parseMessageFields(dataFields);
  // TODO: Format and return the parsed response
  // Filter out null values from data array before concatenating
  const filteredData = data.filter(
    (item): item is { label: string; data: string } => item !== null,
  );

  return headerData.concat(filteredData);
};

export const checkTransactionStatusSuccess = (data: string) => {
  const parsedData = parseTerminalResponse(data);
  const responseCode = parsedData.find(
    (item) => item?.label === "Response Code",
  )?.data;

  if (responseCode === "00") {
    return true;
  }
  return false;
};
