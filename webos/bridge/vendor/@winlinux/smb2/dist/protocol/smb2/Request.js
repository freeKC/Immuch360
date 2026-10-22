import Packet from "./Packet.js";
import ProtocolRequest from "../Request.js";
export default class Request extends ProtocolRequest {
    typeName;
    data;
    constructor(header, body) {
        super(header, body);
        this.typeName = Packet.getPacketTypeName(this.header.type);
        const packet = Packet.getPacketByPacketType(this.header.type);
        if (Buffer.isBuffer(this.body.buffer) && packet.parseRequestBuffer) {
            this.data = packet.parseRequestBuffer(this.body.buffer);
        }
    }
    static parse(buffer) {
        const { header, body } = Packet.parse(buffer);
        return new Request(header, body);
    }
    serialize() {
        return Packet.serialize(this.header, this.body);
    }
}
//# sourceMappingURL=Request.js.map