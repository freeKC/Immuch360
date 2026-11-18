// cargo test of video.rs against the golden fixtures of .github/desktop/ai: relief_golden_v1.json (the right eye of a
// 3D photo, every case exact, holes equal) and relief_video_golden_v1.json (external percentiles, the floating window,
// half side by side, the input of the model, the histogram of the cut detector), read by the small JSON reader below
// (the crate takes no JSON package for its tests). And the C functions as Dart calls them.

use std::collections::BTreeMap;
use std::path::PathBuf;

use super::video::{self, ReliefRequest};
use super::*;

#[derive(Debug, Clone)]
enum Json {
    Null,
    Bool,
    Number(f64),
    Text(String),
    List(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    fn parse(text: &str) -> Json {
        let bytes = text.as_bytes();
        let mut at = 0;
        let value = Self::value(bytes, &mut at);
        Self::space(bytes, &mut at);
        assert_eq!(at, bytes.len(), "trailing text in the JSON");
        value
    }

    fn space(bytes: &[u8], at: &mut usize) {
        while *at < bytes.len() && bytes[*at].is_ascii_whitespace() {
            *at += 1;
        }
    }

    fn value(bytes: &[u8], at: &mut usize) -> Json {
        Self::space(bytes, at);
        match bytes[*at] {
            b'{' => {
                *at += 1;
                let mut map = BTreeMap::new();
                loop {
                    Self::space(bytes, at);
                    if bytes[*at] == b'}' {
                        *at += 1;
                        return Json::Object(map);
                    }
                    let Json::Text(key) = Self::value(bytes, at) else {
                        panic!("a key that is not a string")
                    };
                    Self::space(bytes, at);
                    assert_eq!(bytes[*at], b':');
                    *at += 1;
                    map.insert(key, Self::value(bytes, at));
                    Self::space(bytes, at);
                    if bytes[*at] == b',' {
                        *at += 1;
                    }
                }
            }
            b'[' => {
                *at += 1;
                let mut list = Vec::new();
                loop {
                    Self::space(bytes, at);
                    if bytes[*at] == b']' {
                        *at += 1;
                        return Json::List(list);
                    }
                    list.push(Self::value(bytes, at));
                    Self::space(bytes, at);
                    if bytes[*at] == b',' {
                        *at += 1;
                    }
                }
            }
            b'"' => {
                *at += 1;
                let mut text = Vec::new();
                while bytes[*at] != b'"' {
                    if bytes[*at] == b'\\' {
                        *at += 1;
                        text.push(match bytes[*at] {
                            b'n' => b'\n',
                            b't' => b'\t',
                            other => other,
                        });
                    } else {
                        text.push(bytes[*at]);
                    }
                    *at += 1;
                }
                *at += 1;
                Json::Text(String::from_utf8(text).expect("UTF-8"))
            }
            b't' => {
                *at += 4;
                Json::Bool
            }
            b'f' => {
                *at += 5;
                Json::Bool
            }
            b'n' => {
                *at += 4;
                Json::Null
            }
            _ => {
                let start = *at;
                while *at < bytes.len() && matches!(bytes[*at], b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9') {
                    *at += 1;
                }
                let text = std::str::from_utf8(&bytes[start..*at]).expect("a number");
                // Rust reads the shortest repr Python writes back to the same double
                Json::Number(text.parse().expect("a number"))
            }
        }
    }

    fn get(&self, key: &str) -> &Json {
        match self {
            Json::Object(map) => map.get(key).unwrap_or_else(|| panic!("no {key}")),
            _ => panic!("not an object"),
        }
    }

    fn list(&self) -> &[Json] {
        match self {
            Json::List(list) => list,
            _ => panic!("not a list"),
        }
    }

    fn number(&self) -> f64 {
        match self {
            Json::Number(value) => *value,
            _ => panic!("not a number"),
        }
    }

    fn text(&self) -> &str {
        match self {
            Json::Text(text) => text,
            _ => panic!("not a string"),
        }
    }

    fn numbers(&self) -> Vec<f64> {
        self.list().iter().map(Json::number).collect()
    }

    fn bytes(&self) -> Vec<u8> {
        self.list().iter().map(|value| value.number() as u8).collect()
    }

    /// A list of lists of numbers, flattened row after row
    fn flat(&self) -> Vec<f64> {
        self.list().iter().flat_map(Json::numbers).collect()
    }
}

fn fixture(name: &str) -> Json {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../test/fixtures/ai_immersive")
        .join(name);
    Json::parse(&std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display())))
}

