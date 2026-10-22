// SMB2 IOCTL (MS-SMB2 2.2.31, 2.2.32), used for FSCTL_VALIDATE_NEGOTIATE_INFO
//. The input buffer follows the fixed request part, so InputOffset
// is the header (64) plus the 56 fixed bytes.
const requestStructure = {
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: 57
    },
    reserved: {
        type: Number,
        size: 2
    },
    ctlCode: {
        type: Number,
        signedness: "Unsigned",
        size: 4
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16,
        defaultValue: "ff".repeat(16)
    },
    inputOffset: {
        type: Number,
        size: 4,
        defaultValue: 64 + 56
    },
    inputCount: {
        type: Number,
        size: 4
    },
    maxInputResponse: {
        type: Number,
        size: 4
    },
    outputOffset: {
        type: Number,
        size: 4
    },
    outputCount: {
        type: Number,
        size: 4
    },
    maxOutputResponse: {
        type: Number,
        size: 4
    },
    flags: {
        type: Number,
        size: 4
    },
    reserved2: {
        type: Number,
        size: 4
    },
    buffer: {
        type: Buffer,
        sizeFieldName: "inputCount"
    }
};
// The output lies at OutputOffset from the start of the SMB2 header; read
// it from the raw message, not from `buffer`, which assumes no input echo.
const responseStructure = {
    structureSize: {
        type: Number,
        size: 2
    },
    reserved: {
        type: Number,
        size: 2
    },
    ctlCode: {
        type: Number,
        signedness: "Unsigned",
        size: 4
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16
    },
    inputOffset: {
        type: Number,
        size: 4
    },
    inputCount: {
        type: Number,
        size: 4
    },
    outputOffset: {
        type: Number,
        size: 4
    },
    outputCount: {
        type: Number,
        size: 4
    },
    flags: {
        type: Number,
        size: 4
    },
    reserved2: {
        type: Number,
        size: 4
    },
    buffer: {
        type: Buffer,
        sizeFieldName: "outputCount"
    }
};
export default {
    requestStructure,
    responseStructure
};
//# sourceMappingURL=InputOutputControl.js.map