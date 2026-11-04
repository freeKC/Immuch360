// Moving in a splat on a flat screen (plan section 4): two ways, Walk for a place and Turn around for an object. The
// horizon stays level, the view never tips past 85 degrees up or down, and walking stays in the horizontal plane of
// the gaze. The navigator below is pure (tested in Node, test/splat_viewer_js/controls.test.mjs); attachInput binds
// it to the mouse, the touchpad, the keyboard, the touch screen and the gyroscope of the page.

export const MAX_PITCH = (85 * Math.PI) / 180;

/** Shift, or the stick pushed fully: this many times faster */
export const FAST = 3;

/** Movement eases in and out over about 0.2 s, as on the headset */
export const EASE_SECONDS = 0.07;

/** The arrows and the orbit keys turn this many radians a second */
export const TURN_RATE = Math.PI / 3;

/** Slower rotations of the gyroscope, in rad/s, are sensor noise (the 360 viewer's threshold) */
export const GYRO_NOISE = 0.005;

/** The share of the zone, at most a metre, over which walking slows down to nothing at its edge */
export const EDGE_SHARE = 0.05;

const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const scale = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const length = (a) => Math.hypot(a[0], a[1], a[2]);
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

/** The horizontal direction of the gaze for [yaw] (0 looks along -z, a positive yaw turns left) */
export function forwardOf(yaw) {
  return [-Math.sin(yaw), 0, -Math.cos(yaw)];
}

export function rightOf(yaw) {
  return [Math.cos(yaw), 0, -Math.sin(yaw)];
}

/** The direction of the gaze for [yaw] and [pitch] */
export function gazeOf(yaw, pitch) {
  const c = Math.cos(pitch);
  return [-Math.sin(yaw) * c, Math.sin(pitch), -Math.cos(yaw) * c];
}

/**
 * The rotation a gyroscope measured over [dt] seconds, around the axes of the device in portrait ([rx] towards the
 * right edge, [ry] towards the top, in rad/s), as a change of yaw and pitch for a screen turned by [angle] degrees
 * (screen.orientation.angle: 90 is the top of the phone on the left). The same rule as applyGyroRotation of the 360
 * viewer: turning the phone to the right looks right, tilting its top towards the user looks up.
 */
export function gyroTurn(rx, ry, dt, angle) {
  let aroundRight;
  let aroundUp;
  switch (((angle % 360) + 360) % 360) {
    case 90:
      aroundRight = -ry;
      aroundUp = rx;
      break;
    case 180:
      aroundRight = -rx;
      aroundUp = -ry;
      break;
    case 270:
      aroundRight = ry;
      aroundUp = -rx;
      break;
    default:
      aroundRight = rx;
      aroundUp = ry;
  }
  const turn = (rate) => (Math.abs(rate) < GYRO_NOISE ? 0 : rate * dt);
  return { yaw: turn(aroundUp), pitch: turn(aroundRight) };
}

/** How fast the stick walks for a push of [amount] (0 at the centre, 1 at the rim): faster the further, 3 at the rim */
export function stickSpeed(amount) {
  const a = clamp(amount, 0, 1);
  return a <= 0.8 ? a / 0.8 : 1 + ((a - 0.8) / 0.2) * (FAST - 1);
}

/**
 * The navigator of one splat, from its first view (placement.js firstView): Walk moves the eye ([eye], [yaw],
 * [pitch]); Turn around moves it on a sphere around the object's centre ([center], [distance], [azimuth],
 * [elevation]). Both keep the room to move of the view.
 */
export class Navigator {
  constructor(view) {
    this.reset(view);
  }

  reset(view = this.view) {
    this.view = view;
    this.mode = view.object ? 'orbit' : 'walk';
    this.eye = [...view.eye];
    this.yaw = 0;
    this.pitch = 0;
    this.center = [...view.center];
    this.distance = view.object ? view.distance : 1;
    this.azimuth = 0;
    this.elevation = 0;
    this.velocity = [0, 0, 0];
    if (view.object) {
      this.syncFromOrbit();
    }
  }

