// The notice of libfacedetection, the face detector built into the two detector DLLs of the plugin. Its 3-clause BSD
// licence asks for the copyright, the conditions and the disclaimer in the documentation of a binary distribution:
// the app's licence page shows this entry on Windows (lib/desktop/spatial/head_tracker_licenses.dart), and the Windows
// ZIP and installer carry the same LICENSE in licenses/libfacedetection (.github/desktop/windows_bundle.py). The text
// below is third_party/libfacedetection/LICENSE, byte for byte (a test compares them).

import 'package:flutter/foundation.dart';

/// The commit of github.com/ShiqiYu/libfacedetection the plugin carries (third_party/libfacedetection/README.md)
const libfacedetectionCommit = 'acf7b254121927e7dced30e233a2e03119f28ea2';

/// third_party/libfacedetection/LICENSE
const libfacedetectionLicense =
    '''By downloading, copying, installing or using the software you agree to this license.
If you do not agree to this license, do not download, install,
copy or use the software.


                  License Agreement For libfacedetection
                     (3-clause BSD License)

Copyright (c) 2015-2019, Shiqi Yu, all rights reserved.
shiqi.yu@gmail.com

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.

  * Neither the names of the copyright holders nor the names of the contributors
    may be used to endorse or promote products derived from this software
    without specific prior written permission.

This software is provided by the copyright holders and contributors "as is" and
any express or implied warranties, including, but not limited to, the implied
warranties of merchantability and fitness for a particular purpose are disclaimed.
In no event shall copyright holders or contributors be liable for any direct,
indirect, incidental, special, exemplary, or consequential damages
(including, but not limited to, procurement of substitute goods or services;
loss of use, data, or profits; or business interruption) however caused
and on any theory of liability, whether in contract, strict liability,
or tort (including negligence or otherwise) arising in any way out of
the use of this software, even if advised of the possibility of such damage.''';

/// The entry of the licence page: what the library does in the app, where its source is, then its licence
LicenseEntry libfacedetectionLicenseEntry() => const LicenseEntryWithLineBreaks(
  ['libfacedetection'],
  'libfacedetection, the face detector of the head tracking of Spatial 2.5D on Windows, built into '
  'immuch_head_tracker_detect.dll and immuch_head_tracker_detect_avx2.dll. Source: '
  'https://github.com/ShiqiYu/libfacedetection at commit $libfacedetectionCommit, unchanged, in '
  'mobile/packages/immuch_head_tracker/third_party/libfacedetection of https://github.com/freeKC/Immuch360.\n\n'
  '$libfacedetectionLicense',
);