/// pattern() of make_relief_video_golden.py
fn pattern(width: usize, height: usize, seed: usize) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(width * height * 3);
    for y in 0..height {
        for x in 0..width {
            rgb.push(((17 * x + 3 * y * y + seed) % 256) as u8);
            rgb.push(((5 * x * y + 40 + seed) % 256) as u8);
            rgb.push(((255 + 256 * 64 - 7 * x - 11 * y + 3 * seed) % 256) as u8);
        }
    }
    rgb
}

/// The percentile of a map by nearest rank, as relief-v1 reads it
fn percentile(sorted: &[f64], percent: usize) -> f64 {
    let rank = (percent * sorted.len()).div_ceil(100).max(1);
    sorted[rank - 1]
}

/// The frame of a relief case: the image in the left half of a 2L x H frame
fn frame_of(image: &Json) -> (Vec<u8>, usize, usize) {
    let rows: Vec<Vec<u8>> = image.list().iter().map(Json::bytes).collect();
    let height = rows.len();
    let width = rows[0].len() / 3;
    let mut sbs = vec![0u8; width * height * 6];
    for (y, row) in rows.iter().enumerate() {
        sbs[y * width * 6..y * width * 6 + width * 3].copy_from_slice(row);
    }
    (sbs, width, height)
}

fn holes_text(holes: &[u8], width: usize) -> Vec<String> {
    holes
        .chunks(width)
        .map(|row| row.iter().map(|&h| if h == 1 { '1' } else { '0' }).collect())
        .collect()
}

#[test]
fn the_right_eye_of_every_case_of_the_photo_golden_exactly() {
    let golden = fixture("relief_golden_v1.json");
    for case in golden.get("cases").list() {
        let name = case.get("name").text();
        let (mut sbs, width, height) = frame_of(case.get("image"));
        let depth = case.get("depth").flat();
        let mut sorted = depth.clone();
        sorted.sort_by(f64::total_cmp);
        let request = ReliefRequest {
            depth: &depth,
            depth_width: case.get("depth").list()[0].list().len(),
            depth_height: case.get("depth").list().len(),
            p2: percentile(&sorted, 2),
            p98: percentile(&sorted, 98),
            parallax: case.get("parallax").number(),
            convergence: case.get("convergence").number(),
            threads: 3,
        };
        let mut holes = vec![0u8; width * height];
        let filled = video::relief_v1_eye(&mut sbs, width, height, &request, &mut holes).unwrap();
        let expected: Vec<Vec<u8>> = case.get("rightEye").list().iter().map(Json::bytes).collect();
        for (y, row) in expected.iter().enumerate() {
            assert_eq!(
                &sbs[y * width * 6 + width * 3..(y + 1) * width * 6],
                &row[..],
                "{name}, row {y}"
            );
        }
        let expected_holes: Vec<&str> = case.get("holes").list().iter().map(Json::text).collect();
        assert_eq!(holes_text(&holes, width), expected_holes, "{name}");
        assert_eq!(filled as f64, case.get("filledPixels").number(), "{name}");
    }
}

