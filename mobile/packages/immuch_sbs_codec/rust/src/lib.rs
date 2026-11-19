// The C interface of immuch_sbs_codec, called by lib/src/bindings.dart through dart:ffi: decode, encode, free, two
// small calls for the version and the licence texts, and the frame work of the 3D videos (video.rs), which reads and
// writes the caller's memory only. Every call that can fail returns a Status (codec.rs) and
// writes its reason, NUL terminated, into the caller's buffer; a panic is caught here and never crosses into Dart.
// What Rust allocates for Dart is a boxed slice, freed by isc_free with its length.

mod codec;
mod licenses;
#[cfg(test)]
mod tests;
mod video;
#[cfg(test)]
mod video_tests;

use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use codec::{CodecError, EncodeRequest, Status, Subsampling};

/// Changes with any change of the functions below; the Dart side refuses another one
pub const ABI_VERSION: u32 = 2;

#[unsafe(no_mangle)]
pub extern "C" fn isc_abi_version() -> u32 {
    ABI_VERSION
}

/// The licence texts of what the library is built from, UTF-8, static: never freed
///
/// # Safety
/// `out_length` is null or points to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_licenses(out_length: *mut usize) -> *const u8 {
    let text = licenses::TEXT;
    if !out_length.is_null() {
        // SAFETY: checked non null; the caller hands a writable usize
        unsafe { *out_length = text.len() };
    }
    text.as_ptr()
}

/// Decodes the JPEG of `jpeg_length` bytes at `jpeg` into opaque RGBA rows, without orientation nor colour management
/// (a grey, CMYK or YCCK file comes out as RGB the way libjpeg-turbo turns it).
/// On success the pixels are at `*out_rgba` (`*out_rgba_length` bytes) and the ICC profile at `*out_icc`, or null;
/// both go back through isc_free.
///
/// # Safety
/// `jpeg` points to `jpeg_length` readable bytes; the `out_` pointers point to writable memory; `error` is null or
/// points to `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_decode(
    jpeg: *const u8,
    jpeg_length: usize,
    out_width: *mut u32,
    out_height: *mut u32,
    out_rgba: *mut *mut u8,
    out_rgba_length: *mut usize,
    out_icc: *mut *mut u8,
    out_icc_length: *mut usize,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if jpeg.is_null()
            || out_width.is_null()
            || out_height.is_null()
            || out_rgba.is_null()
            || out_rgba_length.is_null()
            || out_icc.is_null()
            || out_icc_length.is_null()
        {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null; the caller keeps jpeg_length bytes readable for the call
        let bytes = unsafe { std::slice::from_raw_parts(jpeg, jpeg_length) };
        let decoded = codec::decode(bytes)?;
        let (rgba, rgba_length) = into_raw(decoded.rgba);
        let (icc, icc_length) = decoded.icc.map_or((ptr::null_mut(), 0), into_raw);
        // SAFETY: checked non null; the caller hands writable out values. Dimensions are at most 65 535.
        unsafe {
            *out_width = decoded.width as u32;
            *out_height = decoded.height as u32;
            *out_rgba = rgba;
            *out_rgba_length = rgba_length;
            *out_icc = icc;
            *out_icc_length = icc_length;
        }
        Ok(())
    })
}

/// Encodes `width` x `height` RGBA pixels at `rgba` into a JPEG: SOI, the EXIF APP1 payload (`Exif\0\0` and its TIFF
/// structure), the XMP packet in its APP1, the ICC profile in APP2 chunks, then the image. `subsampling` counts as
/// ChromaSubsampling of sbs_codec.dart: 0 4:4:4, 1 4:2:2, 2 4:2:0, 3 4:4:0, 4 4:1:1. A null segment pointer, or a
/// length of 0, writes no such segment. On success the file is at `*out_jpeg` (`*out_jpeg_length` bytes), freed by
/// isc_free.
///
/// # Safety
/// Each non null input pointer points to its length of readable bytes (`rgba`: `width` x `height` x 4); the `out_`
/// pointers point to writable memory; `error` is null or points to `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_encode(
    rgba: *const u8,
    rgba_length: usize,
    width: u32,
    height: u32,
    quality: u32,
    subsampling: u32,
    exif: *const u8,
    exif_length: usize,
    xmp: *const u8,
    xmp_length: usize,
    icc: *const u8,
    icc_length: usize,
    out_jpeg: *mut *mut u8,
    out_jpeg_length: *mut usize,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if rgba.is_null() || out_jpeg.is_null() || out_jpeg_length.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        let subsampling = Subsampling::from_code(subsampling)
            .ok_or_else(|| CodecError::new(Status::InvalidArgument, format!("subsampling {subsampling}")))?;
        let quality = u8::try_from(quality)
            .map_err(|_| CodecError::new(Status::InvalidArgument, format!("quality {quality}, 1 to 100")))?;
        // SAFETY: checked non null; the caller keeps rgba_length bytes readable for the call
        let pixels = unsafe { std::slice::from_raw_parts(rgba, rgba_length) };
        // SAFETY: each pointer with its length, as the caller hands them (optional_slice checks null and 0)
        let (exif, xmp, icc) = unsafe {
            (
                optional_slice(exif, exif_length),
                optional_slice(xmp, xmp_length),
                optional_slice(icc, icc_length),
            )
        };
        let jpeg = codec::encode(&EncodeRequest {
            rgba: pixels,
            width: width as usize,
            height: height as usize,
            quality,
            subsampling,
            exif,
            xmp,
            icc,
        })?;
        let (data, length) = into_raw(jpeg);
        // SAFETY: checked non null; the caller hands writable out values
        unsafe {
            *out_jpeg = data;
            *out_jpeg_length = length;
        }
        Ok(())
    })
}

