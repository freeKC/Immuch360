// A small, forgiving XML parser for what the network shares exchange: WebDAV multistatus answers, UPnP device
// descriptions, SOAP answers and DIDL-Lite listings of the DLNA media servers, PROPFIND requests to the phone share.
// Servers in the wild send XML that a strict parser refuses (undeclared prefixes, stray "&", unclosed elements), and
// what the app needs of it is a handful of elements by local name: a full XML library would bring nothing more.

/// An element: its local name, its namespace, its attributes, its children and its text
class LiteXmlElement {
  LiteXmlElement(this.qualifiedName, this.namespace, this.name);

  /// The name as written, with its prefix ("D:href")
  final String qualifiedName;

  /// The namespace URI the prefix (or the default namespace) is bound to, null when none is
  final String? namespace;

  /// The local name, without the prefix ("href")
  final String name;

  /// By local name ("profileID" for "dlna:profileID"), the xmlns declarations left out, entities decoded; the first
  /// of two attributes with the same local name wins
  final Map<String, String> attributes = {};

  final List<LiteXmlElement> children = [];
  final StringBuffer _text = StringBuffer();

  /// The text right inside this element (not the one of its children), entities decoded, CDATA kept as is
  String get text => _text.toString();

  /// The children named [name]; [namespace] null matches any namespace, none included
  Iterable<LiteXmlElement> childrenNamed(String name, {String? namespace}) =>
      children.where((child) => child._matches(name, namespace));

  LiteXmlElement? child(String name, {String? namespace}) => childrenNamed(name, namespace: namespace).firstOrNull;

  /// The elements named [name] anywhere below this one, depth first in document order; [namespace] as in
  /// [childrenNamed]
  Iterable<LiteXmlElement> descendantsNamed(String name, {String? namespace}) sync* {
    // A stack rather than a recursion, so that a deep document costs no nested iterators
    final stack = [...children.reversed];
    while (stack.isNotEmpty) {
      final element = stack.removeLast();
      if (element._matches(name, namespace)) {
        yield element;
      }
      stack.addAll(element.children.reversed);
    }
  }

  bool _matches(String name, String? namespace) =>
      this.name == name && (namespace == null || this.namespace == namespace);

  @override
  String toString() => 'LiteXmlElement($qualifiedName${namespace == null ? '' : ' {$namespace}'})';
}

