// Save to Immich in the page (plan of 3 November 2026, section 6.1): the view on screen becomes the poster of the
// splat photo. At the next frame the page copies the WebGL canvas into a 2D canvas right after it drew (no
// preserveDrawingBuffer), crops it to 3:2 or 2:3, scales it to 1,600 px at most, draws the mark when the app says so,
// checks that something shows (a black capture, the WebKitGTK and NVIDIA case, asks to move a little and save again),
// and posts it as a JPEG of quality 0.85 to the app. The panel then shows the poster, the name, the size and the
// gaussians, the date in the timeline, the album switch, Cancel and Save; once saved it polls where the save stands
// every second and shows the result for 6 seconds. Closing the viewer does not stop the save: the app tells its end.

import { drawMark } from './mark.js';

/** The long side of a poster, at most */
export const POSTER_LONG = 1600;

/** The JPEG quality of the poster */
export const POSTER_QUALITY = 0.85;

/** How often the page asks where the save stands */
export const POLL_MS = 1000;

/** How long a result stays (FreeKC's rule: lines fade) */
export const RESULT_MS = 6000;

/** The states after which nothing more happens */
export const FINAL_STATES = ['done', 'duplicate', 'alreadyThere', 'inTrash', 'failed', 'cancelled'];

/** The middle of a drawing of [width] by [height] at 3:2 (landscape) or 2:3 (portrait): x, y, w, h */
export function cropRect(width, height) {
  const landscape = width >= height;
  const ratio = landscape ? 3 / 2 : 2 / 3;
  if (width / height > ratio) {
    const w = Math.round(height * ratio);
    return { x: Math.floor((width - w) / 2), y: 0, w, h: height };
  }
  const h = Math.round(width / ratio);
  return { x: 0, y: Math.floor((height - h) / 2), w: width, h };
}

/** The size of the poster of a crop of [w] by [h]: its long side at most POSTER_LONG, never larger than the crop */
export function posterSize(w, h) {
  const scale = Math.min(1, POSTER_LONG / Math.max(w, h));
  return { width: Math.max(1, Math.round(w * scale)), height: Math.max(1, Math.round(h * scale)) };
}

/**
 * Whether the RGBA [pixels] of a capture show nothing: a mean luminance under 3 or a variance under 4 over a grid of
 * about 64 by 64 points (a black drawing buffer, a flat colour)
 */
export function isBlankCapture(pixels, width, height) {
  const stepX = Math.max(1, Math.floor(width / 64));
  const stepY = Math.max(1, Math.floor(height / 64));
  let count = 0;
  let sum = 0;
  let squares = 0;
  for (let y = 0; y < height; y += stepY) {
    for (let x = 0; x < width; x += stepX) {
      const at = 4 * (y * width + x);
      const luminance = 0.2126 * pixels[at] + 0.7152 * pixels[at + 1] + 0.0722 * pixels[at + 2];
      count++;
      sum += luminance;
      squares += luminance * luminance;
    }
  }
  if (count === 0) {
    return true;
  }
  const mean = sum / count;
  const variance = squares / count - mean * mean;
  return mean < 3 || variance < 4;
}

/** Whether [state] ends a save */
export function isFinal(state) {
  return FINAL_STATES.includes(state);
}

/**
 * The poster of the WebGL [canvas] as it is now (call right after it drew): a JPEG blob, or null when the capture
 * shows nothing. [mark] draws the mark on it.
 */
export async function capturePoster(canvas, { mark }) {
  const crop = cropRect(canvas.width, canvas.height);
  const size = posterSize(crop.w, crop.h);
  const poster = document.createElement('canvas');
  poster.width = size.width;
  poster.height = size.height;
  const ctx = poster.getContext('2d', { willReadFrequently: true });
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(canvas, crop.x, crop.y, crop.w, crop.h, 0, 0, size.width, size.height);
  const pixels = ctx.getImageData(0, 0, size.width, size.height).data;
  if (isBlankCapture(pixels, size.width, size.height)) {
    return null;
  }
  if (mark) {
    drawMark(ctx, size.width, size.height);
  }
  return new Promise((resolve) => poster.toBlob(resolve, 'image/jpeg', POSTER_QUALITY));
}

/**
 * Save to Immich of the page: [save] the "save" entry of the session, [panel] the page's panel, [capture] asks the
 * draw loop for the poster of the next frame (a promise of a blob or null), [events] the posts to the app
 */
export function createSaver({ save, panel, events, capture, say }) {
  let busy = false;
  let poll = null;
  let posterUrl = null;
  const t = save.texts ?? {};

  const stopPolling = () => {
    clearTimeout(poll);
    poll = null;
  };

  const follow = () => {
    stopPolling();
    const tick = async () => {
      let status = null;
      try {
        const response = await fetch(save.state ?? 'save', { cache: 'no-store' });
        status = response.ok ? await response.json() : null;
      } catch (error) {
        status = null;
      }
      if (status) {
        panel.setSaveLine(status.text ?? '', status.percent);
        if (isFinal(status.state)) {
          busy = false;
          panel.showSaveResult({
            again: status.state === 'duplicate' || status.state === 'alreadyThere',
            againLabel: t.again,
            closeLabel: t.close,
          });
          poll = setTimeout(() => panel.hideSave(), RESULT_MS);
          return;
        }
      }
      poll = setTimeout(tick, POLL_MS);
    };
    poll = setTimeout(tick, 200);
  };

  const start = async () => {
    if (busy) {
      return;
    }
    if (!save.connected) {
      say(t.notConnected, 4);
      return;
    }
    busy = true;
    const blob = await capture();
    if (!blob) {
      busy = false;
      say(t.noCapture, 6);
      return;
    }
    let taken = false;
    try {
      const response = await fetch(save.poster ?? 'poster', { method: 'POST', body: blob });
      taken = response.ok;
    } catch (error) {
      taken = false;
    }
    if (!taken) {
      busy = false;
      say(t.noCapture, 6);
      return;
    }
    if (posterUrl) {
      URL.revokeObjectURL(posterUrl);
    }
    posterUrl = URL.createObjectURL(blob);
    panel.showSave({
      poster: posterUrl,
      title: t.title,
      lines: [save.name, save.details, save.date, save.warning, t.explain],
      albumLabel: t.album,
      album: save.album !== false,
      cancelLabel: t.cancel,
      saveLabel: t.save,
      onSave: (album) => {
        events.post('save', { album });
        follow();
      },
      onAgain: (album) => {
        busy = true;
        events.post('saveAgain', { album });
        follow();
      },
      onCancel: () => {
        stopPolling();
        busy = false;
        events.post('cancelSave');
        panel.hideSave();
      },
    });
  };

  return { start, stop: stopPolling };
}