  /** The depth the slides and pinches are measured at */
  get depth() {
    return this.mode === 'orbit' ? this.distance : Math.max(1, this.view.size / 4);
  }

  /** Walk or Turn around; the view does not jump: Walk starts where Turn around was, and the other way round */
  setMode(mode) {
    if (mode === this.mode) {
      return;
    }
    if (mode === 'orbit') {
      const offset = sub(this.eye, this.center);
      this.distance = Math.max(this.minDistance, length(offset));
      this.azimuth = Math.atan2(offset[0], offset[2]);
      this.elevation = clamp(Math.asin(clamp(offset[1] / this.distance, -1, 1)), -MAX_PITCH, MAX_PITCH);
      this.mode = 'orbit';
      this.syncFromOrbit();
    } else {
      this.mode = 'walk';
    }
    this.velocity = [0, 0, 0];
  }

  get minDistance() {
    return Math.max(0.05, this.view.size * 0.05);
  }

  get maxDistance() {
    return Math.max(10, this.view.size * 20);
  }

  /** The eye, yaw and pitch of the orbit: the eye on its sphere, looking at the centre */
  syncFromOrbit() {
    const c = Math.cos(this.elevation);
    const offset = [Math.sin(this.azimuth) * c, Math.sin(this.elevation), Math.cos(this.azimuth) * c];
    this.eye = add(this.center, scale(offset, this.distance));
    this.yaw = this.azimuth;
    this.pitch = -this.elevation;
  }

  /** The camera: where the eye is and the point it looks at */
  camera() {
    return { eye: [...this.eye], look: add(this.eye, gazeOf(this.yaw, this.pitch)) };
  }

  /** A drag of the view by [dx] and [dy] radians (the content follows the finger) */
  look(dx, dy) {
    if (this.mode === 'orbit') {
      this.azimuth -= dx;
      this.elevation = clamp(this.elevation + dy, -MAX_PITCH, MAX_PITCH);
      this.syncFromOrbit();
    } else {
      this.yaw += dx;
      this.pitch = clamp(this.pitch + dy, -MAX_PITCH, MAX_PITCH);
    }
  }

  /** A turn of [radians] to the left (arrows, gyroscope): the eye turns in Walk, goes around in Turn around */
  turn(radians) {
    if (this.mode === 'orbit') {
      this.azimuth += radians;
      this.syncFromOrbit();
    } else {
      this.yaw += radians;
    }
  }

  /** A tilt of [radians] up (gyroscope), in Walk */
  tilt(radians) {
    if (this.mode === 'walk') {
      this.pitch = clamp(this.pitch + radians, -MAX_PITCH, MAX_PITCH);
    }
  }

  /** A slide of the view by [right] and [up] metres (the content follows the finger: the eye goes the other way) */
  slide(right, up) {
    const move = add(scale(rightOf(this.yaw), -right), [0, up, 0]);
    if (this.mode === 'orbit') {
      this.center = add(this.center, move);
      this.syncFromOrbit();
    } else {
      this.eye = this.keepIn(add(this.eye, move));
    }
  }

  /** Forward ([metres] > 0) or back: in the gaze's horizontal plane in Walk, closer or farther in Turn around */
  dolly(metres) {
    if (this.mode === 'orbit') {
      this.distance = clamp(this.distance - metres, this.minDistance, this.maxDistance);
      this.syncFromOrbit();
    } else {
      this.eye = this.keepIn(add(this.eye, scale(forwardOf(this.yaw), metres)));
    }
  }

  /** Closer or farther by a factor (a pinch, the wheel in Turn around): [factor] above 1 comes closer */
  zoom(factor) {
    if (!(factor > 0)) {
      return;
    }
    if (this.mode === 'orbit') {
      this.distance = clamp(this.distance / factor, this.minDistance, this.maxDistance);
      this.syncFromOrbit();
    } else {
      this.dolly(Math.log(factor) * this.depth * 2);
    }
  }

