// The frame work of the 3D videos of the computers (store/m2/release-49/lots/video3d-plan.md, sections 2.2 and 4.6),
// as .github/desktop/ai/make_relief_video_golden.py describes it step by step: the input of Video Depth Anything
// (cubic, ImageNet, channels first), the histogram of the cut detector, the right eye of relief-v1 with percentiles
// given from outside, the soft floating window, and half side by side. Every step keeps the order of the operations
// of the script and its double precision, so that the golden fixture holds exactly; the rows of the right eye are
// shared among a few threads, each row alone, which changes no value. The loops index several slices at once, as the
// script does, hence the lint left out.
#![allow(clippy::needless_range_loop)]

use std::panic;
use std::thread;

use crate::codec::{CodecError, Status};

pub const IMAGENET_MEAN: [f64; 3] = [0.485, 0.456, 0.406];
pub const IMAGENET_STD: [f64; 3] = [0.229, 0.224, 0.225];
const CUBIC_A: f64 = -0.75;
pub const HIST_WIDTH: usize = 320;
pub const HIST_HEIGHT: usize = 180;
pub const HIST_BINS: usize = 64;
const LINK_THRESHOLD: f64 = 0.04;
const DILATION_RADIUS: usize = 2;
/// The largest side of a frame this file takes (8K and a little more)
pub const MAX_SIDE: usize = 16384;

fn invalid(message: impl Into<String>) -> CodecError {
    CodecError::new(Status::InvalidArgument, message)
}

fn check_size(width: usize, height: usize, what: &str) -> Result<(), CodecError> {
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return Err(invalid(format!("{what} of {width} x {height}")));
    }
    Ok(())
}

fn check_length(length: usize, needed: usize, what: &str) -> Result<(), CodecError> {
    if length < needed {
        return Err(invalid(format!("{what}: {length} values, {needed} needed")));
    }
    Ok(())
}

// --- the input of the model ---------------------------------------------------------------------------------------

fn cubic_weights(f: f64) -> [f64; 4] {
    let a = CUBIC_A;
    let c0 = ((a * (f + 1.0) - 5.0 * a) * (f + 1.0) + 8.0 * a) * (f + 1.0) - 4.0 * a;
    let c1 = ((a + 2.0) * f - (a + 3.0)) * f * f + 1.0;
    let c2 = ((a + 2.0) * (1.0 - f) - (a + 3.0)) * (1.0 - f) * (1.0 - f) + 1.0;
    [c0, c1, c2, 1.0 - c0 - c1 - c2]
}

fn cubic_taps(size_in: usize, size_out: usize) -> Vec<([usize; 4], [f64; 4])> {
    (0..size_out)
        .map(|x| {
            let u = (x as f64 + 0.5) * size_in as f64 / size_out as f64 - 0.5;
            let x0 = u.floor();
            let weights = cubic_weights(u - x0);
            let x0 = x0 as i64;
            let last = size_in as i64 - 1;
            let columns = [0, 1, 2, 3].map(|i| (x0 - 1 + i).clamp(0, last) as usize);
            (columns, weights)
        })
        .collect()
}

