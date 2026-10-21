// Immuch360: turns the bytes of a preview into a frame the sphere can upload.
//
// The pixels must be of the app's own origin, or WebGL refuses them (a picture loaded from the server by <img> taints
// the texture). The bytes are fetched once (they also hold the GPano tags) and decoded from a Blob: by
// createImageBitmap where the engine has it (Chromium 50 and later, off the main thread, and a bitmap from a Blob is
// always clean), else by an Image from an object URL. A frame wider or taller than the cap is drawn into a smaller
// canvas first. release() frees the decoded picture once it is uploaded.

import {fitTexture} from './SphereRenderer';

export interface DecodedFrame {
	source: HTMLImageElement | HTMLCanvasElement | ImageBitmap;
	width: number;
	height: number;
	/** The size of the picture before any downscale */
	naturalWidth: number;
	naturalHeight: number;
	release: () => void;
}

type Picture = HTMLImageElement | ImageBitmap;

function loadImage(blob: Blob): Promise<HTMLImageElement> {
	return new Promise((resolve, reject) => {
		const url = URL.createObjectURL(blob);
		const image = new Image();
		image.onload = () => {
			URL.revokeObjectURL(url);
			resolve(image);
		};
		image.onerror = () => {
			URL.revokeObjectURL(url);
			reject(new Error('the picture could not be decoded'));
		};
		image.src = url;
	});
}

async function decode(blob: Blob): Promise<{picture: Picture; width: number; height: number}> {
	if (typeof createImageBitmap === 'function') {
		try {
			const bitmap = await createImageBitmap(blob);
			return {picture: bitmap, width: bitmap.width, height: bitmap.height};
		} catch {
			// some engines refuse a format createImageBitmap does not know: the Image below may still read it
		}
	}
	const image = await loadImage(blob);
	return {picture: image, width: image.naturalWidth, height: image.naturalHeight};
}

const close = (picture: Picture) => {
	if ('close' in picture && typeof picture.close === 'function') picture.close();
};

export async function decodeFrame(bytes: ArrayBuffer, mimeType: string, maxSide: number): Promise<DecodedFrame> {
	const {picture, width, height} = await decode(new Blob([bytes], {type: mimeType}));
	const size = fitTexture(width, height, maxSide);
	if (size.width === width && size.height === height) {
		return {source: picture, width, height, naturalWidth: width, naturalHeight: height, release: () => close(picture)};
	}
	const canvas = document.createElement('canvas');
	canvas.width = size.width;
	canvas.height = size.height;
	const context = canvas.getContext('2d');
	if (!context) {
		close(picture);
		throw new Error('no 2D canvas');
	}
	context.drawImage(picture, 0, 0, size.width, size.height);
	close(picture);
	return {
		source: canvas,
		width: size.width,
		height: size.height,
		naturalWidth: width,
		naturalHeight: height,
		release: () => {
			canvas.width = 0;
			canvas.height = 0;
		},
	};
}

/** The type of a preview from its first bytes: Immich writes JPEG or WebP previews */
export function sniffImageType(bytes: ArrayBuffer): string {
	const head = new Uint8Array(bytes, 0, Math.min(12, bytes.byteLength));
	if (head[0] === 0xff && head[1] === 0xd8) return 'image/jpeg';
	if (head[0] === 0x52 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x46 && head[8] === 0x57 && head[9] === 0x45) return 'image/webp';
	if (head[0] === 0x89 && head[1] === 0x50) return 'image/png';
	return 'application/octet-stream';
}
