// The engine of the page: Spark 2.4.0 on three.js 0.180 (licenses/splat-viewer). Seven calls only (load, setPose,
// setCamera, sampleCenters, stats, setQuality, dispose), so that another engine (the PlayCanvas engine, the fallback
// of the plan) stays one adapter away.

import * as THREE from 'three';
import { SparkRenderer, SplatMesh, unpackSplat } from './spark.module.min.js';

/** The name of the graphics chip the web view draws with, as WebGL tells it */
function rendererName(gl) {
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  return String(info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
}

/**
 * Creates the engine on [canvas]: [maxStdDev] (Spark's cut of each gaussian, smaller on phones), [onDirty] when Spark
 * needs another frame (its sort settled).
 */
export function createEngine({ canvas, maxStdDev, onDirty }) {
  const renderer = new THREE.WebGLRenderer({
    canvas,
    antialias: false,
    powerPreference: 'high-performance',
    preserveDrawingBuffer: false,
  });
  renderer.setClearColor(0x000000, 1);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(60, 1, 0.01, 2000);
  const spark = new SparkRenderer({ renderer, maxStdDev, onDirty });
  scene.add(spark);
  let mesh = null;
  const look = new THREE.Vector3();
  const gl = renderer.getContext();

  return {
    renderer: rendererName(gl),

    /**
     * Decodes [bytes], a splat of [type] ('spz' or 'ply'); resolves with the number of gaussians once Spark is ready
     */
    async load(bytes, type, name) {
      mesh = new SplatMesh({ fileBytes: bytes, fileType: type, fileName: name });
      await mesh.initialized;
      scene.add(mesh);
      return mesh.packedSplats?.numSplats ?? mesh.numSplats ?? 0;
    },

    /** The mesh at [position], turned by [pitch] radians about x */
    setPose(position, pitch) {
      mesh.position.set(position[0], position[1], position[2]);
      mesh.quaternion.setFromAxisAngle(new THREE.Vector3(1, 0, 0), pitch);
      mesh.updateMatrixWorld(true);
    },

    /** The eye at [eye] looking at [target], with [fov] vertical degrees on a drawing of [aspect] */
    setCamera(eye, target, fov, aspect) {
      camera.position.set(eye[0], eye[1], eye[2]);
      look.set(target[0], target[1], target[2]);
      camera.up.set(0, 1, 0);
      camera.lookAt(look);
      if (camera.fov !== fov || camera.aspect !== aspect) {
        camera.fov = fov;
        camera.aspect = aspect;
        camera.updateProjectionMatrix();
      }
    },

    /** The positions of the gaussians [stride] apart from the first, [samples] of them, as the file holds them */
    sampleCenters(stride, samples) {
      const packed = mesh.packedSplats;
      const out = new Float32Array(3 * samples);
      const count = packed?.numSplats ?? 0;
      const array = packed?.packedArray;
      if (!array) {
        return new Float32Array(0);
      }
      let written = 0;
      for (let k = 0; k < samples && k * stride < count; k++) {
        const { center } = unpackSplat(array, k * stride, packed.splatEncoding);
        out[3 * k] = center.x;
        out[3 * k + 1] = center.y;
        out[3 * k + 2] = center.z;
        written = k + 1;
      }
      return out.subarray(0, 3 * written);
    },

    /** The drawing buffer at [width] by [height] CSS pixels times [pixelRatio] */
    setQuality(width, height, pixelRatio) {
      renderer.setPixelRatio(pixelRatio);
      renderer.setSize(width, height, false);
    },

    render() {
      renderer.render(scene, camera);
    },

    /**
     * The share of the pixels of the last frame that are not the clear colour, from a grid of about 64 x 64 points
     * read right after drawing
     */
    nonBlank() {
      renderer.render(scene, camera);
      const width = gl.drawingBufferWidth;
      const height = gl.drawingBufferHeight;
      const pixels = new Uint8Array(width * height * 4);
      gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      const stepX = Math.max(1, Math.floor(width / 64));
      const stepY = Math.max(1, Math.floor(height / 64));
      let seen = 0;
      let lit = 0;
      for (let y = 0; y < height; y += stepY) {
        for (let x = 0; x < width; x += stepX) {
          const at = 4 * (y * width + x);
          seen++;
          if (pixels[at] + pixels[at + 1] + pixels[at + 2] > 12) {
            lit++;
          }
        }
      }
      return seen ? lit / seen : 0;
    },

    /** A PNG of what is drawn now (the page check only) */
    capture() {
      renderer.render(scene, camera);
      return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
    },

    stats() {
      return { drawingBuffer: [gl.drawingBufferWidth, gl.drawingBufferHeight] };
    },

    dispose() {
      if (mesh) {
        scene.remove(mesh);
        mesh.dispose?.();
      }
      spark.dispose?.();
      renderer.dispose();
      renderer.forceContextLoss?.();
    },
  };
}