  /**
   * One frame of [dt] seconds of the keys or the stick: [input] is {forward, right, up, turn} each from -1 to 1, and
   * [speedFactor] (Shift, the stick pushed). Returns whether the view moved. Any walking input in Turn around switches
   * to Walk first (the keys W, A, S, D and the stick); the arrows keep Turn around (closer, farther, around).
   */
  step(dt, input, speedFactor = 1) {
    const { forward = 0, right = 0, up = 0, turn = 0, orbitZoom = 0 } = input;
    let moved = false;
    if (turn !== 0) {
      this.turn(turn * TURN_RATE * dt);
      moved = true;
    }
    if (this.mode === 'orbit') {
      if (orbitZoom !== 0) {
        this.zoom(Math.exp(orbitZoom * dt));
        moved = true;
      }
      if (up !== 0) {
        this.center = add(this.center, [0, up * this.view.speed * speedFactor * dt, 0]);
        this.syncFromOrbit();
        moved = true;
      }
      return moved;
    }
    const speed = this.view.speed * speedFactor;
    const wanted = add(add(scale(forwardOf(this.yaw), forward * speed), scale(rightOf(this.yaw), right * speed)),
      [0, up * speed, 0]);
    const ease = 1 - Math.exp(-dt / EASE_SECONDS);
    this.velocity = add(this.velocity, scale(sub(wanted, this.velocity), ease));
    if (length(this.velocity) < 1e-4 && length(wanted) === 0) {
      this.velocity = [0, 0, 0];
      return moved;
    }
    this.eye = this.keepIn(add(this.eye, scale(this.edgeSlowed(this.velocity), dt)));
    return true;
  }

  /** [velocity] with what goes out of the room to move slowed near its edge, to nothing at it */
  edgeSlowed(velocity) {
    const { low, high } = this.view.zone;
    return velocity.map((v, axis) => {
      const width = Math.min(1, (high[axis] - low[axis]) * EDGE_SHARE);
      const room = v > 0 ? high[axis] - this.eye[axis] : this.eye[axis] - low[axis];
      return v * clamp(room / width, 0, 1);
    });
  }

  /** [point] held within the room to move */
  keepIn(point) {
    const { low, high } = this.view.zone;
    return point.map((v, axis) => clamp(v, low[axis], high[axis]));
  }
}

/** The keys of a keyboard by position (event.code), whatever its layout: on AZERTY, W A S D are Z Q S D */
export const KEYS = {
  forward: ['KeyW', 'ArrowUp'],
  back: ['KeyS', 'ArrowDown'],
  left: ['KeyA'],
  right: ['KeyD'],
  turnLeft: ['ArrowLeft'],
  turnRight: ['ArrowRight'],
  up: ['KeyE', 'PageUp'],
  down: ['KeyQ', 'PageDown'],
  fast: ['ShiftLeft', 'ShiftRight'],
};

/** The keys that walk: in Turn around they switch to Walk */
export const WALK_KEYS = ['KeyW', 'KeyA', 'KeyS', 'KeyD'];

/** The keys of the browser the page keeps from acting: reload, print, find, the developer tools */
export function isBrowserKey(event) {
  const ctrl = event.ctrlKey || event.metaKey;
  if (event.code === 'F5' || event.code === 'F12' || event.code === 'F3' || event.code === 'F7') {
    return true;
  }
  if (ctrl && ['KeyR', 'KeyP', 'KeyF', 'KeyG', 'KeyS', 'KeyU', 'KeyO', 'KeyN', 'KeyT', 'Minus', 'Equal', 'Digit0']
    .includes(event.code)) {
    return true;
  }
  return ctrl && event.shiftKey && ['KeyI', 'KeyJ', 'KeyC'].includes(event.code);
}

