// The C interface of immuch_sbs_codec, called by lib/src/bindings.dart through dart:ffi: decode, encode, free, and
// two small calls for the version and the licence texts. Every call that can fail returns a Status (codec.rs) and
// writes its reason, NUL terminated, into the caller's buffer; a panic is caught here and never crosses into Dart.
// What Rust allocates for Dart is a boxed slice, freed by isc_free with its length.

mod codec;
mod licenses;
#[cfg(test)]
mod tests;

use std::panic::{self, AssertUnwindSafe};
use std::ptr;

use codec::{CodecError, EncodeRequest, Status, Subsampling};

/// Changes with any change of the functions below; the Dart side refuses another one
pub const ABI_VERSION: u32 = 1;

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

/// Decodes the JPEG of `jpeg_length` bytes at `jpeg` into RGBA rows, without orientation nor colour conversion.
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
