// The splat viewer of the computers, phones and tablets (plan of 2 November 2026): one page in the app's assets,
// served by the app's media bridge on 127.0.0.1 with the session of one viewing and the splat file. It checks that
// the web view can draw (WebGL 2, WebAssembly SIMD), loads the splat with Spark, places it by the headset's rules
// (placement.js), lets the user walk in a place or turn around an object (controls.js), and tells the app what
// happened (events.js). It draws only while something moves, and about a second after.

import { Quality, median, quantile } from './adapt.js';
import { Navigator, attachEscape, attachInput, startGyroscope } from './controls.js';
import { DrawLoop } from './drawloop.js';
import { createEvents } from './events.js';
import { createPanel } from './panel.js';
import { boundsOf, firstView, nextUpright, openingUpright, sampleOf, verticalFov } from './placement.js';
import { fill, readSession } from './session.js';

/** The page keeps drawing this long after the last change, for Spark's sort to settle */
const SETTLE_MS = 1000;

/** The app is told how the frames go this often while the page draws */
const STATS_MS = 10000;

/** A 30 byte module with one SIMD instruction: WebAssembly SIMD is there when it validates */
const SIMD_PROBE = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0,
  65, 0, 253, 15, 253, 98, 11]);

/** What the web view lacks to draw splats: 'webgl2', 'simd', or null */
export function missingSupport() {
  try {
    if (!WebAssembly.validate(SIMD_PROBE)) {
      return 'simd';
    }
  } catch (error) {
    return 'simd';
  }
  const probe = document.createElement('canvas');
  const gl = probe.getContext('webgl2');
  if (!gl) {
    return 'webgl2';
  }
  gl.getExtension('WEBGL_lose_context')?.loseContext();
  return null;
}

