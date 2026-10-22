import Packet from "./Packet.js";
import HeaderFlag from "./HeaderFlag.js";
import ProtocolResponse from "../Response.js";
export default class Response extends ProtocolResponse {
    typeName;
    data;
    constructor(header, body) {
        super(header, body);
        this.header.flags |= HeaderFlag.Response;
        this.typeName = Packet.getPacketTypeName(this.header.type);
        const packet = Packet.getPacketByPacketType(this.header.type);
        if (Buffer.isBuffer(this.body.buffer) && packet.parseResponseBuffer) {
            this.data = packet.parseResponseBuffer(this.body.buffer);
        }
    }
    static parse(buffer) {
        const { header, body } = Packet.parse(buffer);
        return new Response(header, body);
    }
    serialize() {
        return Packet.serialize(this.header, this.body);
    }
}
//# sourceMappingURL=Response.js.map