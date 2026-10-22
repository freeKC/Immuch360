const requestStructure = {
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: 24
    },
    reserved: {
        type: Number,
        size: 2
    },
    reserved2: {
        type: Number,
        size: 4
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16
    }
};
const responseStructure = {
    structureSize: {
        type: Number,
        size: 2
    },
    reserved: {
        type: Number,
        size: 2
    }
};
export default {
    requestStructure,
    responseStructure
};
//# sourceMappingURL=Flush.js.map