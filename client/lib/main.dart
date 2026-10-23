import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'data/app_controller.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // CanvasKit's default Chinese fallback downloads Google Fonts. Keep the
    // essential CJK font on the same host so normal Chinese UI needs no CDN.
    final loader = FontLoader('CodexLinkSans')
      ..addFont(_font('CodexLinkSans.woff2'));
    final mono = FontLoader('CodexLinkMono')
      ..addFont(_font('CodexLinkMono.woff2'));
    final symbols = FontLoader('CodexLinkSymbols')
      ..addFont(_font('CodexLinkSymbols.woff2'));
    final emoji = FontLoader('CodexLinkEmoji')
      ..addFont(_font('CodexLinkEmoji.woff2'));
    await Future.wait([
      loader.load(),
      mono.load(),
      symbols.load(),
      emoji.load(),
    ]);
  }
  runApp(CodexLinkApp(controller: AppController()));
}

Future<ByteData> _font(String name) async {
  final response = await http.get(Uri.base.resolve('/fonts/$name'));
  if (response.statusCode != 200) throw StateError('字体资源加载失败：$name');
  return ByteData.sublistView(response.bodyBytes);
}

class CodexLinkApp extends StatefulWidget {
  const CodexLinkApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<CodexLinkApp> createState() => _CodexLinkAppState();
}

class _CodexLinkAppState extends State<CodexLinkApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.foreground();
  }

  ThemeData theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff5865d8),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: kIsWeb ? 'CodexLinkSans' : null,
      fontFamilyFallback: kIsWeb
          ? const ['CodexLinkSans', 'CodexLinkSymbols', 'CodexLinkEmoji']
          : null,
      colorScheme: colors,
      brightness: brightness,
      scaffoldBackgroundColor: colors.surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(fontSize: 16, height: 1.55),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .5),
        thickness: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      title: 'CodexLink',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: widget.controller.dark ? ThemeMode.dark : ThemeMode.light,
      home: HomeScreen(controller: widget.controller),
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }
}