#[test]
fn every_relief_case_of_the_video_golden_with_its_fade_and_half_frame() {
    let golden = fixture("relief_video_golden_v1.json");
    let photo = fixture("relief_golden_v1.json");
    let image = photo.get("cases").list()[0].get("image");
    for case in golden.get("relief").list() {
        let name = case.get("name").text();
        let (mut sbs, width, height) = frame_of(image);
        let depth = case.get("depth").flat();
        let request = ReliefRequest {
            depth: &depth,
            depth_width: case.get("depth").list()[0].list().len(),
            depth_height: case.get("depth").list().len(),
            p2: case.get("p2").number(),
            p98: case.get("p98").number(),
            parallax: case.get("parallax").number(),
            convergence: case.get("convergence").number(),
            threads: 1,
        };
        let mut holes = vec![0u8; width * height];
        let filled = video::relief_v1_eye(&mut sbs, width, height, &request, &mut holes).unwrap();
        let band = case.get("edgeBand").number() as usize;
        video::edge_fade(&mut sbs, width, height, band).unwrap();
        let expected: Vec<u8> = case.get("sbs").list().iter().flat_map(Json::bytes).collect();
        assert_eq!(sbs, expected, "{name}");
        assert_eq!(filled as f64, case.get("filledPixels").number(), "{name}");
        let expected_holes: Vec<&str> = case.get("holes").list().iter().map(Json::text).collect();
        assert_eq!(holes_text(&holes, width), expected_holes, "{name}");
        let mut half = vec![0u8; width * height * 3];
        video::half_sbs(&sbs, width, height, &mut half).unwrap();
        let expected_half: Vec<u8> = case.get("halfSbs").list().iter().flat_map(Json::bytes).collect();
        assert_eq!(half, expected_half, "{name}");
    }
}

#[test]
fn the_input_of_the_model_and_the_histogram_as_the_golden() {
    let golden = fixture("relief_video_golden_v1.json");
    for case in golden.get("vdaInput").list() {
        let source = case.get("source").numbers();
        let size = case.get("size").numbers();
        let (w, h, seed) = (source[0] as usize, source[1] as usize, source[2] as usize);
        let (width, height) = (size[0] as usize, size[1] as usize);
        let mut out = vec![0f32; 3 * width * height];
        video::vda_input(&pattern(w, h, seed), w, h, &mut out, width, height).unwrap();
        let expected: Vec<f32> = case.get("values").numbers().iter().map(|&v| v as f32).collect();
        assert_eq!(out, expected, "{}", case.get("name").text());
    }
    for case in golden.get("lumaHistogram").list() {
        let source = case.get("source").numbers();
        let (w, h, seed) = (source[0] as usize, source[1] as usize, source[2] as usize);
        let mut out = vec![0f64; video::HIST_BINS];
        video::luma_hist64(&pattern(w, h, seed), w, h, &mut out).unwrap();
        assert_eq!(out, case.get("histogram").numbers(), "{}", case.get("name").text());
    }
    for case in golden.get("edgeBands").list() {
        let band = video::edge_band(
            case.get("parallax").number(),
            case.get("width").number() as usize,
            case.get("convergence").number(),
        );
        assert_eq!(band as f64, case.get("band").number());
    }
}

#[test]
fn threads_change_no_value() {
    let (width, height) = (97, 41);
    let mut frame = vec![0u8; width * height * 6];
    for (y, row) in frame.chunks_mut(width * 6).enumerate() {
        row[..width * 3].copy_from_slice(&pattern(width, 1, y)[..]);
    }
    let depth: Vec<f64> = (0..28 * 14)
        .map(|i| ((i * 37 % 101) as f64).sin() * 3.0 + 4.0)
        .collect();
    let mut results = Vec::new();
    for threads in [1, 2, 5, 16] {
        let mut sbs = frame.clone();
        let request = ReliefRequest {
            depth: &depth,
            depth_width: 28,
            depth_height: 14,
            p2: 1.5,
            p98: 6.5,
            parallax: 0.05,
            convergence: 0.5,
            threads,
        };
        let filled = video::relief_v1_eye(&mut sbs, width, height, &request, &mut []).unwrap();
        results.push((sbs, filled));
    }
    assert!(results.windows(2).all(|pair| pair[0] == pair[1]));
}

