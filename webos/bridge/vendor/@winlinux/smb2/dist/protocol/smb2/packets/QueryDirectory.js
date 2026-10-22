import * as util from "../../util.js";
import FileAttribute from "../FileAttribute.js";
import * as structureUtil from "../../structureUtil.js";
const requestStructure = {
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: 33
    },
    fileInformationClass: {
        type: Number,
        size: 1,
        defaultValue: 37 // FileIdBothDirectoryInformation
    },
    flags: {
        type: Number,
        size: 1
    },
    fileIndex: {
        type: Number,
        size: 4
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16
    },
    fileNameOffset: {
        type: Number,
        size: 2,
        defaultValue: 96
    },
    fileNameLength: {
        type: Number,
        size: 2
    },
    outputBufferLength: {
        type: Number,
        size: 4,
        defaultValue: 0x00010000
    },
    buffer: {
        type: Buffer,
        sizeFieldName: "fileNameLength"
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
// FileIdBothDirectoryInformation (MS-FSCC) up to FileName, without
// NextEntryOffset; ShortName is a fixed 24-byte field.
const fixedEntrySize = 100;
const shortNameFieldSize = 24;
const parseDirectoryEntry = (entryBuffer) => {
    if (entryBuffer.length < fixedEntrySize) {
        throw structureUtil.malformed(`directory entry: ${entryBuffer.length} bytes, shorter than the ${fixedEntrySize}-byte fixed part`);
    }
    let offset = 0;
    const index = entryBuffer.readUInt32LE(offset);
    offset += 4;
    const creationTime = structureUtil.parseDate(entryBuffer.slice(offset, offset + 8));
    offset += 8;
    const lastAccessTime = structureUtil.parseDate(entryBuffer.slice(offset, offset + 8));
    offset += 8;
    const lastWriteTime = structureUtil.parseDate(entryBuffer.slice(offset, offset + 8));
    offset += 8;
    const changeTime = structureUtil.parseDate(entryBuffer.slice(offset, offset + 8));
    offset += 8;
    const fileSize = entryBuffer.readBigUInt64LE(offset);
    offset += 8;
    const allocationSize = entryBuffer.readBigUInt64LE(offset);
    offset += 8;
    const fileAttributes = structureUtil.parseEnumValues(FileAttribute, entryBuffer.readUInt32LE(offset));
    offset += 4;
    const filenameLength = entryBuffer.readUInt32LE(offset);
    offset += 4;
    const eaSize = entryBuffer.readUInt32LE(offset);
    offset += 4;
    const shortNameLength = entryBuffer.readUInt8(offset);
    offset += 1;
    if (shortNameLength > shortNameFieldSize) {
        throw structureUtil.malformed(`directory entry: ShortNameLength ${shortNameLength} is larger than the ${shortNameFieldSize}-byte field`);
    }
    offset += 1; // reserved
    let shortFilename;
    if (shortNameLength !== 0) {
        shortFilename = util.toUnixFilePath(entryBuffer
            .slice(offset, offset + shortNameLength)
            .toString("ucs2"));
    }
    offset += 24;
    offset += 2; // reserved
    const fileId = structureUtil.parseString(entryBuffer.slice(offset, offset + 8).reverse(), { type: String, encoding: "hex" });
    offset += 8;
    if (offset + filenameLength > entryBuffer.length) {
        throw structureUtil.malformed(`directory entry: FileNameLength ${filenameLength} runs past the ${entryBuffer.length}-byte entry`);
    }
    const filename = util.toUnixFilePath(entryBuffer
        .slice(offset, offset + filenameLength)
        .toString("ucs2"));
    offset += filenameLength;
    return {
        type: fileAttributes.includes("Directory") ? "Directory" : "File",
        index,
        creationTime,
        lastAccessTime,
        lastWriteTime,
        changeTime,
        fileSize,
        allocationSize,
        eaSize,
        shortFilename,
        fileId,
        filename,
        fileAttributes
    };
};
const parseResponseBuffer = (buffer) => {
    return structureUtil.parseList(buffer, parseDirectoryEntry);
};
export default {
    requestStructure,
    responseStructure,
    parseResponseBuffer
};
//# sourceMappingURL=QueryDirectory.js.map