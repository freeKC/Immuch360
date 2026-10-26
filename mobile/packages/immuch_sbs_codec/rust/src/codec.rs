// The codec itself, safe Rust: an original decoded as its file stores it, and the side by side pair written with its
// EXIF, XMP and ICC segments in the order SbsCodec states (mobile/lib/desktop/ai/codec/sbs_codec.dart). lib.rs puts
// the C functions around it.

use jpeg_encoder::{ChromaSubsamplingMethod, ColorType, Encoder, SamplingFactor};
use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::DecoderOptions;
use zune_jpeg::JpegDecoder;

/// The largest side a JPEG frame header can hold
pub const MAX_SIDE: usize = 65_535;

/// The largest original decoded, 480 MB of RGBA: a bigger one is refused rather than risk the memory of the computer
/// (an allocation the system refuses ends a Rust program instead of failing)
pub const MAX_DECODE_PIXELS: usize = 120_000_000;

/// The signature of an XMP packet in its APP1 segment
pub const XMP_SIGNATURE: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";

/// The signature of an EXIF APP1 payload
pub const EXIF_SIGNATURE: &[u8] = b"Exif\0\0";

/// The signature of each APP2 chunk of an ICC profile
pub const ICC_SIGNATURE: &[u8] = b"ICC_PROFILE\0";

/// The bytes of a profile per APP2 chunk: 65 535 less the length field, the signature and the two counters
pub const ICC_CHUNK: usize = 65_535 - 2 - 12 - 2;

/// What a call returns to Dart; 0 is success. The values are part of the C interface: never renumbered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Status {
    Ok = 0,
    InvalidArgument = 1,
    DecodeFailed = 2,
    TooLarge = 3,
    OutOfMemory = 4,
    EncodeFailed = 5,
    SegmentTooLarge = 6,
    Panic = 7,
}

#[derive(Debug)]
pub struct CodecError {
    pub status: Status,
    pub message: String,
}

impl CodecError {
    pub fn new(status: Status, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

/// The chroma subsampling written, numbered as ChromaSubsampling of sbs_codec.dart lists it
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Subsampling {
    S444,
    S422,
    S420,
    S440,
    S411,
}

impl Subsampling {
    pub fn from_code(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::S444),
            1 => Some(Self::S422),
            2 => Some(Self::S420),
            3 => Some(Self::S440),
            4 => Some(Self::S411),
            _ => None,
        }
    }

    fn factor(self) -> SamplingFactor {
        match self {
            Self::S444 => SamplingFactor::F_1_1,
            Self::S422 => SamplingFactor::F_2_1,
            Self::S420 => SamplingFactor::F_2_2,
            Self::S440 => SamplingFactor::F_1_2,
            Self::S411 => SamplingFactor::F_4_1,
        }
    }
}

/// An original as its file stores it: RGBA rows, no orientation applied, no colour conversion
pub struct Decoded {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
    /// The profile the pixels are in; none when the file has none, or one for another colour space (the CMYK profile
    /// of a CMYK file, whose pixels come out as plain RGB, would be a lie on them)
    pub icc: Option<Vec<u8>>,
}

// The sizes only: the pixels of a photo are no log line
impl std::fmt::Debug for Decoded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let icc = self.icc.as_ref().map(Vec::len);
        write!(f, "Decoded({} x {}, ICC {icc:?} bytes)", self.width, self.height)
    }
}

pub fn decode(jpeg: &[u8]) -> Result<Decoded, CodecError> {
    let options = DecoderOptions::default()
        .set_max_width(MAX_SIDE)
        .set_max_height(MAX_SIDE)
        .jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut decoder = JpegDecoder::new_with_options(ZCursor::new(jpeg), options);
    decoder
        .decode_headers()
        .map_err(|error| CodecError::new(Status::DecodeFailed, error.to_string()))?;
    let (width, height) = decoder
        .dimensions()
        .ok_or_else(|| CodecError::new(Status::DecodeFailed, "no frame header"))?;
    let pixels = width.saturating_mul(height);
    if pixels > MAX_DECODE_PIXELS {
        return Err(CodecError::new(
            Status::TooLarge,
            format!("{width} x {height} is more than {MAX_DECODE_PIXELS} pixels"),
        ));
    }
    let size = decoder
        .output_buffer_size()
        .ok_or_else(|| CodecError::new(Status::TooLarge, format!("{width} x {height}")))?;
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(size)
        .map_err(|_| CodecError::new(Status::OutOfMemory, format!("{size} bytes for {width} x {height}")))?;
    rgba.resize(size, 0);
    decoder
        .decode_into(&mut rgba)
        .map_err(|error| CodecError::new(Status::DecodeFailed, error.to_string()))?;
    let icc = decoder.icc_profile().filter(|profile| is_rgb_profile(profile));
    Ok(Decoded {
        width,
        height,
        rgba,
        icc,
    })
}

/// Whether [profile] describes RGB data: the colour space signature of its header, bytes 16 to 19
pub fn is_rgb_profile(profile: &[u8]) -> bool {
    profile.len() >= 128 && &profile[16..20] == b"RGB "
}

/// The pair to write and how
pub struct EncodeRequest<'a> {
    pub rgba: &'a [u8],
    pub width: usize,
    pub height: usize,
    pub quality: u8,
    pub subsampling: Subsampling,
    /// The APP1 payload, "Exif\0\0" and its TIFF structure
    pub exif: Option<&'a [u8]>,
    /// The XMP packet, UTF-8
    pub xmp: Option<&'a [u8]>,
    pub icc: Option<&'a [u8]>,
}