/** The input of the keys held now, for Navigator.step */
export function keyInput(held, mode) {
  const has = (names) => names.some((code) => held.has(code));
  const forwardKey = (has(['KeyW']) ? 1 : 0) - (has(['KeyS']) ? 1 : 0);
  const arrows = (has(['ArrowUp']) ? 1 : 0) - (has(['ArrowDown']) ? 1 : 0);
  return {
    forward: mode === 'orbit' ? forwardKey : forwardKey + arrows,
    orbitZoom: mode === 'orbit' ? arrows : 0,
    right: (has(KEYS.right) ? 1 : 0) - (has(KEYS.left) ? 1 : 0),
    up: (has(KEYS.up) ? 1 : 0) - (has(KEYS.down) ? 1 : 0),
    turn: (has(KEYS.turnLeft) ? 1 : 0) - (has(KEYS.turnRight) ? 1 : 0),
    fast: has(KEYS.fast),
  };
}

const TAP_MS = 250;
const TAP_PX = 10;
const DOUBLE_TAP_MS = 300;
/** The stick, about 2 cm across on any screen (96 CSS pixels to the inch) */
export const STICK_RADIUS_PX = 38;

/** Whether a touch at ([x], [y]) of a [width] by [height] screen starts the stick: the lower left third */
export function inStickArea(x, y, width, height) {
  return x < width / 3 && y > (height * 2) / 3;
}

/**
 * Esc on [target] (the window), from the first moment of the page: it closes the viewer while the scene loads and
 * once a refusal or a failure shows (the review of 2 November 2026: two Esc on the error of a cut SPZ left the window
 * open); once the scene shows, it closes the open sheet first, the viewer at the next press. [hooks]: shown() whether
 * the scene shows, failed() whether an error shows, hideSheet() true when it hid a sheet, close(). Returns the unbind.
 */
export function attachEscape(target, hooks) {
  const onKeyDown = (event) => {
    if (event.code !== 'Escape' && event.key !== 'Escape') {
      return;
    }
    event.preventDefault();
    if (event.repeat) {
      return;
    }
    if (!hooks.shown() || hooks.failed() || !hooks.hideSheet()) {
      hooks.close();
    }
  };
  target.addEventListener('keydown', onKeyDown);
  return () => target.removeEventListener('keydown', onKeyDown);
}

/**
 * Binds the input of the page to [nav]: [canvas] gets the mouse and the touches, the window the keys. [hooks] are
 * told: changed() after each change of the view, key(code) for the keys of the panel (M, R, U, H, I; Esc is
 * attachEscape's, bound from the start of the page),
 * tap() and doubleTap() of a touch, stick(state) to draw the stick, walked() when the input switched to Walk,
 * focusLost(). Returns {stepKeys(dt), held, stop()}.
 */
