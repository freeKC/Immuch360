// The session of one viewing, as the app wrote it (lib/domain/services/splat_viewer_service.dart): the scene to
// show, the orientation remembered for the file, the device class and its limits, whether the first frames are
// watched, the texts in the app's language and its colours. Read once, from the app's own origin.

/** The session from its JSON, with defaults for what an older app would not give; throws when the scene is missing */
export function parseSession(data) {
  if (!data || typeof data !== 'object' || !data.scene || typeof data.scene.url !== 'string') {
    throw new Error('the session has no scene');
  }
  const scene = data.scene;
  const type = scene.type === 'ply' ? 'ply' : 'spz';
  const limits = data.limits ?? {};
  return {
    scene: {
      url: scene.url,
      type,
      name: String(scene.name ?? `scene.${type}`),
      bytes: Number(scene.bytes) || 0,
      gaussians: Number(scene.gaussians) || 0,
      shown: Number(scene.shown) || 0,
      reduced: scene.reduced === true,
    },
    upright: ['yUp', 'zUp', 'yDown'].includes(data.upright) ? data.upright : null,
    device: data.device === 'phone' ? 'phone' : 'computer',
    limits: {
      pixelRatioMax: Number(limits.pixelRatioMax) > 0 ? Number(limits.pixelRatioMax) : 1,
      maxStdDev: Number(limits.maxStdDev) > 0 ? Number(limits.maxStdDev) : Math.sqrt(8),
    },
    gyroscope: data.gyroscope === true,
    // A computer that shows the splat whole watches its first frames (framewatch.js); null elsewhere
    watch:
      data.watch && typeof data.watch === 'object'
        ? { floor: Number(data.watch.floor) > 0 ? Number(data.watch.floor) : 150000 }
        : null,
    locale: typeof data.locale === 'string' ? data.locale : 'en',
    texts: { ...(data.texts ?? {}) },
    theme: { dark: true, primary: '#4250af', ...(data.theme ?? {}) },
    events: typeof data.events === 'string' ? data.events : 'events',
    check: data.check === true,
    capture: typeof data.capture === 'string' ? data.capture : null,
  };
}

export async function readSession(url = 'session.json') {
  const response = await fetch(url, { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`session.json: HTTP ${response.status}`);
  }
  return parseSession(await response.json());
}

/** [template] with each {name} replaced by [values].name */
export function fill(template, values) {
  return String(template ?? '').replace(/\{(\w+)\}/g, (all, name) => (name in values ? String(values[name]) : all));
}
