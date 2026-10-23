import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

// Image context preserves CSS/SMIL animation while disabling SVG scripts and
// external subresources. Do not insert user SVG into the application's DOM.
class SvgPreview extends StatelessWidget {
  const SvgPreview({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    tagName: 'img',
    onElementCreated: (element) {
      final img = element as web.HTMLImageElement;
      img.src = 'data:image/svg+xml;base64,${base64Encode(bytes)}';
      img.alt = 'SVG 动画预览';
      img.style.width = '100%';
      img.style.height = '100%';
      img.style.objectFit = 'contain';
    },
  );
}
