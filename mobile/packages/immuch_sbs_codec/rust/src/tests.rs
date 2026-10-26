// cargo test: the codec round trip, the ICC profile copied byte for byte, the quality and the subsampling written as
// asked, the segments in their order, a panic turned into a status, and the C functions as Dart calls them. The
// measure of a 48 Mpx pair is an ignored test, run by hand with a photo (see `measure`).

use std::time::Instant;

use super::codec::{self, EncodeRequest, Status, Subsampling};
use super::*;

/// A smooth picture with some detail, RGBA, opaque
fn picture(width: usize, height: usize) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(width * height * 4);
    for y in 0..height {
        for x in 0..width {
            rgba.push((x * 255 / width.max(1)) as u8);
            rgba.push((y * 255 / height.max(1)) as u8);
            rgba.push(((x + y) * 3 % 256) as u8 / 4 + 96);
            rgba.push(255);
        }
    }
    rgba
}

fn request(rgba: &[u8], width: usize, height: usize) -> EncodeRequest<'_> {
    EncodeRequest {
        rgba,
        width,
        height,
        quality: 95,
        subsampling: Subsampling::S444,
        exif: None,
        xmp: None,
        icc: None,
    }
}

/// An ICC profile header of [length] bytes for colour space [space], the rest filled with a pattern
fn profile(length: usize, space: &[u8; 4]) -> Vec<u8> {
    let mut data: Vec<u8> = (0..length).map(|i| (i * 7 % 251) as u8).collect();
    data[..4].copy_from_slice(&(length as u32).to_be_bytes());
    data[16..20].copy_from_slice(space);
    data[36..40].copy_from_slice(b"acsp");
    data
}

/// The marker segments before the scan: (marker, payload without its length)
fn segments_of(jpeg: &[u8]) -> Vec<(u8, &[u8])> {
    assert_eq!(&jpeg[..2], &[0xff, 0xd8], "SOI first");
    let mut found = Vec::new();
    let mut at = 2;
    while at + 4 <= jpeg.len() {
        assert_eq!(jpeg[at], 0xff, "a marker at {at}");
        let marker = jpeg[at + 1];
        let length = usize::from(jpeg[at + 2]) << 8 | usize::from(jpeg[at + 3]);
        found.push((marker, &jpeg[at + 4..at + 2 + length]));
        if marker == 0xda {
            break;
        }
        at += 2 + length;
    }
    found
}

fn mean_and_max_error(a: &[u8], b: &[u8]) -> (f64, u8) {
    assert_eq!(a.len(), b.len());
    let mut sum = 0u64;
    let mut max = 0u8;
    for (i, (&x, &y)) in a.iter().zip(b).enumerate() {
        if i % 4 == 3 {
            continue;
        }
        let d = x.abs_diff(y);
        sum += u64::from(d);
        max = max.max(d);
    }
    (sum as f64 / (a.len() / 4 * 3) as f64, max)
}

#[test]
fn round_trip_keeps_size_and_pixels() {
    let (width, height) = (96, 64);
    let rgba = picture(width, height);
    let jpeg = codec::encode(&request(&rgba, width, height)).unwrap();
    let decoded = codec::decode(&jpeg).unwrap();
    assert_eq!((decoded.width, decoded.height), (width, height));
    assert_eq!(decoded.rgba.len(), width * height * 4);
    assert!(
        decoded.rgba.as_chunks::<4>().0.iter().all(|pixel| pixel[3] == 255),
        "opaque"
    );
    let (mean, max) = mean_and_max_error(&rgba, &decoded.rgba);
    assert!(mean < 1.5, "mean error {mean}");
    assert!(max < 24, "max error {max}");
    assert!(decoded.icc.is_none(), "no profile written, none read");
}

#[test]
fn odd_sizes_round_trip() {
    for (width, height) in [(1, 1), (17, 9), (33, 3), (8, 31)] {
        for subsampling in [Subsampling::S444, Subsampling::S420, Subsampling::S411] {
            let rgba = picture(width, height);
            let jpeg = codec::encode(&EncodeRequest {
                subsampling,
                ..request(&rgba, width, height)
            })
            .unwrap();
            let decoded = codec::decode(&jpeg).unwrap();
            assert_eq!((decoded.width, decoded.height), (width, height), "{subsampling:?}");
        }
    }
}

