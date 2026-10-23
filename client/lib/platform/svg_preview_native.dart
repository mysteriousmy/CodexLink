import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SvgPreview extends StatefulWidget {
  const SvgPreview({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<SvgPreview> createState() => _SvgPreviewState();
}

class _SvgPreviewState extends State<SvgPreview> {
  WebViewController? _web;
  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) => request.url == 'about:blank'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
          ),
        )
        ..loadHtmlString(
          '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'"><style>html,body{margin:0;width:100%;height:100%;background:transparent}img{width:100%;height:100%;object-fit:contain}</style><img src="data:image/svg+xml;base64,${base64Encode(widget.bytes)}" alt="SVG 动画预览">',
        );
    }
  }

  @override
  Widget build(BuildContext context) => _web == null
      ? const Center(child: Text('请下载后在浏览器打开 SVG 动画。'))
      : WebViewWidget(controller: _web!);
}