/// The input of Video Depth Anything for the frame `rgb` (`width` x `height` RGB bytes): `out_width` x `out_height`
/// float32 values per channel, channels first, into `out` (video.rs, vda_input).
///
/// # Safety
/// `rgb` points to `rgb_length` readable bytes, `out` to `out_length` writable floats; `error` is null or points to
/// `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_vda_input(
    rgb: *const u8,
    rgb_length: usize,
    width: u32,
    height: u32,
    out: *mut f32,
    out_length: usize,
    out_width: u32,
    out_height: u32,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if rgb.is_null() || out.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null; the caller keeps both buffers alive and apart for the call
        let (frame, input) = unsafe {
            (
                std::slice::from_raw_parts(rgb, rgb_length),
                std::slice::from_raw_parts_mut(out, out_length),
            )
        };
        video::vda_input(
            frame,
            width as usize,
            height as usize,
            input,
            out_width as usize,
            out_height as usize,
        )
    })
}

/// The 64 bins of the luma histogram of the frame `rgb` at 320 x 180, into `out` (64 doubles; video.rs, luma_hist64).
///
/// # Safety
/// `rgb` points to `rgb_length` readable bytes, `out` to 64 writable doubles; `error` is null or points to
/// `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_luma_hist64(
    rgb: *const u8,
    rgb_length: usize,
    width: u32,
    height: u32,
    out: *mut f64,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if rgb.is_null() || out.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null; the caller hands rgb_length readable bytes and 64 writable doubles
        let (frame, bins) = unsafe {
            (
                std::slice::from_raw_parts(rgb, rgb_length),
                std::slice::from_raw_parts_mut(out, video::HIST_BINS),
            )
        };
        video::luma_hist64(frame, width as usize, height as usize, bins)
    })
}

/// The right eye of relief-v1 written into the right half of `sbs` (2 `width` x `height` RGB bytes, the frame in its
/// left half) from the depth map `depth` (`depth_width` x `depth_height` doubles) normalised between `p2` and `p98`;
/// `holes` (null, or `width` x `height` bytes) gets 1 for each filled pixel, `*out_filled` how many there were. The
/// rows are shared among `threads` threads (1 to 16).
///
/// # Safety
/// Each pointer points to its length of memory (`holes` may be null), `sbs` and `holes` writable, all apart;
/// `out_filled` points to a writable u64; `error` is null or points to `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_relief_v1_eye(
    sbs: *mut u8,
    sbs_length: usize,
    width: u32,
    height: u32,
    depth: *const f64,
    depth_length: usize,
    depth_width: u32,
    depth_height: u32,
    p2: f64,
    p98: f64,
    parallax: f64,
    convergence: f64,
    threads: u32,
    holes: *mut u8,
    holes_length: usize,
    out_filled: *mut u64,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if sbs.is_null() || depth.is_null() || out_filled.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null (holes may be null: no mask then); the caller keeps the buffers alive and apart
        let (frame, map, mask) = unsafe {
            (
                std::slice::from_raw_parts_mut(sbs, sbs_length),
                std::slice::from_raw_parts(depth, depth_length),
                if holes.is_null() || holes_length == 0 {
                    &mut [][..]
                } else {
                    std::slice::from_raw_parts_mut(holes, holes_length)
                },
            )
        };
        let request = video::ReliefRequest {
            depth: map,
            depth_width: depth_width as usize,
            depth_height: depth_height as usize,
            p2,
            p98,
            parallax,
            convergence,
            threads: threads as usize,
        };
        let filled = video::relief_v1_eye(frame, width as usize, height as usize, &request, mask)?;
        // SAFETY: checked non null; the caller hands a writable u64
        unsafe { *out_filled = filled };
        Ok(())
    })
}