/// The JPEG of [request]: SOI, the EXIF, the XMP, the ICC chunks, then the image, without the JFIF segment
/// jpeg-encoder writes first. A pixel that is not opaque is laid on black, as the Dart codec does.
pub fn encode(request: &EncodeRequest) -> Result<Vec<u8>, CodecError> {
    let EncodeRequest {
        rgba,
        width,
        height,
        quality,
        subsampling,
        ..
    } = *request;
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return Err(CodecError::new(
            Status::TooLarge,
            format!("{width} x {height} does not fit in a JPEG"),
        ));
    }
    let expected = width * height * 4;
    if rgba.len() != expected {
        return Err(CodecError::new(
            Status::InvalidArgument,
            format!(
                "{} bytes of RGBA for {width} x {height}, {expected} expected",
                rgba.len()
            ),
        ));
    }
    if !(1..=100).contains(&quality) {
        return Err(CodecError::new(
            Status::InvalidArgument,
            format!("quality {quality}, 1 to 100"),
        ));
    }
    // The segments first: a packet too big fails before seconds of encoding
    let segments = segments(request)?;
    let flattened = on_black(rgba)?;

    let mut body = Vec::new();
    // About what a photo at quality 90 takes; the vector grows if needed
    body.try_reserve(expected / 8)
        .map_err(|_| CodecError::new(Status::OutOfMemory, format!("{} bytes for the JPEG", expected / 8)))?;
    let mut encoder = Encoder::new(&mut body, quality);
    encoder.set_sampling_factor(subsampling.factor());
    // The average of each block, as libjpeg does, rather than its top left pixel
    encoder.set_chroma_subsampling_method(ChromaSubsamplingMethod::Average);
    let result = match &flattened {
        Some(rgb) => encoder.encode(rgb, width as u16, height as u16, ColorType::Rgb),
        None => encoder.encode(rgba, width as u16, height as u16, ColorType::Rgba),
    };
    result.map_err(|error| CodecError::new(Status::EncodeFailed, error.to_string()))?;
    drop(flattened);

    let image = after_header(&body)?;
    let mut out = Vec::new();
    out.try_reserve_exact(2 + segments.len() + image.len())
        .map_err(|_| CodecError::new(Status::OutOfMemory, "the JPEG and its segments"))?;
    out.extend_from_slice(&[0xff, 0xd8]);
    out.extend_from_slice(&segments);
    out.extend_from_slice(image);
    Ok(out)
}

/// The EXIF, the XMP and the ICC chunks of [request], each a whole segment with its marker
pub fn segments(request: &EncodeRequest) -> Result<Vec<u8>, CodecError> {
    let mut out = Vec::new();
    if let Some(exif) = request.exif {
        if !exif.starts_with(EXIF_SIGNATURE) {
            return Err(CodecError::new(
                Status::InvalidArgument,
                "an EXIF payload starts with Exif\\0\\0",
            ));
        }
        push_segment(&mut out, 0xe1, &[exif], "the EXIF")?;
    }
    if let Some(xmp) = request.xmp {
        push_segment(&mut out, 0xe1, &[XMP_SIGNATURE, xmp], "the XMP packet")?;
    }
    if let Some(icc) = request.icc.filter(|icc| !icc.is_empty()) {
        let count = icc.len().div_ceil(ICC_CHUNK);
        if count > 255 {
            return Err(CodecError::new(
                Status::SegmentTooLarge,
                format!("an ICC profile of {} bytes needs more than 255 chunks", icc.len()),
            ));
        }
        for (index, chunk) in icc.chunks(ICC_CHUNK).enumerate() {
            let counters = [(index + 1) as u8, count as u8];
            push_segment(&mut out, 0xe2, &[ICC_SIGNATURE, &counters, chunk], "an ICC chunk")?;
        }
    }
    Ok(out)
}

fn push_segment(out: &mut Vec<u8>, marker: u8, parts: &[&[u8]], what: &str) -> Result<(), CodecError> {
    let length = 2 + parts.iter().map(|part| part.len()).sum::<usize>();
    if length > 0xffff {
        return Err(CodecError::new(
            Status::SegmentTooLarge,
            format!("{what} takes {} bytes, one segment holds 65 533", length - 2),
        ));
    }
    out.extend_from_slice(&[0xff, marker, (length >> 8) as u8, length as u8]);
    for part in parts {
        out.extend_from_slice(part);
    }
    Ok(())
}

/// RGB pixels laid on black when one pixel of [rgba] is not opaque, none when all are (the usual case, no copy)
pub fn on_black(rgba: &[u8]) -> Result<Option<Vec<u8>>, CodecError> {
    if rgba.as_chunks::<4>().0.iter().all(|pixel| pixel[3] == 255) {
        return Ok(None);
    }
    let mut rgb = Vec::new();
    rgb.try_reserve_exact(rgba.len() / 4 * 3)
        .map_err(|_| CodecError::new(Status::OutOfMemory, "the pixels laid on black"))?;
    for pixel in rgba.as_chunks::<4>().0 {
        let alpha = u32::from(pixel[3]);
        for &channel in &pixel[..3] {
            rgb.push(((u32::from(channel) * alpha + 127) / 255) as u8);
        }
    }
    Ok(Some(rgb))
}

/// What follows the SOI and the JFIF APP0 jpeg-encoder always writes
fn after_header(jpeg: &[u8]) -> Result<&[u8], CodecError> {
    if jpeg.len() < 4 || jpeg[..2] != [0xff, 0xd8] {
        return Err(CodecError::new(Status::EncodeFailed, "the encoder wrote no SOI"));
    }
    let rest = &jpeg[2..];
    if rest.len() >= 9 && rest[..2] == [0xff, 0xe0] && &rest[4..9] == b"JFIF\0" {
        let length = usize::from(rest[2]) << 8 | usize::from(rest[3]);
        if 2 + length <= rest.len() {
            return Ok(&rest[2 + length..]);
        }
    }
    Ok(rest)
}
