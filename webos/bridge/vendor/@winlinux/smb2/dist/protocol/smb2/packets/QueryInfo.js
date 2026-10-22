const requestStructure = {
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: 41
    },
    infoType: {
        type: Number,
        size: 1
    },
    fileInfoClass: {
        type: Number,
        size: 1
    },
    outputBufferLength: {
        type: Number,
        size: 4,
        defaultValue: 65536
    },
    inputBufferOffset: {
        type: Number,
        size: 2
    },
    reserved: {
        type: Number,
        size: 2
    },
    inputBufferLength: {
        type: Number,
        size: 4
    },
    additionalInformation: {
        type: Number,
        size: 4
    },
    flags: {
        type: Number,
        size: 4
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16
    },
    buffer: {
        type: Buffer,
        sizeFieldName: "inputBufferLength"
    }
};
const responseStructure = {
    structureSize: {
        type: Number,
        size: 2
    },
    outputBufferOffset: {
        type: Number,
        size: 2
    },
    outputBufferLength: {
        type: Number,
        size: 4
    },
    buffer: {
        type: Buffer,
        sizeFieldName: "outputBufferLength"
    }
};
export default {
    requestStructure,
    responseStructure
};
//# sourceMappingURL=QueryInfo.js.map