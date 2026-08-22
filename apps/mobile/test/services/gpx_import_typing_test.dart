import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Guards the iOS type declaration used by the document picker. A GPX file
/// delivered through a channel which drops its MIME type can be classified as
/// generic `public.data`; without that conformance it appears greyed out even
/// though Tide and Seek's parser could import it.
void main() {
  late XmlElement declaration;

  setUpAll(() {
    final plist = XmlDocument.parse(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    final root = plist.rootElement.findElements('dict').single;
    declaration = _arrayFor(
      root,
      'UTImportedTypeDeclarations',
    ).findElements('dict').single;
  });

  test('the GPX type is claimed by identifier, extension and MIME type', () {
    expect(_stringFor(declaration, 'UTTypeIdentifier'), 'com.topografix.gpx');

    final tags = _dictFor(declaration, 'UTTypeTagSpecification');
    expect(_stringsIn(_arrayFor(tags, 'public.filename-extension')), ['gpx']);
    expect(
      _stringsIn(_arrayFor(tags, 'public.mime-type')),
      containsAll(<String>['application/gpx+xml', 'application/xml']),
    );
  });

  test('a generically typed GPX file is still claimed', () {
    expect(
      _stringsIn(_arrayFor(declaration, 'UTTypeConformsTo')),
      containsAll(<String>['public.xml', 'public.data']),
    );
  });

  test('every type the picker accepts is declared or owned by iOS', () {
    const accepted = ['com.topografix.gpx', 'public.xml'];
    const systemOwned = {'public.xml', 'public.data', 'public.item'};

    for (final identifier in accepted) {
      expect(
        systemOwned.contains(identifier) ||
            identifier == _stringFor(declaration, 'UTTypeIdentifier'),
        isTrue,
        reason: '$identifier is accepted by the picker but declared nowhere',
      );
    }
  });
}

XmlElement _arrayFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'array');

XmlElement _dictFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'dict');

String _stringFor(XmlElement dict, String name) =>
    _valueFor(dict, name, 'string').innerText;

XmlElement _valueFor(XmlElement dict, String name, String expected) {
  final children = dict.childElements.toList(growable: false);
  for (var index = 0; index < children.length - 1; index += 1) {
    final child = children[index];
    if (child.name.local == 'key' && child.innerText == name) {
      final value = children[index + 1];
      expect(value.name.local, expected);
      return value;
    }
  }
  fail('$name is missing from the plist');
}

List<String> _stringsIn(XmlElement array) => array
    .findElements('string')
    .map((element) => element.innerText)
    .toList(growable: false);