#[test]
fn icc_profile_copied_byte_for_byte_over_several_chunks() {
    let (width, height) = (32, 16);
    let rgba = picture(width, height);
    // Two chunks: 65 519 bytes, then the rest
    let icc = profile(70_000, b"RGB ");
    let jpeg = codec::encode(&EncodeRequest {
        icc: Some(&icc),
        ..request(&rgba, width, height)
    })
    .unwrap();
    let chunks: Vec<_> = segments_of(&jpeg)
        .into_iter()
        .filter(|(marker, _)| *marker == 0xe2)
        .collect();
    assert_eq!(chunks.len(), 2);
    assert_eq!(&chunks[0].1[..14], b"ICC_PROFILE\0\x01\x02");
    assert_eq!(&chunks[1].1[..14], b"ICC_PROFILE\0\x02\x02");
    assert_eq!(chunks[0].1.len() - 14, codec::ICC_CHUNK);
    assert_eq!(codec::decode(&jpeg).unwrap().icc.as_deref(), Some(icc.as_slice()));
}

#[test]
fn icc_profile_of_another_encoder_read() {
    let (width, height) = (24, 24);
    let rgba = picture(width, height);
    let icc = profile(3_144, b"RGB ");
    let mut jpeg = Vec::new();
    let mut encoder = jpeg_encoder::Encoder::new(&mut jpeg, 90);
    encoder.add_icc_profile(&icc).unwrap();
    encoder
        .encode(&rgba, width as u16, height as u16, jpeg_encoder::ColorType::Rgba)
        .unwrap();
    assert_eq!(codec::decode(&jpeg).unwrap().icc.as_deref(), Some(icc.as_slice()));
}

#[test]
fn profile_of_another_colour_space_not_given_to_rgb_pixels() {
    let (width, height) = (16, 16);
    let rgba = picture(width, height);
    for space in [b"CMYK", b"GRAY"] {
        let icc = profile(600, space);
        let jpeg = codec::encode(&EncodeRequest {
            icc: Some(&icc),
            ..request(&rgba, width, height)
        })
        .unwrap();
        assert!(
            codec::decode(&jpeg).unwrap().icc.is_none(),
            "{}",
            String::from_utf8_lossy(space)
        );
    }
    assert!(!codec::is_rgb_profile(b"RGB "), "a header is 128 bytes");
}

#[test]
fn segments_in_order_and_no_jfif() {
    let (width, height) = (16, 8);
    let rgba = picture(width, height);
    let exif = b"Exif\0\0MM\0\x2a\0\0\0\x08\0\0\0\0\0\0".to_vec();
    let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><!-- é --></x:xmpmeta>"
        .as_bytes()
        .to_vec();
    let icc = profile(200, b"RGB ");
    let jpeg = codec::encode(&EncodeRequest {
        exif: Some(&exif),
        xmp: Some(&xmp),
        icc: Some(&icc),
        ..request(&rgba, width, height)
    })
    .unwrap();
    let found = segments_of(&jpeg);
    assert_eq!(found[0], (0xe1, exif.as_slice()));
    assert_eq!(found[1].0, 0xe1);
    assert_eq!(&found[1].1[..codec::XMP_SIGNATURE.len()], codec::XMP_SIGNATURE);
    assert_eq!(&found[1].1[codec::XMP_SIGNATURE.len()..], xmp.as_slice());
    assert_eq!(found[2].0, 0xe2);
    assert_eq!(&found[2].1[14..], icc.as_slice());
    assert_eq!(found[3].0, 0xc0, "then the image, from its frame header");
    assert!(found.iter().all(|(marker, _)| *marker != 0xe0), "no JFIF segment");
    assert_eq!(&jpeg[jpeg.len() - 2..], &[0xff, 0xd9], "EOI last");
}

#[test]
fn without_segments_the_image_follows_soi() {
    let rgba = picture(8, 8);
    let jpeg = codec::encode(&request(&rgba, 8, 8)).unwrap();
    assert_eq!(&jpeg[..4], &[0xff, 0xd8, 0xff, 0xc0]);
}

/// Annex K luminance table, in natural order, and the zigzag order the DQT segment uses
const ANNEX_K_LUMA: [u32; 64] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51,
    87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
];
const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
    28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54,
    47, 55, 62, 63,
];

/// The luminance table libjpeg writes for [quality] (jpeg_quality_scaling, baseline), in zigzag order: the tables an
/// estimate of the quality of an original reads back
fn ijg_luma(quality: u32) -> Vec<u8> {
    let scale = if quality < 50 {
        5000 / quality
    } else {
        200 - quality * 2
    };
    ZIGZAG
        .iter()
        .map(|&i| ((ANNEX_K_LUMA[i] * scale + 50) / 100).clamp(1, 255) as u8)
        .collect()
}