/// The frame `rgb` (`width` x `height` RGB bytes) as the input of Video Depth Anything: `out_width` x `out_height`
/// by OpenCV's cubic, over 255, ImageNet mean and std, channels first, into `out` (3 x `out_width` x `out_height`).
pub fn vda_input(
    rgb: &[u8],
    width: usize,
    height: usize,
    out: &mut [f32],
    out_width: usize,
    out_height: usize,
) -> Result<(), CodecError> {
    check_size(width, height, "a frame")?;
    check_size(out_width, out_height, "an input")?;
    check_length(rgb.len(), width * height * 3, "the frame")?;
    check_length(out.len(), out_width * out_height * 3, "the input")?;
    let across = cubic_taps(width, out_width);
    let down = cubic_taps(height, out_height);
    // The rows first, in double precision, each output column of each source row
    let mut rows = vec![0f64; height * out_width * 3];
    for y in 0..height {
        let source = &rgb[y * width * 3..(y + 1) * width * 3];
        let row = &mut rows[y * out_width * 3..(y + 1) * out_width * 3];
        for (x, (columns, weights)) in across.iter().enumerate() {
            for k in 0..3 {
                let mut value = 0.0;
                for i in 0..4 {
                    value += f64::from(source[columns[i] * 3 + k]) * weights[i];
                }
                row[x * 3 + k] = value;
            }
        }
    }
    let plane = out_width * out_height;
    for (y, (sources, weights)) in down.iter().enumerate() {
        for x in 0..out_width {
            for k in 0..3 {
                let mut value = 0.0;
                for i in 0..4 {
                    value += rows[(sources[i] * out_width + x) * 3 + k] * weights[i];
                }
                let byte = (value + 0.5).floor().clamp(0.0, 255.0);
                out[k * plane + y * out_width + x] = ((byte / 255.0 - IMAGENET_MEAN[k]) / IMAGENET_STD[k]) as f32;
            }
        }
    }
    Ok(())
}

// --- the histogram of the cut detector -----------------------------------------------------------------------------

fn area_spans(size_in: usize, size_out: usize) -> Vec<Vec<(usize, f64)>> {
    let scale = size_in as f64 / size_out as f64;
    (0..size_out)
        .map(|x| {
            let start = x as f64 * scale;
            let end = (x + 1) as f64 * scale;
            let mut span = Vec::new();
            let mut i = start.floor() as usize;
            while (i as f64) < end && i < size_in {
                let weight = end.min((i + 1) as f64) - start.max(i as f64);
                if weight > 0.0 {
                    span.push((i, weight));
                }
                i += 1;
            }
            span
        })
        .collect()
}

/// The histogram of 64 bins of the luma of `rgb` taken to 320 x 180 by area, each bin a share of the 57 600 pixels.
pub fn luma_hist64(rgb: &[u8], width: usize, height: usize, out: &mut [f64]) -> Result<(), CodecError> {
    check_size(width, height, "a frame")?;
    check_length(rgb.len(), width * height * 3, "the frame")?;
    check_length(out.len(), HIST_BINS, "the histogram")?;
    let across = area_spans(width, HIST_WIDTH);
    let down = area_spans(height, HIST_HEIGHT);
    let mut rows = vec![0f64; height * HIST_WIDTH * 3];
    for y in 0..height {
        let source = &rgb[y * width * 3..(y + 1) * width * 3];
        for (x, span) in across.iter().enumerate() {
            for k in 0..3 {
                let mut value = 0.0;
                for &(i, weight) in span {
                    value += f64::from(source[i * 3 + k]) * weight;
                }
                rows[(y * HIST_WIDTH + x) * 3 + k] = value;
            }
        }
    }
    let area = (width as f64 / HIST_WIDTH as f64) * (height as f64 / HIST_HEIGHT as f64);
    let mut counts = [0u32; HIST_BINS];
    for span in &down {
        for x in 0..HIST_WIDTH {
            let mut rgb_out = [0u32; 3];
            for (k, channel) in rgb_out.iter_mut().enumerate() {
                let mut value = 0.0;
                for &(i, weight) in span {
                    value += rows[(i * HIST_WIDTH + x) * 3 + k] * weight;
                }
                *channel = (value / area + 0.5).floor().clamp(0.0, 255.0) as u32;
            }
            let luma = (rgb_out[0] * 4899 + rgb_out[1] * 9617 + rgb_out[2] * 1868 + 8192) >> 14;
            counts[(luma >> 2) as usize] += 1;
        }
    }
    let total = (HIST_WIDTH * HIST_HEIGHT) as f64;
    for (bin, count) in out.iter_mut().zip(counts) {
        *bin = f64::from(count) / total;
    }
    Ok(())
}

// --- relief-v1 with external percentiles ---------------------------------------------------------------------------

