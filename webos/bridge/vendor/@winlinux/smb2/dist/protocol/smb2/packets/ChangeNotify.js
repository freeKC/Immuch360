import * as util from "../../util.js";
import FileAction from "../FileAction.js";
import * as structureUtil from "../../structureUtil.js";
export var Flags;
(function (Flags) {
    Flags[Flags["None"] = 0] = "None";
    Flags[Flags["WatchTreeRecursively"] = 1] = "WatchTreeRecursively";
})(Flags || (Flags = {}));
export var CompletionFilter;
(function (CompletionFilter) {
    CompletionFilter[CompletionFilter["FilenameChange"] = 1] = "FilenameChange";
    CompletionFilter[CompletionFilter["DirnameChange"] = 2] = "DirnameChange";
    CompletionFilter[CompletionFilter["AttributesChange"] = 4] = "AttributesChange";
    CompletionFilter[CompletionFilter["SizeChange"] = 8] = "SizeChange";
    CompletionFilter[CompletionFilter["LastWriteChange"] = 16] = "LastWriteChange";
    CompletionFilter[CompletionFilter["LastAccessChange"] = 32] = "LastAccessChange";
    CompletionFilter[CompletionFilter["CreationChange"] = 64] = "CreationChange";
    CompletionFilter[CompletionFilter["EaChange"] = 128] = "EaChange";
    CompletionFilter[CompletionFilter["SecurityChange"] = 256] = "SecurityChange";
    CompletionFilter[CompletionFilter["StreamNameChange"] = 512] = "StreamNameChange";
    CompletionFilter[CompletionFilter["StreamSizeChange"] = 1024] = "StreamSizeChange";
    CompletionFilter[CompletionFilter["StreamWriteChange"] = 2048] = "StreamWriteChange";
})(CompletionFilter || (CompletionFilter = {}));
const requestStructure = {
    structureSize: {
        type: Number,
        size: 2,
        defaultValue: 32
    },
    flags: {
        type: Number,
        size: 2,
        defaultValue: Flags.WatchTreeRecursively
    },
    outputBufferLength: {
        type: Number,
        size: 4,
        defaultValue: 0x00010000
    },
    fileId: {
        type: String,
        encoding: "hex",
        size: 16
    },
    completionFilter: {
        type: Number,
        size: 4,
        defaultValue: CompletionFilter.FilenameChange |
            CompletionFilter.DirnameChange |
            CompletionFilter.AttributesChange |
            CompletionFilter.SizeChange |
            CompletionFilter.LastWriteChange |
            CompletionFilter.LastAccessChange |
            CompletionFilter.CreationChange |
            CompletionFilter.EaChange |
            CompletionFilter.SecurityChange |
            CompletionFilter.StreamNameChange |
            CompletionFilter.StreamSizeChange |
            CompletionFilter.StreamWriteChange
    },
    reserved: {
        type: Number,
        size: 4
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
const parseChangeEntry = (entryBuffer) => {
    // FILE_NOTIFY_INFORMATION after NextEntryOffset: Action, FileNameLength, FileName.
    if (entryBuffer.length < 8) {
        throw structureUtil.malformed(`change entry: ${entryBuffer.length} bytes, shorter than Action and FileNameLength`);
    }
    const action = entryBuffer.readUInt32LE(0);
    const filenameLength = entryBuffer.readUInt32LE(4);
    if (8 + filenameLength > entryBuffer.length) {
        throw structureUtil.malformed(`change entry: FileNameLength ${filenameLength} runs past the ${entryBuffer.length}-byte entry`);
    }
    const filename = util.toUnixFilePath(entryBuffer
        .slice(8, 8 + filenameLength)
        .toString("ucs2"));
    const actionName = structureUtil.parseEnumValue(FileAction, action);
    return {
        action,
        actionName,
        filename
    };
};
const parseResponseBuffer = (buffer) => {
    return structureUtil.parseList(buffer, parseChangeEntry);
};
export default {
    requestStructure,
    responseStructure,
    parseResponseBuffer
};
//# sourceMappingURL=ChangeNotify.js.map