#[test]
fn quality_written_as_the_ijg_tables() {
    let rgba = picture(16, 16);
    for quality in [75u8, 85, 90, 92, 95, 97] {
        let jpeg = codec::encode(&EncodeRequest {
            quality,
            ..request(&rgba, 16, 16)
        })
        .unwrap();
        let tables: Vec<_> = segments_of(&jpeg)
            .into_iter()
            .filter(|(marker, _)| *marker == 0xdb)
            .collect();
        let luma = tables.iter().find(|(_, payload)| payload[0] == 0).expect("table 0").1;
        assert_eq!(
            &luma[1..65],
            ijg_luma(u32::from(quality)).as_slice(),
            "quality {quality}"
        );
    }
}

#[test]
fn subsampling_written_in_the_frame_header() {
    let (width, height) = (40, 24);
    let rgba = picture(width, height);
    for (subsampling, luma) in [
        (Subsampling::S444, 0x11),
        (Subsampling::S422, 0x21),
        (Subsampling::S420, 0x22),
        (Subsampling::S440, 0x12),
        (Subsampling::S411, 0x41),
    ] {
        let jpeg = codec::encode(&EncodeRequest {
            subsampling,
            ..request(&rgba, width, height)
        })
        .unwrap();
        let frame = segments_of(&jpeg)
            .into_iter()
            .find(|(marker, _)| *marker == 0xc0)
            .expect("SOF0")
            .1;
        // precision, height, width, 3 components of id, factors, table
        assert_eq!(frame[5], 3);
        assert_eq!(frame[7], luma, "{subsampling:?}");
        assert_eq!((frame[10], frame[13]), (0x11, 0x11), "{subsampling:?}");
        let decoded = codec::decode(&jpeg).unwrap();
        let (mean, _) = mean_and_max_error(&rgba, &decoded.rgba);
        assert!(mean < 3.0, "{subsampling:?}: mean error {mean}");
    }
}

#[test]
fn transparency_laid_on_black() {
    let (width, height) = (16, 16);
    let mut rgba = [200u8, 200, 200, 255].repeat(width * height);
    for pixel in rgba.as_chunks_mut::<4>().0.iter_mut().take(width * height / 2) {
        pixel[3] = 0;
    }
    let jpeg = codec::encode(&request(&rgba, width, height)).unwrap();
    let decoded = codec::decode(&jpeg).unwrap();
    // The top half was transparent: black; the bottom half opaque grey
    assert!(
        decoded.rgba[..width * 4 * 6]
            .iter()
            .enumerate()
            .all(|(i, &v)| i % 4 == 3 || v < 8)
    );
    assert!(decoded.rgba[width * 4 * 10..].iter().all(|&v| v > 190));
    assert_eq!(codec::on_black(&[10, 20, 30, 128]).unwrap(), Some(vec![5, 10, 15]));
    assert_eq!(codec::on_black(&[10, 20, 30, 255]).unwrap(), None);
}

#[test]
fn grey_and_cmyk_originals_come_out_as_rgba() {
    let (width, height) = (16, 16);
    let grey: Vec<u8> = (0..width * height).map(|i| (i % 256) as u8).collect();
    let mut jpeg = Vec::new();
    jpeg_encoder::Encoder::new(&mut jpeg, 95)
        .encode(&grey, width as u16, height as u16, jpeg_encoder::ColorType::Luma)
        .unwrap();
    let decoded = codec::decode(&jpeg).unwrap();
    assert_eq!(decoded.rgba.len(), width * height * 4);
    assert!(
        decoded
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .all(|p| p[0] == p[1] && p[1] == p[2] && p[3] == 255)
    );

    let cmyk = vec![40u8; width * height * 4];
    let mut jpeg = Vec::new();
    let mut encoder = jpeg_encoder::Encoder::new(&mut jpeg, 95);
    encoder.add_icc_profile(&profile(400, b"CMYK")).unwrap();
    encoder
        .encode(&cmyk, width as u16, height as u16, jpeg_encoder::ColorType::Cmyk)
        .unwrap();
    let decoded = codec::decode(&jpeg).unwrap();
    assert_eq!(decoded.rgba.len(), width * height * 4);
    assert!(
        decoded.icc.is_none(),
        "the CMYK profile is not the one of the RGB pixels"
    );
}