/// The band of the soft floating window of an eye `width` wide (video.rs, edge_band)
#[unsafe(no_mangle)]
pub extern "C" fn isc_edge_band(parallax: f64, width: u32, convergence: f64) -> u32 {
    video::edge_band(parallax, width as usize, convergence) as u32
}

/// Fades `band` columns at both edges of each eye of `sbs` (2 `width` x `height` RGB bytes) to black.
///
/// # Safety
/// `sbs` points to `sbs_length` writable bytes; `error` is null or points to `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_edge_fade(
    sbs: *mut u8,
    sbs_length: usize,
    width: u32,
    height: u32,
    band: u32,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if sbs.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null; the caller hands sbs_length writable bytes
        let frame = unsafe { std::slice::from_raw_parts_mut(sbs, sbs_length) };
        video::edge_fade(frame, width as usize, height as usize, band as usize)
    })
}

/// Both eyes of `sbs` (2 `width` x `height` RGB bytes) squeezed to half their width into `out` (`width` x `height`).
///
/// # Safety
/// `sbs` points to `sbs_length` readable bytes and `out` to `out_length` writable ones, apart; `error` is null or
/// points to `error_capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_half_sbs(
    sbs: *const u8,
    sbs_length: usize,
    width: u32,
    height: u32,
    out: *mut u8,
    out_length: usize,
    error: *mut u8,
    error_capacity: usize,
) -> i32 {
    guard(error, error_capacity, || {
        if sbs.is_null() || out.is_null() {
            return Err(CodecError::new(Status::InvalidArgument, "a null pointer"));
        }
        // SAFETY: checked non null; the caller keeps both buffers alive and apart for the call
        let (frame, half) = unsafe {
            (
                std::slice::from_raw_parts(sbs, sbs_length),
                std::slice::from_raw_parts_mut(out, out_length),
            )
        };
        video::half_sbs(frame, width as usize, height as usize, half)
    })
}

/// Frees what isc_decode or isc_encode returned, with the length they gave. Null does nothing.
///
/// # Safety
/// `data` and `length` come from one of those calls, and each is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isc_free(data: *mut u8, length: usize) {
    if data.is_null() {
        return;
    }
    // SAFETY: data and length are those into_raw gave for a boxed slice, freed once
    drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(data, length)) });
}

/// A vector handed to C: its pointer and length, null for an empty one
fn into_raw(bytes: Vec<u8>) -> (*mut u8, usize) {
    if bytes.is_empty() {
        return (ptr::null_mut(), 0);
    }
    let length = bytes.len();
    (Box::into_raw(bytes.into_boxed_slice()).cast::<u8>(), length)
}

/// # Safety
/// `data` is null or points to `length` readable bytes that outlive the call.
unsafe fn optional_slice<'a>(data: *const u8, length: usize) -> Option<&'a [u8]> {
    if data.is_null() || length == 0 {
        return None;
    }
    // SAFETY: as the function's contract says
    Some(unsafe { std::slice::from_raw_parts(data, length) })
}

/// Runs [body], catching a panic: the status of its outcome, and its reason written to [error]
fn guard(error: *mut u8, capacity: usize, body: impl FnOnce() -> Result<(), CodecError>) -> i32 {
    let failure = match panic::catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(())) => return Status::Ok as i32,
        Ok(Err(failure)) => failure,
        Err(payload) => CodecError::new(Status::Panic, panic_message(payload.as_ref())),
    };
    write_message(error, capacity, &failure.message);
    failure.status as i32
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    let text = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("no message");
    format!("the codec stopped: {text}")
}

/// [message] cut to [capacity] less one byte on a character boundary, NUL terminated
fn write_message(error: *mut u8, capacity: usize, message: &str) {
    if error.is_null() || capacity == 0 {
        return;
    }
    let mut length = message.len().min(capacity - 1);
    while !message.is_char_boundary(length) {
        length -= 1;
    }
    // SAFETY: error points to capacity writable bytes (isc_ functions' contract), and length < capacity
    unsafe {
        ptr::copy_nonoverlapping(message.as_ptr(), error, length);
        *error.add(length) = 0;
    }
}
