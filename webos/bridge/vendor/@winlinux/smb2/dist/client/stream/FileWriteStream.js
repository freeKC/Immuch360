import { Writable } from "stream";
export class FileWriteStream extends Writable {
    maxWriteChunkLength;
    fileWriter;
    _bytesWritten;
    get bytesWritten() {
        return this._bytesWritten;
    }
    constructor(maxWriteChunkLength, fileWriter) {
        super();
        this.maxWriteChunkLength = maxWriteChunkLength;
        this.fileWriter = fileWriter;
        this._bytesWritten = 0;
    }
    _write(chunk, encoding, callback) {
        const chunkSize = chunk.length;
        if (chunkSize > this.maxWriteChunkLength) {
            const promises = [];
            for (let offset = 0; offset < chunkSize; offset += this.maxWriteChunkLength) {
                promises.push(this.fileWriter(this._bytesWritten + offset, chunk.subarray(offset, offset + this.maxWriteChunkLength)));
            }
            Promise.all(promises)
                .then(() => {
                this._bytesWritten += chunkSize;
                callback();
            })
                .catch(callback);
        }
        else {
            this.fileWriter(this._bytesWritten, chunk)
                .then(() => {
                this._bytesWritten += chunkSize;
                callback();
            })
                .catch(callback);
        }
    }
}
//# sourceMappingURL=FileWriteStream.js.map