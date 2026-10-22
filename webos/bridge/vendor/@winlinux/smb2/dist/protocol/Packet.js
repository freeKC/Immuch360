import * as protocolIds from "./protocolIds.js";
import * as structureUtil from "./structureUtil.js";
export const protocolIdStructureField = {
    type: String,
    encoding: "hex",
    size: 4,
    defaultValue: protocolIds.smb2
};
export default class Packet {
    static parseProtocolId(buffer) {
        return structureUtil.parseValue(buffer, protocolIdStructureField);
    }
    static getChunks(buffer) {
        const chunks = [];
        while (buffer.length > 4) {
            const netBiosType = buffer.readUInt8(0);
            if (netBiosType !== 0x00)
                throw new Error("no_net_bios_message");
            const packetLength = buffer.readUInt32BE(0);
            if (packetLength > buffer.length - 4)
                break;
            buffer = buffer.slice(4);
            chunks.push(buffer.slice(0, packetLength));
            buffer = buffer.slice(packetLength);
        }
        return {
            chunks,
            restChunk: buffer
        };
    }
}
//# sourceMappingURL=Packet.js.map