export function attachInput(canvas, nav, hooks) {
  const held = new Set();
  const pointers = new Map();
  let stick = null;
  let pinch = null;
  let lastTap = 0;
  let tapTimer = null;
  const radPerPixel = () => (((hooks.fov() * Math.PI) / 180) / Math.max(1, canvas.clientHeight));
  const metresPerPixel = () => (2 * Math.tan(((hooks.fov() * Math.PI) / 180) / 2) * nav.depth) /
    Math.max(1, canvas.clientHeight);

  const onKeyDown = (event) => {
    if (isBrowserKey(event)) {
      event.preventDefault();
      return;
    }
    if (['KeyM', 'KeyR', 'KeyU', 'KeyH', 'KeyI'].includes(event.code)) {
      event.preventDefault();
      if (!event.repeat) {
        hooks.key(event.code);
      }
      return;
    }
    const walking = Object.values(KEYS).some((codes) => codes.includes(event.code));
    if (!walking) {
      return;
    }
    event.preventDefault();
    if (WALK_KEYS.includes(event.code) && nav.mode === 'orbit') {
      nav.setMode('walk');
      hooks.walked();
    }
    held.add(event.code);
    hooks.changed();
  };
  const onKeyUp = (event) => {
    held.delete(event.code);
  };
  const onBlur = () => {
    held.clear();
    hooks.focusLost();
  };

  const onWheel = (event) => {
    event.preventDefault();
    // Lines (Firefox) or pages as pixels; a touchpad pinch comes as a wheel with Ctrl held
    const pixels = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaMode === 2 ? event.deltaY * 400 : event.deltaY;
    const factor = Math.exp(-pixels * (event.ctrlKey ? 0.01 : 0.002));
    if (nav.mode === 'orbit') {
      nav.zoom(factor);
    } else {
      nav.dolly(Math.log(factor) * nav.view.speed);
    }
    hooks.changed();
  };

  const touchPoints = () => [...pointers.values()].filter((p) => p !== stick?.pointer);

  const onPointerDown = (event) => {
    canvas.focus({ preventScroll: true });
    canvas.setPointerCapture(event.pointerId);
    const point = { id: event.pointerId, x: event.clientX, y: event.clientY, startX: event.clientX,
      startY: event.clientY, start: performance.now(), button: event.button, type: event.pointerType };
    pointers.set(event.pointerId, point);
    if (event.pointerType === 'touch') {
      if (!stick && pointers.size === 1 && inStickArea(event.clientX, event.clientY, canvas.clientWidth,
        canvas.clientHeight)) {
        stick = { pointer: point, x: 0, y: 0 };
        if (nav.mode === 'orbit') {
          nav.setMode('walk');
          hooks.walked();
        }
        hooks.stick({ cx: point.x, cy: point.y, x: 0, y: 0 });
      }
      const touches = touchPoints();
      if (touches.length === 2) {
        pinch = { distance: spread(touches), mid: middle(touches) };
      }
    }
  };

  const onPointerMove = (event) => {
    const point = pointers.get(event.pointerId);
    if (!point) {
      return;
    }
    const dx = event.clientX - point.x;
    const dy = event.clientY - point.y;
    point.x = event.clientX;
    point.y = event.clientY;
    if (stick && point === stick.pointer) {
      let sx = (point.x - point.startX) / STICK_RADIUS_PX;
      let sy = (point.y - point.startY) / STICK_RADIUS_PX;
      const amount = Math.hypot(sx, sy);
      if (amount > 1) {
        sx /= amount;
        sy /= amount;
      }
      stick.x = sx;
      stick.y = sy;
      hooks.stick({ cx: point.startX, cy: point.startY, x: sx, y: sy });
      hooks.changed();
      return;
    }
    if (point.type === 'touch') {
      const touches = touchPoints();
      if (touches.length >= 2 && pinch) {
        const distance = spread(touches);
        const mid = middle(touches);
        if (pinch.distance > 0 && distance > 0) {
          nav.zoom(distance / pinch.distance);
        }
        const perPixel = metresPerPixel();
        nav.slide((mid[0] - pinch.mid[0]) * perPixel, (mid[1] - pinch.mid[1]) * perPixel);
        pinch = { distance, mid };
        hooks.changed();
        return;
      }
      lookBy(dx, dy);
      return;
    }
    if (event.buttons & 2) {
      const perPixel = metresPerPixel();
      nav.slide(dx * perPixel, dy * perPixel);
      hooks.changed();
    } else if (event.buttons & 1) {
      lookBy(dx, dy);
    }
  };

  const lookBy = (dx, dy) => {
    const k = nav.mode === 'orbit' ? Math.PI / Math.max(1, canvas.clientHeight) : radPerPixel();
    nav.look(dx * k, dy * k);
    hooks.changed();
  };

  const onPointerUp = (event) => {
    const point = pointers.get(event.pointerId);
    pointers.delete(event.pointerId);
    if (!point) {
      return;
    }
    if (stick && point === stick.pointer) {
      stick = null;
      hooks.stick(null);
      hooks.changed();
      return;
    }
    if (touchPoints().length < 2) {
      pinch = null;
    }
    const quick = performance.now() - point.start < TAP_MS;
    const still = Math.hypot(point.x - point.startX, point.y - point.startY) < TAP_PX;
    if (point.type === 'touch' && quick && still && pointers.size === 0) {
      const now = performance.now();
      if (now - lastTap < DOUBLE_TAP_MS) {
        clearTimeout(tapTimer);
        lastTap = 0;
        hooks.doubleTap();
      } else {
        lastTap = now;
        tapTimer = setTimeout(() => hooks.tap(), DOUBLE_TAP_MS);
      }
    }
  };

  const noMenu = (event) => event.preventDefault();
  window.addEventListener('keydown', onKeyDown);
  window.addEventListener('keyup', onKeyUp);
  window.addEventListener('blur', onBlur);
  canvas.addEventListener('wheel', onWheel, { passive: false });
  canvas.addEventListener('pointerdown', onPointerDown);
  canvas.addEventListener('pointermove', onPointerMove);
  canvas.addEventListener('pointerup', onPointerUp);
  canvas.addEventListener('pointercancel', onPointerUp);
  canvas.addEventListener('contextmenu', noMenu);

  return {
    held,
    /** One frame of the keys and the stick; true while they move the view */
    stepKeys(dt) {
      const keys = keyInput(held, nav.mode);
      let input = keys;
      let factor = keys.fast ? FAST : 1;
      if (stick) {
        const amount = Math.hypot(stick.x, stick.y);
        input = { ...keys, forward: keys.forward - stick.y / Math.max(amount, 1e-6) * Math.min(1, amount),
          right: keys.right + stick.x / Math.max(amount, 1e-6) * Math.min(1, amount) };
        factor = Math.max(factor, stickSpeed(amount));
        if (amount < 0.05) {
          input = keys;
        }
      }
      return nav.step(dt, input, factor);
    },
    get active() {
      return held.size > 0 || stick != null;
    },
    stop() {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('blur', onBlur);
      canvas.removeEventListener('wheel', onWheel);
      canvas.removeEventListener('pointerdown', onPointerDown);
      canvas.removeEventListener('pointermove', onPointerMove);
      canvas.removeEventListener('pointerup', onPointerUp);
      canvas.removeEventListener('pointercancel', onPointerUp);
      canvas.removeEventListener('contextmenu', noMenu);
      clearTimeout(tapTimer);
    },
  };
}

