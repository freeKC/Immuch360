// Immuch360: the addresses the pages that add a source make from their fields.

/** The WebDAV address of the fields: http or https, host, optional port, path */
export function webdavUrl(host: string, port: string, path: string, tls: boolean): string {
	const cleanHost = host.trim().replace(/^https?:\/\//i, '').replace(/\/+$/, '');
	const cleanPath = path.trim().replace(/^\/+/, '');
	return `${tls ? 'https' : 'http'}://${cleanHost}${port.trim() ? `:${port.trim()}` : ''}/${cleanPath}`;
}
