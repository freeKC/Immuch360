// The licence texts of the crates built into the library, carried by the library itself so that the licence page of
// Immuch360 Desktop shows them wherever the library is shipped (lib/desktop/ai/codec/sbs_codec_licenses.dart). The
// texts are the files of the crates as published, copied into ../licenses. jpeg-encoder is "(MIT OR Apache-2.0) AND
// IJG": its IJG terms ask that a program shipped as executable code says it is based in part on the work of the
// Independent JPEG Group, which the first paragraph does.

pub const TEXT: &str = concat!(
    "The JPEG codec of the AI features of Immuch360 Desktop (immuch_sbs_codec), written in Rust: it decodes the ",
    "original photos and writes the side by side 3D photos. This software is based in part on the work of the ",
    "Independent JPEG Group.\n\n",
    "It is built from these crates, each used under its MIT licence:\n",
    "- jpeg-encoder 0.7.1, https://github.com/vstroebel/jpeg-encoder, (MIT OR Apache-2.0) AND IJG\n",
    "- zune-jpeg 0.5.15 and zune-core 0.5.3, https://github.com/etemesi254/zune-image, MIT OR Apache-2.0 OR Zlib\n",
    "- the Rust standard library 1.98.0, https://github.com/rust-lang/rust, MIT OR Apache-2.0; its notices: ",
    "https://github.com/rust-lang/rust/blob/1.98.0/COPYRIGHT\n\n",
    "jpeg-encoder, LICENSE-MIT:\n\n",
    include_str!("../../licenses/jpeg-encoder/LICENSE-MIT"),
    "\n\njpeg-encoder, LICENSE-IJG:\n\n",
    include_str!("../../licenses/jpeg-encoder/LICENSE-IJG"),
    "\n\nzune-jpeg and zune-core, LICENSE-MIT:\n\n",
    include_str!("../../licenses/zune-jpeg/LICENSE-MIT"),
);