#[test]
fn refusals_with_their_status() {
    let rgba = picture(8, 8);
    let fails = |request: EncodeRequest| codec::encode(&request).unwrap_err().status;
    assert_eq!(
        fails(EncodeRequest {
            quality: 0,
            ..request(&rgba, 8, 8)
        }),
        Status::InvalidArgument
    );
    assert_eq!(
        fails(EncodeRequest {
            quality: 101,
            ..request(&rgba, 8, 8)
        }),
        Status::InvalidArgument
    );
    assert_eq!(fails(request(&rgba[4..], 8, 8)), Status::InvalidArgument);
    assert_eq!(fails(request(&rgba, 0, 8)), Status::TooLarge);
    assert_eq!(fails(request(&rgba, 70_000, 8)), Status::TooLarge);
    assert_eq!(
        fails(EncodeRequest {
            exif: Some(b"MM\0*"),
            ..request(&rgba, 8, 8)
        }),
        Status::InvalidArgument
    );
    let big_xmp = vec![b'x'; 65_534 - 29];
    assert_eq!(
        fails(EncodeRequest {
            xmp: Some(&big_xmp),
            ..request(&rgba, 8, 8)
        }),
        Status::SegmentTooLarge
    );
    let fitting_xmp = vec![b'x'; 65_533 - 29];
    assert!(
        codec::encode(&EncodeRequest {
            xmp: Some(&fitting_xmp),
            ..request(&rgba, 8, 8)
        })
        .is_ok()
    );
    let huge_icc = vec![0u8; codec::ICC_CHUNK * 255 + 1];
    assert_eq!(
        fails(EncodeRequest {
            icc: Some(&huge_icc),
            ..request(&rgba, 8, 8)
        }),
        Status::SegmentTooLarge
    );

    assert_eq!(codec::decode(b"not a jpeg").unwrap_err().status, Status::DecodeFailed);
    assert_eq!(codec::decode(&[]).unwrap_err().status, Status::DecodeFailed);
    // A cut file: the decoder is tolerant and may give what it read, but never panics, and a failure says so
    let jpeg = codec::encode(&request(&rgba, 8, 8)).unwrap();
    for cut in [3, 20, jpeg.len() / 2, jpeg.len() - 2] {
        if let Err(error) = codec::decode(&jpeg[..cut]) {
            assert_eq!(error.status, Status::DecodeFailed, "cut at {cut}");
        }
    }
}

#[test]
fn a_frame_too_big_refused_before_any_allocation() {
    let rgba = picture(8, 8);
    let mut jpeg = codec::encode(&request(&rgba, 8, 8)).unwrap();
    let sof = jpeg.windows(2).position(|w| w == [0xff, 0xc0]).unwrap();
    // 20 000 x 20 000: 400 Mpx, over the limit
    jpeg[sof + 5..sof + 9].copy_from_slice(&[0x4e, 0x20, 0x4e, 0x20]);
    let error = codec::decode(&jpeg).unwrap_err();
    assert_eq!(error.status, Status::TooLarge, "{}", error.message);
}

#[test]
fn a_panic_becomes_a_status_and_its_message() {
    let mut buffer = [0xaau8; 64];
    let status = guard(buffer.as_mut_ptr(), buffer.len(), || panic!("boom in the codec"));
    assert_eq!(status, Status::Panic as i32);
    let end = buffer.iter().position(|&b| b == 0).unwrap();
    let message = std::str::from_utf8(&buffer[..end]).unwrap();
    assert!(message.contains("boom in the codec"), "{message}");

    let status = guard(std::ptr::null_mut(), 0, || panic!("{}", String::from("owned message")));
    assert_eq!(status, Status::Panic as i32);
}

#[test]
fn messages_cut_on_a_character_boundary() {
    let mut buffer = [0xaau8; 6];
    write_message(buffer.as_mut_ptr(), buffer.len(), "aéééé");
    // "a" and two "é" make 5 bytes, then the NUL
    assert_eq!(&buffer, b"a\xc3\xa9\xc3\xa9\0");
    let mut buffer = [0xaau8; 5];
    write_message(buffer.as_mut_ptr(), buffer.len(), "aéééé");
    assert_eq!(&buffer[..4], b"a\xc3\xa9\0");
}