/// What the right eye of a frame is drawn with
pub struct ReliefRequest<'a> {
    /// The map, larger is nearer: double precision, as the job keeps its aligned maps
    pub depth: &'a [f64],
    pub depth_width: usize,
    pub depth_height: usize,
    pub p2: f64,
    pub p98: f64,
    pub parallax: f64,
    pub convergence: f64,
    pub threads: usize,
}

fn normalised_dilated(request: &ReliefRequest) -> Vec<f64> {
    let (w, h) = (request.depth_width, request.depth_height);
    let spread = request.p98 - request.p2;
    let d: Vec<f64> = request
        .depth
        .iter()
        .map(|&value| {
            if spread <= 0.0 || value.is_nan() {
                0.5
            } else {
                ((value - request.p2) / spread).clamp(0.0, 1.0)
            }
        })
        .collect();
    // The 5 x 5 maximum as a pass along the rows then one along the columns: the values of the square exactly
    let mut across = vec![0f64; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut best = d[y * w + x];
            for xx in x.saturating_sub(DILATION_RADIUS)..=(x + DILATION_RADIUS).min(w - 1) {
                if d[y * w + xx] > best {
                    best = d[y * w + xx];
                }
            }
            across[y * w + x] = best;
        }
    }
    let mut out = vec![0f64; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut best = across[y * w + x];
            for yy in y.saturating_sub(DILATION_RADIUS)..=(y + DILATION_RADIUS).min(h - 1) {
                if across[yy * w + x] > best {
                    best = across[yy * w + x];
                }
            }
            out[y * w + x] = best;
        }
    }
    out
}

fn clamp_index(index: i64, size: usize) -> usize {
    index.clamp(0, size as i64 - 1) as usize
}

fn to_byte(value: f64) -> u8 {
    (value + 0.5).floor().clamp(0.0, 255.0) as u8
}

/// One row of the right eye: `left` the row of the frame (RGB), `d` the depth of each of its pixels; writes `right`
/// and `holes` (1 for a filled pixel) and returns how many were filled
fn right_eye_row(left: &[u8], d: &[f64], parallax: f64, convergence: f64, right: &mut [u8], holes: &mut [u8]) -> u64 {
    let width = d.len();
    let shift = parallax * width as f64;
    let t: Vec<f64> = (0..width).map(|x| x as f64 + shift * (convergence - d[x])).collect();
    let mut depth = vec![f64::NEG_INFINITY; width];
    let mut colour = vec![0f64; width * 3];
    for x in 0..width {
        let (d0, t0) = (d[x], t[x]);
        let alone = (t0 + 0.5).floor();
        if alone >= 0.0 && alone < width as f64 {
            let column = alone as usize;
            if d0 > depth[column] {
                depth[column] = d0;
                for k in 0..3 {
                    colour[column * 3 + k] = f64::from(left[x * 3 + k]);
                }
            }
        }
        if x + 1 >= width {
            continue;
        }
        let d1 = d[x + 1];
        if (d0 - d1).abs() > LINK_THRESHOLD {
            continue;
        }
        let t1 = t[x + 1];
        let first = t0.min(t1).ceil().max(0.0);
        let last = t0.max(t1).floor().min(width as f64 - 1.0);
        if first > last {
            continue;
        }
        for column in first as usize..=last as usize {
            let a = if t1 != t0 {
                (column as f64 - t0) / (t1 - t0)
            } else {
                0.0
            };
            let dd = d0 + (d1 - d0) * a;
            if dd > depth[column] {
                depth[column] = dd;
                for k in 0..3 {
                    let c0 = f64::from(left[x * 3 + k]);
                    let c1 = f64::from(left[(x + 1) * 3 + k]);
                    colour[column * 3 + k] = c0 + (c1 - c0) * a;
                }
            }
        }
    }
    // Filling: each run of holes takes its background neighbour, the left one on a tie, black for a row with nothing
    let mut x = 0;
    while x < width {
        if depth[x] != f64::NEG_INFINITY {
            x += 1;
            continue;
        }
        let start = x;
        while x < width && depth[x] == f64::NEG_INFINITY {
            x += 1;
        }
        let end = x - 1;
        let before = start.checked_sub(1);
        let after = if end + 1 < width { Some(end + 1) } else { None };
        let from = match (before, after) {
            (Some(b), Some(a)) => Some(if depth[b] <= depth[a] { b } else { a }),
            (Some(b), None) => Some(b),
            (None, a) => a,
        };
        for column in start..=end {
            for k in 0..3 {
                colour[column * 3 + k] = from.map_or(0.0, |f| colour[f * 3 + k]);
            }
        }
    }
    let mut filled = 0;
    for x in 0..width {
        if depth[x] != f64::NEG_INFINITY {
            for k in 0..3 {
                right[x * 3 + k] = to_byte(colour[x * 3 + k]);
            }
            holes[x] = 0;
        } else {
            let previous = x.saturating_sub(1);
            let next = (x + 1).min(width - 1);
            for k in 0..3 {
                right[x * 3 + k] = to_byte((colour[previous * 3 + k] + colour[x * 3 + k] + colour[next * 3 + k]) / 3.0);
            }
            holes[x] = 1;
            filled += 1;
        }
    }
    filled
}

