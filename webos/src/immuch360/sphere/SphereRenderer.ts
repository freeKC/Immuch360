// Immuch360: the 360° sphere in WebGL 1, a port of the equirectangular pass of renderer C
// (mobile/packages/media_kit_video/windows/projection_shaders.h, kFragmentEquirect and kFragmentMain, and
// projection_renderer.cc, SetUniforms). One triangle covers the canvas; each pixel becomes a ray of the view, turned
// into a longitude and a latitude read from the equirectangular frame. Black outside the crop (a partial panorama, or
// the back half of a VR180 media); one eye of a 3D frame. At rest, a Catmull-Rom read in nine bilinear reads, or four
// reads per pixel where the frame is minified (no mipmaps for frames of any size in WebGL 1); while the view moves,
// one bilinear read.
//
// Changes from GLSL ES 3.00 to WebGL 1 (GLSL ES 1.00): texture2D, the size of the texture as a uniform (no
// textureSize), gl_FragColor, the triangle from a vertex buffer (no gl_VertexID), and y up in normalised device
// coordinates (the first row of a WebGL canvas is y = +1), so the ray takes +y where renderer C takes -y.

import type {Rect} from './rules';

const VERTEX = `
attribute vec2 aPosition;
varying vec2 vPosition;
void main() {
  vPosition = aPosition;
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
`;

const FRAGMENT = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

uniform sampler2D uSource;
uniform vec2 uTextureSize;
uniform mat3 uViewToSphere;
uniform vec2 uTanHalfFov;
uniform float uSharp;
uniform vec2 uOutputSize;
uniform float uTexelsPerPixel;
uniform vec4 uEye;
uniform vec4 uCrop;

varying vec2 vPosition;

const float PI = 3.14159265358979;

vec4 catmullRom(vec2 st) {
  vec2 size = uTextureSize;
  vec2 position = st * size;
  vec2 centre1 = floor(position - 0.5) + 0.5;
  vec2 f = position - centre1;
  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
  vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
  vec2 w3 = f * f * (-0.5 + 0.5 * f);
  vec2 w12 = w1 + w2;
  vec2 t0 = (centre1 - 1.0) / size;
  vec2 t3 = (centre1 + 2.0) / size;
  vec2 t12 = (centre1 + w2 / w12) / size;
  vec4 c = texture2D(uSource, vec2(t0.x, t0.y)) * w0.x * w0.y;
  c += texture2D(uSource, vec2(t12.x, t0.y)) * w12.x * w0.y;
  c += texture2D(uSource, vec2(t3.x, t0.y)) * w3.x * w0.y;
  c += texture2D(uSource, vec2(t0.x, t12.y)) * w0.x * w12.y;
  c += texture2D(uSource, vec2(t12.x, t12.y)) * w12.x * w12.y;
  c += texture2D(uSource, vec2(t3.x, t12.y)) * w3.x * w12.y;
  c += texture2D(uSource, vec2(t0.x, t3.y)) * w0.x * w3.y;
  c += texture2D(uSource, vec2(t12.x, t3.y)) * w12.x * w3.y;
  c += texture2D(uSource, vec2(t3.x, t3.y)) * w3.x * w3.y;
  return clamp(c, 0.0, 1.0);
}

vec3 sampleFrame(vec2 frame) {
  if (uSharp > 0.5 && uTexelsPerPixel < 1.25) {
    return catmullRom(frame).rgb;
  }
  return texture2D(uSource, frame).rgb;
}

vec3 sampleSphere(vec3 d) {
  float lon = atan(d.x, d.z);
  float lat = asin(clamp(d.y, -1.0, 1.0));
  vec2 s = vec2(0.5 + lon / (2.0 * PI), 0.5 - lat / PI);
  vec2 local = (s - uCrop.xy) / uCrop.zw;
  if (uCrop.z > 0.999) {
    local.x = fract(local.x);
  }
  if (local.x < 0.0 || local.x > 1.0 || local.y < 0.0 || local.y > 1.0) {
    return vec3(0.0);
  }
  return sampleFrame(uEye.xy + local * uEye.zw);
}

vec3 sampleView(vec2 position) {
  vec3 ray = vec3(position.x * uTanHalfFov.x, position.y * uTanHalfFov.y, 1.0);
  return sampleSphere(normalize(uViewToSphere * ray));
}