function spread(points) {
  return Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y);
}

function middle(points) {
  return [(points[0].x + points[1].x) / 2, (points[0].y + points[1].y) / 2];
}

/**
 * The gyroscope of the page: devicemotion's rotation rates (degrees a second) turned into turns of [nav], with the
 * screen's orientation. Returns {stop()}; [noGyroscope] is called when no rate came within a second.
 */
export function startGyroscope(nav, changed, noGyroscope) {
  let last = null;
  let seen = false;
  const onMotion = (event) => {
    const rate = event.rotationRate;
    if (!rate || rate.beta == null || rate.gamma == null) {
      return;
    }
    seen = true;
    const now = event.timeStamp || performance.now();
    const elapsed = last == null ? 0 : (now - last) / 1000;
    last = now;
    const dt = elapsed > 0 && elapsed <= 0.2 ? elapsed : event.interval > 0 ? event.interval / 1000 : 1 / 50;
    const angle = screen.orientation?.angle ?? window.orientation ?? 0;
    const turn = gyroTurn((rate.beta * Math.PI) / 180, (rate.gamma * Math.PI) / 180, dt, angle);
    if (turn.yaw !== 0 || turn.pitch !== 0) {
      if (nav.mode === 'orbit') {
        nav.setMode('walk');
      }
      nav.turn(turn.yaw);
      nav.tilt(turn.pitch);
      changed();
    }
  };
  window.addEventListener('devicemotion', onMotion);
  const check = setTimeout(() => {
    if (!seen) {
      noGyroscope();
    }
  }, 1000);
  return {
    stop() {
      clearTimeout(check);
      window.removeEventListener('devicemotion', onMotion);
    },
  };
}