/// The right eye of relief-v1 written into the right half of `sbs` (2 `width` x `height` RGB bytes, the frame in its
/// left half), from the depth of the request normalised between its p2 and p98; `holes` (`width` x `height`, may be
/// empty) gets 1 for each filled pixel. Returns how many pixels were filled.
pub fn relief_v1_eye(
    sbs: &mut [u8],
    width: usize,
    height: usize,
    request: &ReliefRequest,
    holes: &mut [u8],
) -> Result<u64, CodecError> {
    check_size(width, height, "an eye")?;
    check_size(request.depth_width, request.depth_height, "a depth map")?;
    check_length(sbs.len(), width * height * 6, "the side by side frame")?;
    check_length(
        request.depth.len(),
        request.depth_width * request.depth_height,
        "the depth map",
    )?;
    if !holes.is_empty() {
        check_length(holes.len(), width * height, "the holes")?;
    }
    if !(request.parallax.is_finite() && (0.0..=1.0).contains(&request.parallax)) {
        return Err(invalid(format!("a parallax of {}", request.parallax)));
    }
    if !(request.convergence.is_finite() && (0.0..=1.0).contains(&request.convergence)) {
        return Err(invalid(format!("a convergence of {}", request.convergence)));
    }
    if !(request.p2.is_finite() && request.p98.is_finite()) {
        return Err(invalid("percentiles that are not numbers"));
    }
    let map = normalised_dilated(request);
    let (w, h) = (request.depth_width, request.depth_height);
    // The bilinear reading of the map at the centre of each pixel of the eye, the columns once for all rows
    let columns: Vec<(usize, usize, f64)> = (0..width)
        .map(|x| {
            let u = (x as f64 + 0.5) * w as f64 / width as f64 - 0.5;
            let x0 = u.floor();
            (clamp_index(x0 as i64, w), clamp_index(x0 as i64 + 1, w), u - x0)
        })
        .collect();
    let threads = request.threads.clamp(1, 16).min(height);
    let rows_per_thread = height.div_ceil(threads);
    let row_bytes = width * 6;
    let mut no_holes = vec![0u8; if holes.is_empty() { width * height } else { 0 }];
    let holes: &mut [u8] = if holes.is_empty() {
        &mut no_holes
    } else {
        &mut holes[..width * height]
    };
    let filled = thread::scope(|scope| {
        let mut work = Vec::new();
        for (chunk, (frame_rows, hole_rows)) in sbs[..row_bytes * height]
            .chunks_mut(row_bytes * rows_per_thread)
            .zip(holes.chunks_mut(width * rows_per_thread))
            .enumerate()
        {
            let map = &map;
            let columns = &columns;
            work.push(scope.spawn(move || {
                let mut d = vec![0f64; width];
                let mut filled = 0;
                for (i, (row, hole_row)) in frame_rows
                    .chunks_mut(row_bytes)
                    .zip(hole_rows.chunks_mut(width))
                    .enumerate()
                {
                    let y = chunk * rows_per_thread + i;
                    let v = (y as f64 + 0.5) * h as f64 / height as f64 - 0.5;
                    let y0 = v.floor();
                    let fy = v - y0;
                    let top = clamp_index(y0 as i64, h) * w;
                    let bottom = clamp_index(y0 as i64 + 1, h) * w;
                    for (x, &(left, right, fx)) in columns.iter().enumerate() {
                        let (a, b) = (map[top + left], map[top + right]);
                        let (e, f) = (map[bottom + left], map[bottom + right]);
                        let upper = a + (b - a) * fx;
                        let lower = e + (f - e) * fx;
                        d[x] = upper + (lower - upper) * fy;
                    }
                    let (left_eye, right_eye) = row.split_at_mut(width * 3);
                    filled += right_eye_row(left_eye, &d, request.parallax, request.convergence, right_eye, hole_row);
                }
                filled
            }));
        }
        work.into_iter()
            .map(|handle| handle.join().unwrap_or_else(|payload| panic::resume_unwind(payload)))
            .sum::<u64>()
    });
    Ok(filled)
}

