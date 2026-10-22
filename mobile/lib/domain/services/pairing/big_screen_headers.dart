// The device headers of a big screen (a TV, the Quest window, a computer). The server names a session after the
// deviceModel and deviceType headers of its requests (its User-Agent first), and rewrites that name at the first
// request of a new app version, then hourly. The phone named the screen's session "Immuch360 on Living room TV"; the
// screen sends that name back on every stack (the OpenAPI client and the native clients), so that the server keeps
// it, in the web app's Authorized devices too.

/// The name of a big screen's session on the server
String pairingSessionName(String label) => 'Immuch360 on $label';

const _ascii = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae', 'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', //
  'ë': 'e', 'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', //
  'ø': 'o', 'œ': 'oe', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'À': 'A', 'Á': 'A', //
  'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', 'Æ': 'AE', 'Ç': 'C', 'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E', 'Ì': 'I', //
  'Í': 'I', 'Î': 'I', 'Ï': 'I', 'Ñ': 'N', 'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O', 'Œ': 'OE', //
  'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U', 'Ý': 'Y', '’': "'", '‘': "'", '“': '"', '”': '"', //
};

/// [text] as a header value can carry it: printable ASCII only (OkHttp refuses anything else, and the whole header
/// set with it), the accented Latin letters without their accents, any other character as "?"
String asciiHeaderValue(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    if (rune >= 0x20 && rune < 0x7f) {
      out.write(character);
    } else {
      out.write(_ascii[character] ?? '?');
    }
  }
  return out.toString().trim();
}

/// deviceModel and deviceType for a big screen named [label] running on [os] ("Android", "Windows", "Linux",
/// "macOS"); none without a label (the phones never have one)
Map<String, String> bigScreenDeviceHeaders({required String? label, required String os}) {
  if (label == null || label.trim().isEmpty) {
    return const {};
  }
  return {'deviceModel': asciiHeaderValue(pairingSessionName(label.trim())), 'deviceType': os};
}