#[test]
fn the_c_functions_as_dart_calls_them() {
    let (width, height) = (32u32, 16u32);
    let rgba = picture(width as usize, height as usize);
    let icc = profile(1_000, b"RGB ");
    let xmp = b"<x:xmpmeta/>";
    let mut jpeg: *mut u8 = std::ptr::null_mut();
    let mut jpeg_length = 0usize;
    let mut error = [0u8; 256];
    // SAFETY: every pointer points to live memory of the length given
    let status = unsafe {
        isc_encode(
            rgba.as_ptr(),
            rgba.len(),
            width,
            height,
            92,
            2,
            std::ptr::null(),
            0,
            xmp.as_ptr(),
            xmp.len(),
            icc.as_ptr(),
            icc.len(),
            &mut jpeg,
            &mut jpeg_length,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert_eq!(status, 0);
    assert!(!jpeg.is_null() && jpeg_length > 100);

    let (mut w, mut h) = (0u32, 0u32);
    let (mut pixels, mut pixels_length) = (std::ptr::null_mut(), 0usize);
    let (mut profile_out, mut profile_length) = (std::ptr::null_mut(), 0usize);
    // SAFETY: jpeg and jpeg_length come from isc_encode; the out values are locals
    let status = unsafe {
        isc_decode(
            jpeg,
            jpeg_length,
            &mut w,
            &mut h,
            &mut pixels,
            &mut pixels_length,
            &mut profile_out,
            &mut profile_length,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert_eq!(status, 0);
    assert_eq!((w, h, pixels_length), (width, height, rgba.len()));
    // SAFETY: as isc_decode returned them
    let read_profile = unsafe { std::slice::from_raw_parts(profile_out, profile_length) };
    assert_eq!(read_profile, icc.as_slice());
    // SAFETY: each freed once, with the length given
    unsafe {
        isc_free(pixels, pixels_length);
        isc_free(profile_out, profile_length);
        isc_free(jpeg, jpeg_length);
        isc_free(std::ptr::null_mut(), 0);
    }

    // An unknown subsampling, then a null pointer: status 1 and a reason
    let mut out: *mut u8 = std::ptr::null_mut();
    let mut out_length = 0usize;
    // SAFETY: as above
    let status = unsafe {
        isc_encode(
            rgba.as_ptr(),
            rgba.len(),
            width,
            height,
            92,
            9,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            &mut out,
            &mut out_length,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert_eq!(status, Status::InvalidArgument as i32);
    assert!(out.is_null());
    assert!(error.starts_with(b"subsampling 9\0"));
    // SAFETY: a null jpeg is refused before any read
    let status = unsafe {
        isc_decode(
            std::ptr::null(),
            0,
            &mut w,
            &mut h,
            &mut pixels,
            &mut pixels_length,
            &mut profile_out,
            &mut profile_length,
            std::ptr::null_mut(),
            0,
        )
    };
    assert_eq!(status, Status::InvalidArgument as i32);

    assert_eq!(isc_abi_version(), ABI_VERSION);
    let mut length = 0usize;
    // SAFETY: a static text and its length
    let text = unsafe {
        let data = isc_licenses(&mut length);
        std::str::from_utf8(std::slice::from_raw_parts(data, length)).unwrap()
    };
    assert!(text.contains("This software is based in part on the work of the Independent JPEG Group."));
    assert!(text.contains("Volker Ströbel"));
    assert!(text.contains("zune-image developers"));
    assert!(text.contains("Thomas G. Lane, Guido Vollbeding"));
}

/// The measure of the plan: decode a photo, lay it twice side by side, encode the pair. By hand, in release:
/// IMMUCH360_SBS_MEASURE=/path/photo.jpg cargo test --release -- --ignored --nocapture measure
#[test]
#[ignore = "a measure, needs IMMUCH360_SBS_MEASURE"]
fn measure() {
    let path = std::env::var("IMMUCH360_SBS_MEASURE").expect("IMMUCH360_SBS_MEASURE, a JPEG");
    let bytes = std::fs::read(&path).unwrap();
    let start = Instant::now();
    let decoded = codec::decode(&bytes).unwrap();
    let decode = start.elapsed();
    let (width, height) = (decoded.width, decoded.height);
    let mut pair = vec![0u8; width * 2 * height * 4];
    for (row, source) in pair
        .chunks_exact_mut(width * 8)
        .zip(decoded.rgba.chunks_exact(width * 4))
    {
        row[..width * 4].copy_from_slice(source);
        row[width * 4..].copy_from_slice(source);
    }
    println!(
        "{path}: {width} x {height}, {:.1} Mpx, decoded in {:.3} s",
        (width * height) as f64 / 1e6,
        decode.as_secs_f64()
    );
    for subsampling in [Subsampling::S420, Subsampling::S444] {
        for quality in [92u8, 97] {
            let start = Instant::now();
            let jpeg = codec::encode(&EncodeRequest {
                rgba: &pair,
                width: width * 2,
                height,
                quality,
                subsampling,
                exif: None,
                xmp: None,
                icc: decoded.icc.as_deref(),
            })
            .unwrap();
            println!(
                "pair {} x {height} ({:.1} Mpx), {subsampling:?}, quality {quality}: encoded in {:.3} s, {:.1} MB",
                width * 2,
                (width * 2 * height) as f64 / 1e6,
                start.elapsed().as_secs_f64(),
                jpeg.len() as f64 / 1e6
            );
        }
    }
}