#[test]
fn refusals_of_the_frame_work() {
    let mut sbs = vec![0u8; 8 * 4 * 6];
    let depth = vec![1.0f64; 4];
    let request = |parallax: f64| ReliefRequest {
        depth: &depth,
        depth_width: 2,
        depth_height: 2,
        p2: 0.0,
        p98: 1.0,
        parallax,
        convergence: 0.5,
        threads: 1,
    };
    assert!(video::relief_v1_eye(&mut sbs, 8, 4, &request(0.02), &mut []).is_ok());
    assert!(video::relief_v1_eye(&mut sbs, 8, 4, &request(1.5), &mut []).is_err());
    assert!(video::relief_v1_eye(&mut sbs[..10], 8, 4, &request(0.02), &mut []).is_err());
    assert!(video::edge_fade(&mut sbs, 8, 4, 5).is_err());
    let mut half = vec![0u8; 7 * 4 * 3];
    assert!(video::half_sbs(&sbs, 7, 4, &mut half).is_err());
    let mut input = vec![0f32; 3];
    assert!(video::vda_input(&[0; 12], 2, 2, &mut input, 14, 14).is_err());
}

#[test]
fn the_video_functions_as_dart_calls_them() {
    let (width, height) = (32usize, 8usize);
    let photo = fixture("relief_golden_v1.json");
    let (mut sbs, _, _) = frame_of(photo.get("cases").list()[0].get("image"));
    let depth: Vec<f64> = photo.get("cases").list()[0].get("depth").flat();
    let mut holes = vec![0u8; width * height];
    let mut filled = 0u64;
    let mut error = [0u8; 256];
    // SAFETY: every buffer is alive, of the length given, and apart
    let status = unsafe {
        isc_relief_v1_eye(
            sbs.as_mut_ptr(),
            sbs.len(),
            width as u32,
            height as u32,
            depth.as_ptr(),
            depth.len(),
            16,
            4,
            1.0,
            9.0,
            0.02,
            0.5,
            2,
            holes.as_mut_ptr(),
            holes.len(),
            &mut filled,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert_eq!(status, 0);
    assert_eq!(isc_edge_band(0.02, 1920, 0.5), 22);
    // SAFETY: as above
    let status = unsafe {
        isc_edge_fade(
            sbs.as_mut_ptr(),
            sbs.len(),
            width as u32,
            height as u32,
            3,
            error.as_mut_ptr(),
            256,
        )
    };
    assert_eq!(status, 0);
    assert_eq!(&sbs[..3], &[0, 0, 0]);
    let mut half = vec![0u8; width * height * 3];
    // SAFETY: as above
    let status = unsafe {
        isc_half_sbs(
            sbs.as_ptr(),
            sbs.len(),
            width as u32,
            height as u32,
            half.as_mut_ptr(),
            half.len(),
            error.as_mut_ptr(),
            256,
        )
    };
    assert_eq!(status, 0);
    let mut bins = [0f64; 64];
    let frame = pattern(64, 36, 1);
    // SAFETY: as above
    let status = unsafe {
        isc_luma_hist64(
            frame.as_ptr(),
            frame.len(),
            64,
            36,
            bins.as_mut_ptr(),
            error.as_mut_ptr(),
            256,
        )
    };
    assert_eq!(status, 0);
    assert!((bins.iter().sum::<f64>() - 1.0).abs() < 1e-9);
    let mut input = vec![0f32; 3 * 28 * 14];
    // SAFETY: as above
    let status = unsafe {
        isc_vda_input(
            frame.as_ptr(),
            frame.len(),
            64,
            36,
            input.as_mut_ptr(),
            input.len(),
            28,
            14,
            error.as_mut_ptr(),
            256,
        )
    };
    assert_eq!(status, 0);
    // A null pointer is a status and a message, never a crash
    // SAFETY: the null is what is checked
    let status = unsafe {
        isc_half_sbs(
            std::ptr::null(),
            0,
            2,
            2,
            half.as_mut_ptr(),
            12,
            error.as_mut_ptr(),
            256,
        )
    };
    assert_eq!(status, 1);
    assert!(error.starts_with(b"a null pointer"));
    assert_eq!(isc_abi_version(), 2);
}