void main() {
  vec3 colour;
  if (uSharp > 0.5 && uTexelsPerPixel >= 1.25) {
    vec2 pixel = 2.0 / uOutputSize;
    colour = 0.25 * (sampleView(vPosition + pixel * vec2(-0.125, -0.375)) +
                     sampleView(vPosition + pixel * vec2(0.375, -0.125)) +
                     sampleView(vPosition + pixel * vec2(0.125, 0.375)) +
                     sampleView(vPosition + pixel * vec2(-0.375, 0.125)));
  } else {
    colour = sampleView(vPosition);
  }
  gl_FragColor = vec4(colour, 1.0);
}
`;

/** Where the view looks, in degrees: yaw to the right, pitch up, vertical field of view */
export interface SphereViewState {
	yaw: number;
	pitch: number;
	fov: number;
	/** The view rests: the sharper filter */
	sharp: boolean;
}

/** What the frame holds: where the eye shown lies in it, and the part of the sphere that eye covers */
export interface SphereSetup {
	eye: Rect;
	crop: Rect;
}

type Source = HTMLImageElement | HTMLCanvasElement | HTMLVideoElement | ImageBitmap;

/** The largest frame side the viewer uploads: 4096 like the low memory cap of the Android TV app (32 MB a texture) */
export const TEXTURE_CAP = 4096;

/** The WebGL context of a canvas, version 1, or null when the TV gives none */
export function getWebGL(canvas: HTMLCanvasElement): WebGLRenderingContext | null {
	const options = {alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: false};
	try {
		return (canvas.getContext('webgl', options) ?? canvas.getContext('experimental-webgl', options)) as WebGLRenderingContext | null;
	} catch {
		return null;
	}
}

/**
 * The rows of Ry(yaw) * Rx(pitch), a ray of the view to the sphere, as projection_renderer.cc builds them, laid out
 * by columns for uniformMatrix3fv: the centre of the view looks at longitude yaw and latitude pitch.
 */
export function viewToSphereColumns(yawDegrees: number, pitchDegrees: number): Float32Array {
	const yaw = (yawDegrees * Math.PI) / 180;
	const pitch = (Math.max(-90, Math.min(90, pitchDegrees)) * Math.PI) / 180;
	const cy = Math.cos(yaw);
	const sy = Math.sin(yaw);
	const cp = Math.cos(pitch);
	const sp = Math.sin(pitch);
	const rows = [cy, -sy * sp, sy * cp, 0, cp, sp, -sy, -cy * sp, cy * cp];
	const columns = new Float32Array(9);
	for (let i = 0; i < 9; i++) columns[i] = rows[(i % 3) * 3 + Math.floor(i / 3)]!;
	return columns;
}

/** The size a frame is uploaded at: within the cap and the TV's MAX_TEXTURE_SIZE, the aspect ratio kept */
export function fitTexture(width: number, height: number, maxSide: number): {width: number; height: number} {
	const scale = Math.min(1, maxSide / Math.max(width, height));
	return {width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale))};
}

export class SphereRenderer {
	private readonly gl: WebGLRenderingContext;
	private readonly program: WebGLProgram;
	private readonly texture: WebGLTexture;
	private readonly buffer: WebGLBuffer;
	private readonly uniforms: Record<string, WebGLUniformLocation | null> = {};
	private textureWidth = 0;
	private textureHeight = 0;
	private setup: SphereSetup = {eye: {left: 0, top: 0, width: 1, height: 1}, crop: {left: 0, top: 0, width: 1, height: 1}};

	constructor(private readonly canvas: HTMLCanvasElement, gl?: WebGLRenderingContext | null) {
		const context = gl ?? getWebGL(canvas);
		if (!context) throw new Error('no WebGL');
		this.gl = context;
		this.program = this.link();
		const texture = context.createTexture();
		const buffer = context.createBuffer();
		if (!texture || !buffer) throw new Error('WebGL could not create its objects');
		this.texture = texture;
		this.buffer = buffer;
		context.bindBuffer(context.ARRAY_BUFFER, buffer);
		// One triangle over the whole canvas
		context.bufferData(context.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), context.STATIC_DRAW);
		context.bindTexture(context.TEXTURE_2D, texture);
		context.texParameteri(context.TEXTURE_2D, context.TEXTURE_MIN_FILTER, context.LINEAR);
		context.texParameteri(context.TEXTURE_2D, context.TEXTURE_MAG_FILTER, context.LINEAR);
		context.texParameteri(context.TEXTURE_2D, context.TEXTURE_WRAP_S, context.CLAMP_TO_EDGE);
		context.texParameteri(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.CLAMP_TO_EDGE);
		for (const name of ['uSource', 'uTextureSize', 'uViewToSphere', 'uTanHalfFov', 'uSharp', 'uOutputSize', 'uTexelsPerPixel', 'uEye', 'uCrop']) {
			this.uniforms[name] = context.getUniformLocation(this.program, name);
		}
	}

	private compile(type: number, source: string): WebGLShader {
		const gl = this.gl;
		const shader = gl.createShader(type);
		if (!shader) throw new Error('WebGL could not create a shader');
		gl.shaderSource(shader, source);
		gl.compileShader(shader);
		if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
			const log = gl.getShaderInfoLog(shader);
			gl.deleteShader(shader);
			throw new Error(`shader: ${log}`);
		}
		return shader;
	}

	private link(): WebGLProgram {
		const gl = this.gl;
		const program = gl.createProgram();
		if (!program) throw new Error('WebGL could not create a program');
		const vertex = this.compile(gl.VERTEX_SHADER, VERTEX);
		const fragment = this.compile(gl.FRAGMENT_SHADER, FRAGMENT);
		gl.attachShader(program, vertex);
		gl.attachShader(program, fragment);
		gl.bindAttribLocation(program, 0, 'aPosition');
		gl.linkProgram(program);
		gl.deleteShader(vertex);
		gl.deleteShader(fragment);
		if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(`program: ${gl.getProgramInfoLog(program)}`);
		return program;
	}

	/** MAX_TEXTURE_SIZE of the TV */
	maxTextureSize(): number {
		return this.gl.getParameter(this.gl.MAX_TEXTURE_SIZE) as number;
	}

	/** The frame: an image already within the size of fitTexture, a canvas, or a video element */
	setFrame(source: Source, width: number, height: number): void {
		const gl = this.gl;
		gl.bindTexture(gl.TEXTURE_2D, this.texture);
		gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
		gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, source as TexImageSource);
		this.textureWidth = width;
		this.textureHeight = height;
	}

	setSetup(setup: SphereSetup): void {
		this.setup = setup;
	}

	hasFrame(): boolean {
		return this.textureWidth > 0;
	}

	draw(view: SphereViewState): void {
		const gl = this.gl;
		const canvas = this.canvas;
		const width = canvas.width;
		const height = canvas.height;
		gl.viewport(0, 0, width, height);
		gl.useProgram(this.program);
		gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
		gl.enableVertexAttribArray(0);
		gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
		gl.activeTexture(gl.TEXTURE0);
		gl.bindTexture(gl.TEXTURE_2D, this.texture);
		const u = this.uniforms;
		gl.uniform1i(u.uSource!, 0);
		gl.uniform2f(u.uTextureSize!, this.textureWidth || 1, this.textureHeight || 1);
		gl.uniformMatrix3fv(u.uViewToSphere!, false, viewToSphereColumns(view.yaw, view.pitch));
		const fov = (Math.max(1, Math.min(170, view.fov)) * Math.PI) / 180;
		const tanHalf = Math.tan(fov / 2);
		const aspect = width / Math.max(1, height);
		gl.uniform2f(u.uTanHalfFov!, tanHalf * aspect, tanHalf);
		gl.uniform1f(u.uSharp!, view.sharp ? 1 : 0);
		gl.uniform2f(u.uOutputSize!, width, height);
		const pixelsPerRadian = height / 2 / tanHalf;
		const {eye, crop} = this.setup;
		const texelsPerRadian = (this.textureWidth * eye.width) / (2 * Math.PI * Math.max(0.01, crop.width));
		gl.uniform1f(u.uTexelsPerPixel!, texelsPerRadian / pixelsPerRadian);
		gl.uniform4f(u.uEye!, eye.left, eye.top, eye.width, eye.height);
		gl.uniform4f(u.uCrop!, crop.left, crop.top, crop.width, crop.height);
		gl.drawArrays(gl.TRIANGLES, 0, 3);
	}

	/** The colour of the centre pixel after a draw, to tell a black frame (a video the TV keeps out of WebGL) */
	centrePixel(): [number, number, number] {
		const gl = this.gl;
		const pixel = new Uint8Array(4);
		gl.readPixels(Math.floor(this.canvas.width / 2), Math.floor(this.canvas.height / 2), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
		return [pixel[0]!, pixel[1]!, pixel[2]!];
	}

	dispose(): void {
		const gl = this.gl;
		gl.deleteTexture(this.texture);
		gl.deleteBuffer(this.buffer);
		gl.deleteProgram(this.program);
		this.textureWidth = 0;
	}
}

/** WebGL facts for the diagnostics page */
export function webglInfo(): {webgl1: boolean; webgl2: boolean; maxTextureSize: number | null; renderer: string | null} {
	const info = {webgl1: false, webgl2: false, maxTextureSize: null as number | null, renderer: null as string | null};
	try {
		const canvas = document.createElement('canvas');
		const gl = getWebGL(canvas);
		if (gl) {
			info.webgl1 = true;
			info.maxTextureSize = gl.getParameter(gl.MAX_TEXTURE_SIZE) as number;
			const debug = gl.getExtension('WEBGL_debug_renderer_info');
			info.renderer = debug ? String(gl.getParameter(debug.UNMASKED_RENDERER_WEBGL)) : String(gl.getParameter(gl.RENDERER));
			gl.getExtension('WEBGL_lose_context')?.loseContext();
		}
		const canvas2 = document.createElement('canvas');
		const gl2 = canvas2.getContext('webgl2');
		info.webgl2 = !!gl2;
		(gl2 as WebGLRenderingContext | null)?.getExtension('WEBGL_lose_context')?.loseContext();
	} catch {
		// keep what was found
	}
	return info;
}
