# libfacedetection in Immuch360 Desktop

The head tracking of Spatial 2.5D on the computers (Windows, Linux and macOS) finds the user's face in the webcam's
pictures with libfacedetection, https://github.com/ShiqiYu/libfacedetection, vendored at commit
`acf7b254121927e7dced30e233a2e03119f28ea2` (28 June 2026) in
`mobile/packages/immuch_head_tracker/third_party/libfacedetection` (its README there lists the files and their git
blobs). The network's weights are part of the source: `src/facedetectcnn-data.cpp` (445,771 bytes), compiled into the
detector libraries. Nothing is downloaded, at build time or at run time.

## The licence of the code and the weights

The repository's `LICENSE`, quoted from the vendored file:

> License Agreement For libfacedetection
> (3-clause BSD License)
>
> Copyright (c) 2015-2019, Shiqi Yu, all rights reserved.
>
> Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
> following conditions are met: [...]

The weights file sits in that repository under that licence; no other licence is given for it. The binary
distributions carry the notice: the licence page of the app on the three systems
(`mobile/lib/desktop/spatial/head_tracker_licenses.dart`, the text compared with `LICENSE` by a test), and the Windows
ZIP and installer in `licenses/libfacedetection/LICENSE` (`.github/desktop/windows_bundle.py`).

## Where the weights come from

The weights were trained by the authors with libfacedetection.train (YuNet). Its training set is WIDER FACE, whose
mirrors give the annotations under CC BY-NC-ND (the official page could not be read when this was checked), with the
five landmarks of the SCRFD `labelv2` annotations of InsightFace, whose README says the annotations "(and the models
trained with these data) are available for non-commercial research purposes only". So the code and the weights are
BSD-3-Clause by their repository, while the data they were trained on is reserved by its authors for non-commercial
research. Nearly every open face detector is trained on the same data. The system detectors avoid shipping weights
(Vision on macOS, the box-only FaceDetector of Windows), but they would behave differently on each system, and the
Windows one gives no landmarks.

## Decision of 25 November 2026

FreeKC, the maintainer of Immuch360, was given these facts in the plan of Spatial 2.5D on the computers
(`spatial-25d-desktop-plan.md` of the research notes, decision 2 and its review) and decided on 25 November 2026 to
ship libfacedetection with its weights. His words: "j'accepte la licence, immuch360 n'est pas un projet commercial"
(I accept the licence, Immuch360 is not a commercial project). Immuch360 is a free app, with no sale, no advertising
and no account to pay for. This is his decision on the provenance of the training data, not a permission of the
authors of WIDER FACE or InsightFace, who have given none.

What goes with it:

1. The detector runs on the computer only, on the frames of the webcam while a Spatial 2.5D view is on screen and the
   user agreed; the frames never leave the native memory of the tracker, nothing is written or sent.
2. Should the question come up again (a commercial use, a request of the data's authors), the detector sits behind
   `src/face_detect.h`: another detector (a system one, or a model trained on data under an open licence) can replace
   it without touching the rest of the tracker.