// --- the floating window and half side by side --------------------------------------------------------------------

/// The band of the soft floating window for an eye `width` wide: ceil(parallax * width * max(c, 1 - c)) + 2, at
/// most width / 2
pub fn edge_band(parallax: f64, width: usize, convergence: f64) -> usize {
    let band = (parallax * width as f64 * convergence.max(1.0 - convergence)).ceil() as usize + 2;
    band.min(width / 2)
}

/// Fades `band` columns at both edges of each eye of `sbs` (2 `width` x `height` RGB bytes) to black, linearly
pub fn edge_fade(sbs: &mut [u8], width: usize, height: usize, band: usize) -> Result<(), CodecError> {
    check_size(width, height, "an eye")?;
    check_length(sbs.len(), width * height * 6, "the side by side frame")?;
    if band > width / 2 {
        return Err(invalid(format!("a band of {band} for an eye of {width}")));
    }
    if band == 0 {
        return Ok(());
    }
    let band64 = band as u64;
    for row in sbs[..width * height * 6].chunks_mut(width * 6) {
        for eye in row.chunks_mut(width * 3) {
            for k in 0..band {
                for column in [k, width - 1 - k] {
                    for channel in &mut eye[column * 3..column * 3 + 3] {
                        *channel = ((u64::from(*channel) * k as u64 * 2 + band64) / (2 * band64)) as u8;
                    }
                }
            }
        }
    }
    Ok(())
}

/// Each pair of columns of `sbs` (2 `width` x `height` RGB bytes) made one into `out` (`width` x `height`): both eyes
/// squeezed to half their width. `width` even.
pub fn half_sbs(sbs: &[u8], width: usize, height: usize, out: &mut [u8]) -> Result<(), CodecError> {
    check_size(width, height, "an eye")?;
    if !width.is_multiple_of(2) {
        return Err(invalid(format!("an eye of odd width {width}")));
    }
    check_length(sbs.len(), width * height * 6, "the side by side frame")?;
    check_length(out.len(), width * height * 3, "the half frame")?;
    for (source, target) in sbs.chunks(width * 6).zip(out.chunks_mut(width * 3)).take(height) {
        for x in 0..width {
            for k in 0..3 {
                let a = u16::from(source[6 * x + k]);
                let b = u16::from(source[6 * x + 3 + k]);
                target[3 * x + k] = ((a + b + 1) >> 1) as u8;
            }
        }
    }
    Ok(())
}
