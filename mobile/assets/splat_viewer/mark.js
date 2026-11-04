// The mark of the poster of a saved splat scene (decision D1 of the splat photos, plan of 3 November 2026, behind the
// switch "Mark the photos of saved splat scenes"): the glyph of the viewer's tiles (Material view_in_ar_rounded,
// Apache 2.0) in a translucent dark rounded square at the bottom right, 7 % of the short side. The same path and
// numbers as SplatMark of splat_poster_draw.dart, which a Dart test compares with this file.

export const MARK_PATH =
  'M2.02 6C2.53 6 3 5.53 3 5.02L3 3.98C3 3.47 3.47 3 3.98 3L5.02 3C5.53 3 6 2.53 6 2.02C6 1.45 5.53 0.98 5.02 0.98L3.98 0.98C2.34 0.98 0.98 2.34 0.98 3.98L0.98 5.02C0.98 5.53 1.45 6 2.02 6ZM5.02 21L3.98 21C3.47 21 3 20.53 3 20.02L3 18.98C3 18.47 2.53 18 2.02 18C1.45 18 0.98 18.47 0.98 18.98L0.98 20.02C0.98 21.66 2.34 23.02 3.98 23.02L5.02 23.02C5.53 23.02 6 22.55 6 21.98C6 21.47 5.53 21 5.02 21ZM20.02 0.98L18.98 0.98C18.47 0.98 18 1.45 18 2.02C18 2.53 18.47 3 18.98 3L20.02 3C20.53 3 21 3.47 21 3.98L21 5.02C21 5.53 21.47 6 21.98 6C22.55 6 23.02 5.53 23.02 5.02L23.02 3.98C23.02 2.34 21.66 0.98 20.02 0.98ZM21.98 18C21.47 18 21 18.47 21 18.98L21 20.02C21 20.53 20.53 21 20.02 21L18.98 21C18.47 21 18 21.47 18 21.98C18 22.55 18.47 23.02 18.98 23.02L20.02 23.02C21.66 23.02 23.02 21.66 23.02 20.02L23.02 18.98C23.02 18.47 22.55 18 21.98 18ZM18.98 14.86L18.98 9.14C18.98 8.39 18.61 7.73 18 7.41L12.98 4.5C12.7 4.36 12.33 4.27 12 4.27C11.67 4.27 11.3 4.36 11.02 4.5L6 7.41C5.39 7.73 5.02 8.39 5.02 9.14L5.02 14.86C5.02 15.61 5.39 16.27 6 16.59L11.02 19.5C11.3 19.64 11.67 19.73 12 19.73C12.33 19.73 12.7 19.64 12.98 19.5L18 16.59C18.61 16.27 18.98 15.61 18.98 14.86ZM11.02 17.16L6.98 14.86L6.98 10.22L11.02 12.56L11.02 17.16ZM12 10.83L8.06 8.53L12 6.23L15.94 8.53L12 10.83ZM17.02 14.86L12.98 17.16L12.98 12.56L17.02 10.22L17.02 14.86Z';

export const MARK = { size: 0.07, margin: 0.03, radius: 0.22, backAlpha: 0.45, glyph: 0.72, glyphAlpha: 0.92 };

/** The square of the mark on a poster of [width] by [height]: its left and top, its side and the radius of its corners */
export function markBox(width, height) {
  const short = Math.min(width, height);
  const side = Math.round(short * MARK.size);
  const margin = Math.round(short * MARK.margin);
  return { left: width - margin - side, top: height - margin - side, side, radius: side * MARK.radius };
}

/** The mark drawn on the 2D context [ctx] of a poster of [width] by [height] */
export function drawMark(ctx, width, height) {
  const { left, top, side, radius } = markBox(width, height);
  ctx.save();
  ctx.fillStyle = `rgba(0, 0, 0, ${MARK.backAlpha})`;
  ctx.beginPath();
  ctx.roundRect(left, top, side, side, radius);
  ctx.fill();
  const glyph = side * MARK.glyph;
  ctx.translate(left + (side - glyph) / 2, top + (side - glyph) / 2);
  ctx.scale(glyph / 24, glyph / 24);
  ctx.fillStyle = `rgba(255, 255, 255, ${MARK.glyphAlpha})`;
  ctx.fill(new Path2D(MARK_PATH), 'nonzero');
  ctx.restore();
}
