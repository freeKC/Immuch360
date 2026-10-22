'use strict';
/* global __dirname */
// Entry of the base bundle (service/bridge/base.js, Node 8 and later): the bridge, with SMB loaded on demand from the
// second bundle next to it (service/bridge/smb.js, Node 12 and later).

const path = require('path');
const bridge = require('./index');

function loadSmb() {
	const file = path.join(__dirname, 'smb.js');
	return require(file);
}

module.exports = {
	createBridge: (options) => bridge.createBridge(Object.assign({loadSmb: loadSmb}, options || {}))
};
