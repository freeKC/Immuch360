'use strict';
// Entry of the SMB bundle (service/bridge/smb.js, Node 12 and later): the driver with the @winlinux packages in it.

const smb2 = require('@winlinux/smb2');
const auth = require('@winlinux/auth');
const driver = require('./driver');

module.exports = {
	createSmbDriver: () => driver.createSmbDriver({connect: smb2.connect, createAuthProvider: auth.createAuthProvider})
};
