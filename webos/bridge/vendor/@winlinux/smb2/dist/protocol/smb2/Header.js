import { protocolIdStructureField } from "../Packet.js";
export const headerSize = 64;
export const headerStructure = {
    protocolId: protocolIdStructureField,
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: headerSize
    },
    creditCharge: {
        type: Number,
        size: 2
    },
    status: {
        type: Number,
        signedness: "Unsigned",
        size: 4
    },
    type: {
        type: Number,
        size: 2,
        defaultValue: 2
    },
    credit: {
        type: Number,
        size: 2,
        defaultValue: 126
    },
    flags: {
        type: Number,
        size: 4
    },
    nextCommand: {
        type: Number,
        size: 4
    },
    messageId: {
        type: Number,
        size: 8
    },
    clientId: {
        type: String,
        encoding: "hex",
        size: 4
    },
    treeId: {
        type: Number,
        size: 4
    },
    sessionId: {
        type: String,
        encoding: "hex",
        size: 8
    },
    signature: {
        type: Buffer,
        size: 16
    }
};
//# sourceMappingURL=Header.js.map