/** The bytes of the scene at [url], [progress] told the share read */
async function fetchScene(url, progress) {
  const response = await fetch(url, { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const total = Number(response.headers.get('Content-Length')) || 0;
  if (!response.body || !total) {
    return new Uint8Array(await response.arrayBuffer());
  }
  const bytes = new Uint8Array(total);
  const reader = response.body.getReader();
  let done = 0;
  for (;;) {
    const { value, done: ended } = await reader.read();
    if (ended) {
      break;
    }
    if (done + value.length > total) {
      throw new Error('the scene is longer than it said');
    }
    bytes.set(value, done);
    done += value.length;
    progress(done / total);
  }
  if (done !== total) {
    throw new Error('the scene ended early');
  }
  return bytes;
}

/** The names of the walking keys on this keyboard (W A S D by position), when the web view tells them */
async function keyNames(texts) {
  const fallback = { keys: texts.keysFallback ?? 'W, A, S, D', updown: texts.upDownFallback ?? 'E, Q' };
  try {
    const map = await navigator.keyboard?.getLayoutMap?.();
    if (!map) {
      return fallback;
    }
    const name = (code, plain) => (map.get(code) ?? plain).toUpperCase();
    return {
      keys: ['KeyW', 'KeyA', 'KeyS', 'KeyD'].map((code) => name(code, code.slice(3))).join(', '),
      updown: `${name('KeyE', 'E')}, ${name('KeyQ', 'Q')}`,
    };
  } catch (error) {
    return fallback;
  }
}

async function main() {
  const canvas = document.getElementById('scene');
  let session;
  try {
    session = await readSession();
  } catch (error) {
    document.body.textContent = String(error?.message ?? error);
    return;
  }
  const t = session.texts;
  const events = createEvents(session.events);
  const touchFirst = session.device === 'phone';
  let closing = false;
  const close = () => {
    if (!closing) {
      closing = true;
      events.post('close');
    }
  };

  let nav = null;
  let input = null;
  let gyro = null;
  let upright = null;
  let view = null;
  let bounds = null;
  let engine = null;
  let lastTouch = touchFirst;
  const requestDraw = () => loop.request();

  const panel = createPanel(document.body, session, {
    back: close,
    reset: () => {
      if (nav) {
        nav.reset(view);
        panel.setMode(nav.mode === 'walk');
        requestDraw();
      }
    },
    upright: () => turnUpright(),
    mode: () => {
      if (nav) {
        nav.setMode(nav.mode === 'walk' ? 'orbit' : 'walk');
        panel.setMode(nav.mode === 'walk');
        panel.say(hint());
        requestDraw();
      }
    },
    gyroscope: () => toggleGyroscope(),
    info: () => panel.toggleSheet(infoLines()),
    help: () => panel.toggleSheet([hint()]),
  });

  // A refusal or a failure ends the viewing: its sheet shows with Back, and Esc closes at once
  let failed = false;
  const fail = (text) => {
    failed = true;
    panel.showError(text);
  };
  // Esc from now on, while the scene loads too (the keys of the scene come once it shows)
  attachEscape(window, { shown: () => input != null, failed: () => failed, hideSheet: () => panel.hideSheet(), close });

  const missing = missingSupport();
  if (missing) {
    events.post('unsupported', { reason: missing });
    fail(missing === 'simd' ? t.needsSimd ?? t.needsWebgl2 : t.needsWebgl2);
    return;
  }

  let names = { keys: 'W, A, S, D', updown: 'E, Q' };
  const hint = () => {
    const orbit = nav?.mode === 'orbit';
    if (lastTouch) {
      return orbit ? t.hintTouchOrbit : t.hintTouch;
    }
    return fill(orbit ? t.hintKeysOrbit : t.hintKeys, names);
  };
  keyNames(t).then((found) => {
    names = found;
  });

  const quality = new Quality(session.limits.pixelRatioMax);
  const frames = [];
  let statsSince = performance.now();
  const size = { width: 1, height: 1 };
  const pixelRatio = () => Math.min(window.devicePixelRatio || 1, session.limits.pixelRatioMax) * quality.scale;
  const resize = () => {
    size.width = Math.max(1, canvas.clientWidth);
    size.height = Math.max(1, canvas.clientHeight);
    engine?.setQuality(size.width, size.height, pixelRatio());
    requestDraw();
  };

  const frame = (now, last) => {
    if (!engine || !nav) {
      return;
    }
    const dt = last == null ? 1 / 60 : Math.min(0.1, (now - last) / 1000);
    const backToBack = last != null && now - last < 250;
    if (input.stepKeys(dt) || input.active || gyro) {
      loop.keep(now);
    }
    const { eye, look } = nav.camera();
    engine.setCamera(eye, look, verticalFov(size.width / size.height), size.width / size.height);
    engine.render();
    if (backToBack) {
      const ms = now - last;
      frames.push(ms);
      const change = quality.frame(ms, now);
      if (change === 'down' || change === 'up') {
        engine.setQuality(size.width, size.height, pixelRatio());
      } else if (change === 'heavy') {
        panel.say(t.heavy, 6);
      }
    } else {
      quality.pause();
    }
    if (now - statsSince > STATS_MS) {
      reportStats(now);
    }
  };
  const loop = new DrawLoop({
    requestFrame: (callback) => requestAnimationFrame(callback),
    clock: () => performance.now(),
    settleMs: SETTLE_MS,
    draw: frame,
  });

  const reportStats = (now) => {
    const total = frames.reduce((sum, ms) => sum + ms, 0);
    if (frames.length >= 10 && total > 0) {
      events.post('stats', {
        fps: Math.round((10000 * frames.length) / total) / 10,
        medianMs: Math.round(median(frames) * 10) / 10,
        p95Ms: Math.round(quantile(frames, 0.95) * 10) / 10,
        over50ms: frames.filter((ms) => ms > 50).length,
        frames: frames.length,
        pixelRatio: Math.round(pixelRatio() * 100) / 100,
        scale: quality.scale,
        drawingBuffer: engine.stats().drawingBuffer,
      });
    }
    frames.length = 0;
    statsSince = now;
  };

  const lastFps = () => {
    if (frames.length < 5) {
      return null;
    }
    const total = frames.reduce((sum, ms) => sum + ms, 0);
    return total > 0 ? Math.round((1000 * frames.length) / total) : null;
  };

  const axisName = (value) => ({ yUp: t.axisYUp, zUp: t.axisZUp, yDown: t.axisYDown })[value] ?? value;
  const number = (value, digits) =>
    new Intl.NumberFormat(session.locale, { maximumFractionDigits: digits }).format(value);
  const infoLines = () => [
    t.countLine,
    session.scene.reduced ? t.reducedLine : null,
    view?.object ? fill(t.kindObject, { size: `${number(view.size, 2)} m` }) : t.kindPlace,
    fill(t.turnedLine, { axis: axisName(upright) }),
    lastFps() != null ? fill(t.fpsLine, { fps: lastFps() }) : null,
    fill(t.gpuLine, { name: engine?.renderer ?? '' }),
  ];

  const place = () => {
    view = firstView(bounds, upright);
    engine.setPose(view.position, view.pitch);
    if (nav) {
      nav.reset(view);
    } else {
      nav = new Navigator(view);
    }
    panel.setMode(nav.mode === 'walk');
  };

  const turnUpright = () => {
    if (!engine) {
      return;
    }
    upright = nextUpright(upright);
    place();
    events.post('upright', { value: upright });
    panel.say(fill(t.turnedLine, { axis: axisName(upright) }), 3);
    requestDraw();
  };

  const toggleGyroscope = () => {
    if (gyro) {
      gyro.stop();
      gyro = null;
      panel.setGyroscope(false);
      events.post('gyroscope', { on: false });
      return;
    }
    const begin = () => {
      if (nav.mode === 'orbit') {
        nav.setMode('walk');
        panel.setMode(true);
      }
      gyro = startGyroscope(nav, requestDraw, () => {
        gyro?.stop();
        gyro = null;
        panel.setGyroscope(false);
        panel.say(t.noGyroscope, 4);
      });
      panel.setGyroscope(true);
      events.post('gyroscope', { on: true });
      requestDraw();
    };
    // iOS asks once; the app's web view grants it without a prompt
    const ask = window.DeviceMotionEvent?.requestPermission;
    if (typeof ask === 'function') {
      ask.call(window.DeviceMotionEvent).then((answer) => {
        if (answer === 'granted') {
          begin();
        } else {
          panel.say(t.noGyroscope, 4);
        }
      }, () => panel.say(t.noGyroscope, 4));
    } else {
      begin();
    }
  };

  canvas.addEventListener('webglcontextlost', (event) => {
    event.preventDefault();
    events.post('error', { message: 'webglcontextlost' });
    fail(t.graphicsLost ?? t.needsWebgl2);
  });

  const started = performance.now();
  panel.showLoading(0);
  let bytes;
  try {
    bytes = await fetchScene(session.scene.url, (share) => panel.showLoading(share));
  } catch (error) {
    events.post('error', { message: `fetch: ${error?.message ?? error}` });
    fail(fill(t.failed, { reason: String(error?.message ?? error) }));
    return;
  }
  let gaussians;
  try {
    engine = createEngineFor(canvas, session, requestDraw);
    resize();
    gaussians = await engine.load(bytes, session.scene.type, session.scene.name);
  } catch (error) {
    events.post('error', { message: `load: ${error?.message ?? error}` });
    fail(fill(t.failed, { reason: String(error?.message ?? error) }));
    return;
  }
  bytes = null;
  const { stride, samples } = sampleOf(gaussians);
  const positions = engine.sampleCenters(stride, samples);
  bounds = boundsOf(positions);
  upright = openingUpright(session.upright, positions, bounds);
  place();
  panel.hideLoading();

  input = attachInput(canvas, nav, {
    changed: requestDraw,
    fov: () => verticalFov(size.width / size.height),
    key: (code) => {
      lastTouch = false;
      switch (code) {
        case 'KeyR':
          nav.reset(view);
          panel.setMode(nav.mode === 'walk');
          requestDraw();
          break;
        case 'KeyU':
          turnUpright();
          break;
        case 'KeyM':
          nav.setMode(nav.mode === 'walk' ? 'orbit' : 'walk');
          panel.setMode(nav.mode === 'walk');
          panel.say(hint());
          requestDraw();
          break;
        case 'KeyH':
          panel.toggleSheet([hint()]);
          break;
        case 'KeyI':
          panel.toggleSheet(infoLines());
          break;
        default:
          break;
      }
    },
    tap: () => {
      lastTouch = true;
      if (!panel.hideSheet()) {
        panel.toggleBar();
      }
    },
    doubleTap: () => {
      nav.reset(view);
      panel.setMode(nav.mode === 'walk');
      requestDraw();
    },
    stick: (state) => panel.stick(state),
    walked: () => {
      panel.setMode(true);
    },
    // The keys were let go with the focus: a computer says how to get them back (Alt+Tab, a click elsewhere)
    focusLost: () => {
      if (!touchFirst && !closing) {
        panel.say(t.focusHint, 4);
      }
    },
  });
  canvas.addEventListener('pointerdown', (event) => {
    lastTouch = event.pointerType === 'touch';
  });
  if (!touchFirst) {
    window.addEventListener('pointermove', (event) => {
      if (event.pointerType === 'mouse') {
        panel.wake();
      }
    });
    panel.wake();
  }
  window.addEventListener('resize', resize);
  new ResizeObserver(resize).observe(canvas);
  canvas.focus({ preventScroll: true });

  // A few frames for the sort to settle, then the app is told the scene shows: the share of lit pixels is read again
  // until some show, for a few seconds at most (a software GPU sorts slowly)
  loop.request();
  let nonBlank = 0;
  for (let attempt = 0; attempt < 12 && nonBlank === 0; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, attempt === 0 ? 400 : 300));
    nonBlank = engine.nonBlank();
  }
  const loadMs = Math.round(performance.now() - started);
  events.post('ready', {
    loadMs,
    gaussians,
    renderer: engine.renderer,
    nonBlank: Math.round(nonBlank * 1000) / 1000,
    pixelRatio: pixelRatio(),
    drawingBuffer: engine.stats().drawingBuffer,
    placement: {
      object: view.object,
      upright,
      size: view.size,
      bounds,
      position: view.position,
      distance: view.distance,
      samples: positions.length / 3,
      stride,
    },
  });
  panel.say(hint(), 8);
  if (!document.hasFocus() && !touchFirst) {
    setTimeout(() => panel.say(t.focusHint, 4), 8500);
  }
  if (session.check && session.capture) {
    const png = await engine.capture();
    await fetch(session.capture, { method: 'POST', body: png });
  }
}

// The engine module is loaded with the page; kept apart so that a failing import is told as a failure of the page
let createEngineFor = null;
import('./engine-spark.js').then(
  (module) => {
    createEngineFor = (canvas, session, onDirty) =>
      module.createEngine({ canvas, maxStdDev: session.limits.maxStdDev, onDirty });
    main();
  },
  (error) => {
    document.body.textContent = `The splat engine did not load: ${error?.message ?? error}`;
    fetch('events', { method: 'POST', body: JSON.stringify({ type: 'error', message: `engine: ${error}` }) });
  },
);
