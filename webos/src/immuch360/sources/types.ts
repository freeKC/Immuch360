// Immuch360: the network sources of the TV app (SMB, WebDAV and DLNA shares, Plex Media Servers, Tapo cameras), read
// through the media bridge of the app's JS service (webos/bridge/src/index.js).

export type SourceKind = 'smb' | 'webdav' | 'dlna' | 'plex' | 'tapo';

/** A source as the app keeps it (localStorage, like the Immich accounts) and hands it to the bridge */
export interface SourceConfig {
	id: string;
	kind: SourceKind;
	name: string;
	// webdav
	url?: string;
	// smb, tapo
	host?: string;
	port?: number;
	share?: string;
	root?: string;
	domain?: string;
	user?: string;
	password?: string;
	// dlna
	location?: string;
	control?: string;
	// plex
	address?: string;
	hash?: string | null;
	token?: string | null;
	machineId?: string;
}

export interface ListedFolder {
	ref: string;
	name: string;
	section?: string;
}

export type FileKind = 'image' | 'video' | 'unsupported';

export interface ListedFile {
	ref: string;
	name: string;
	kind: FileKind;
	mime: string | null;
	size: number | null;
	width?: number | null;
	height?: number | null;
	duration?: number | null;
	/** DLNA and Plex: the picture the server makes of it */
	thumb?: string | null;
	/** Plex: the item, for the HLS transcode */
	ratingKey?: string | null;
	/** Plex: whether the TV plays the file as it is */
	direct?: boolean;
	modified?: number | null;
}

export interface Listing {
	folders: ListedFolder[];
	files: ListedFile[];
}

/** What bridgeStart answers */
export interface BridgeInfo {
	port: number;
	token: string;
	host: string;
	node: string;
	smb: boolean;
}

/** A server found on the network (bridgeCall discover) */
export interface DiscoveredServer {
	kind: 'dlna' | 'plex';
	name: string;
	location?: string;
	control?: string;
	host?: string;
	address?: string;
	port?: number;
	machineId?: string;
	hash?: string | null;
	version?: string | null;
}

/** A server of a Plex account (bridgeCall plexServers) */
export interface PlexAccountServer {
	name: string;
	machineId: string;
	token: string;
	address: string;
	port: number;
	hash: string;
	local: boolean;
	owned: boolean;
}

/** The error of the bridge: its message and a code the page knows ('auth', 'not_found', 'smb_needs_node12'...) */
export class BridgeError extends Error {
	public code: string | null;
	public status: number | null;

	constructor(message: string, code: string | null, status: number | null) {
		super(message);
		this.code = code;
		this.status = status;
	}
}
