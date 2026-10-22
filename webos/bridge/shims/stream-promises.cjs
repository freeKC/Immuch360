'use strict';
// stream/promises for Node 12, which has the callback forms only
const stream = require('stream');
const util = require('util');
module.exports = {pipeline: util.promisify(stream.pipeline), finished: util.promisify(stream.finished)};