final _tagName = RegExp(r'^\s*([^\s/>]+)');
final _attribute = RegExp(r'''([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _entity = RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

/// The document of [xml]: an element without a name whose children are the top level elements.
///
/// Elements come with their namespaces resolved and their attributes, text with its entities and CDATA sections;
/// comments, processing instructions and doctypes are skipped. Malformed parts are skipped rather than refused, and an
/// end tag closes the matching open element, so that this never throws.
LiteXmlElement parseLiteXml(String xml) {
  final document = LiteXmlElement('', null, '');
  final elements = [document];
  final scopes = <Map<String, String>>[const {}];
  final length = xml.length;
  var i = xml.startsWith('\uFEFF') ? 1 : 0;
  while (i < length) {
    final open = xml.indexOf('<', i);
    final textEnd = open < 0 ? length : open;
    if (textEnd > i) {
      elements.last._text.write(decodeXmlEntities(xml.substring(i, textEnd)));
    }
    if (open < 0) {
      break;
    }
    if (xml.startsWith('<!--', open)) {
      final end = xml.indexOf('-->', open + 4);
      i = end < 0 ? length : end + 3;
      continue;
    }
    if (xml.startsWith('<![CDATA[', open)) {
      final end = xml.indexOf(']]>', open + 9);
      elements.last._text.write(xml.substring(open + 9, end < 0 ? length : end));
      i = end < 0 ? length : end + 3;
      continue;
    }
    if (xml.startsWith('<?', open)) {
      final end = xml.indexOf('?>', open + 2);
      i = end < 0 ? length : end + 2;
      continue;
    }
    if (xml.startsWith('<!', open)) {
      // A doctype, with its internal subset between brackets when there is one
      var end = xml.indexOf('>', open);
      final bracket = xml.indexOf('[', open);
      if (bracket >= 0 && end >= 0 && bracket < end) {
        final subsetEnd = xml.indexOf(']', bracket);
        end = subsetEnd < 0 ? -1 : xml.indexOf('>', subsetEnd);
      }
      i = end < 0 ? length : end + 1;
      continue;
    }

    // A start or end tag, up to the ">" outside of the quoted attribute values
    var end = open + 1;
    String? quote;
    while (end < length) {
      final c = xml[end];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '>') {
        break;
      }
      end++;
    }
    if (end >= length) {
      break;
    }
    final tag = xml.substring(open + 1, end);
    i = end + 1;

    if (tag.startsWith('/')) {
      final qualifiedName = tag.substring(1).trim();
      for (var k = elements.length - 1; k > 0; k--) {
        if (elements[k].qualifiedName == qualifiedName) {
          elements.length = k;
          scopes.length = k;
          break;
        }
      }
      continue;
    }

    final selfClosing = tag.endsWith('/');
    final content = selfClosing ? tag.substring(0, tag.length - 1) : tag;
    final nameMatch = _tagName.firstMatch(content);
    if (nameMatch == null) {
      continue;
    }
    final qualifiedName = nameMatch.group(1)!;
    var scope = scopes.last;
    final attributes = <(String, String)>[];
    for (final attribute in _attribute.allMatches(content, nameMatch.end)) {
      final name = attribute.group(1)!;
      final value = decodeXmlEntities(attribute.group(2) ?? attribute.group(3) ?? '');
      if (name == 'xmlns' || name.startsWith('xmlns:')) {
        if (identical(scope, scopes.last)) {
          scope = Map.of(scope);
        }
        scope[name == 'xmlns' ? '' : name.substring(6)] = value;
      } else {
        attributes.add((name, value));
      }
    }
    final colon = qualifiedName.indexOf(':');
    final prefix = colon < 0 ? '' : qualifiedName.substring(0, colon);
    final namespace = scope[prefix];
    final element = LiteXmlElement(
      qualifiedName,
      namespace == null || namespace.isEmpty ? null : namespace,
      colon < 0 ? qualifiedName : qualifiedName.substring(colon + 1),
    );
    for (final (name, value) in attributes) {
      element.attributes.putIfAbsent(name.substring(name.indexOf(':') + 1), () => value);
    }
    elements.last.children.add(element);
    if (!selfClosing) {
      elements.add(element);
      scopes.add(scope);
    }
  }
  return document;
}

/// [text] with its character references and the five predefined entities replaced; anything else (an unknown entity,
/// a lone "&") is left as it is
String decodeXmlEntities(String text) {
  if (!text.contains('&')) {
    return text;
  }
  return text.replaceAllMapped(_entity, (match) {
    final entity = match.group(1)!;
    if (entity.startsWith('#')) {
      final code = entity.length > 1 && (entity[1] == 'x' || entity[1] == 'X')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return code != null && code >= 0 && code <= 0x10FFFF ? String.fromCharCode(code) : match[0]!;
    }
    return switch (entity) {
      'lt' => '<',
      'gt' => '>',
      'amp' => '&',
      'quot' => '"',
      'apos' => "'",
      _ => match[0]!,
    };
  });
}

final _escaped = RegExp('[&<>"\']');

/// [text] safe inside an element or a quoted attribute value: & < > " ' as &amp; &lt; &gt; &quot; &apos;
String escapeXmlText(String text) => text.replaceAllMapped(
  _escaped,
  (match) => switch (match[0]!) {
    '&' => '&amp;',
    '<' => '&lt;',
    '>' => '&gt;',
    '"' => '&quot;',
    _ => '&apos;',
  },
);
