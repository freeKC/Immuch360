import * as packets from "./packets/index.js";
import HeaderFlag from "./HeaderFlag.js";
import PacketType from "./PacketType.js";
import * as structureUtil from "../structureUtil.js";
import { headerStructure, headerSize } from "./Header.js";
export default class Packet {
    static getPacketTypeName(packetType) {
        return structureUtil.parseEnumValue(PacketType, packetType);
    }
    static getPacketByPacketType(packetType) {
        const typeName = structureUtil.parseEnumValue(PacketType, packetType);
        return Packet.getPacket(typeName);
    }
    static getPacket(typeName) {
        const packet = packets[typeName];
        if (!packet)
            throw new Error(`packet_not_found: ${typeName}`);
        return packet;
    }
    static getStructure(header) {
        const packet = Packet.getPacketByPacketType(header.type);
        const isResponse = (header.flags & HeaderFlag.Response) === 1;
        const structure = packet[`${isResponse ? "response" : "request"}Structure`];
        return structure;
    }
    static serialize(header, body) {
        return Packet.prefixMessage(Packet.serializeMessage(header, body));
    }
    // The bare SMB2 message (header + body) without the NetBIOS header.
    // Signing covers exactly these bytes (MS-SMB2 3.2.4.1.1).
    static serializeMessage(header, body) {
        const structure = Packet.getStructure(header);
        const headerBuffer = Packet.serializeHeader(header);
        const bodyBuffer = structureUtil.serializeStructure(structure, body);
        return Buffer.concat([headerBuffer, bodyBuffer]);
    }
    static prefixMessage(message) {
        const prefixedBuffer = Buffer.allocUnsafe(message.length + 4);
        prefixedBuffer.writeUInt8(0x00, 0);
        prefixedBuffer.writeUInt8((0xff0000 & message.length) >> 16, 1);
        prefixedBuffer.writeUInt16BE(0xffff & message.length, 2);
        message.copy(prefixedBuffer, 4, 0, message.length);
        return prefixedBuffer;
    }
    static parse(buffer) {
        const { header, bodyBuffer } = Packet.parseHeader(buffer);
        const structure = Packet.getStructure(header);
        const body = structureUtil.parseStructure(bodyBuffer, structure);
        return {
            header,
            body
        };
    }
    static parseHeader(buffer) {
        const header = structureUtil.parseStructure(buffer, headerStructure);
        const bodyBuffer = buffer.slice(headerSize);
        return {
            header,
            bodyBuffer
        };
    }
    static serializeHeader(header) {
        return structureUtil.serializeStructure(headerStructure, header);
    }
}
//# sourceMappingURL=Packet.js.map