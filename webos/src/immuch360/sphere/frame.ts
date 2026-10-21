// Immuch360: turns the bytes of a preview into a frame the sphere can upload.
//
// The pixels must be of the app's own origin, or WebGL refuses them (a picture loaded from the server by <img> taints
// the texture). The bytes are fetched once (they also hold the GPano tags), wrapped in a Blob and decoded by an
// Image from its object URL. A frame wider or taller than the cap is drawn into a smaller canvas first.

import {fitTexture} from './SphereRenderer';

export interface DecodedFrame {
	source: HTMLImageElement | HTMLCanvasElement;
	width: number;
	height: number;
	/** The size of the picture before any downscale */
	naturalWidth: number;
	naturalHeight: number;
}

export function decodeFrame(bytes: ArrayBuffer, mimeType: string, maxSide: number): Promise<DecodedFrame> {
	return new Promise((resolve, reject) => {
		const url = URL.createObjectURL(new Blob([bytes], {type: mimeType}));
		const image = new Image();
		image.onload = () => {
			URL.revokeObjectURL(url);
			const naturalWidth = image.naturalWidth;
			const naturalHeight = image.naturalHeight;
			const size = fitTexture(naturalWidth, naturalHeight, maxSide);
			if (size.width === naturalWidth && size.height === naturalHeight) {
				resolve({source: image, width: naturalWidth, height: naturalHeight, naturalWidth, naturalHeight});
				return;
			}
			const canvas = document.createElement('canvas');
			canvas.width = size.width;
			canvas.height = size.height;
			const context = canvas.getContext('2d');
			if (!context) {
				reject(new Error('no 2D canvas'));
				return;
			}
			context.drawImage(image, 0, 0, size.width, size.height);
			resolve({source: canvas, width: size.width, height: size.height, naturalWidth, naturalHeight});
		};
		image.onerror = () => {
			URL.revokeObjectURL(url);
			reject(new Error('the picture could not be decoded'));
		};
		image.src = url;
	});
}

/** The type of a preview from its first bytes: Immich writes JPEG or WebP previews */
export function sniffImageType(bytes: ArrayBuffer): string {
	const head = new Uint8Array(bytes, 0, Math.min(12, bytes.byteLength));
	if (head[0] === 0xff && head[1] === 0xd8) return 'image/jpeg';
	if (head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46 && head[8] === 0x57 && head[9] === 0x45) return 'image/webp';
	if (head[0] === 0x89 && head[1] === 0x50) return 'image/png';
	return 'application/octet-stream';
}
