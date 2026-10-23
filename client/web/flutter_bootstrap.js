{{flutter_js}}
{{flutter_build_config}}

// Ship one renderer that works across browsers, including Safari and Firefox.
// FlutterWeb.targets embeds this variant and omits unused renderer binaries.
_flutter.loader.load({config: {canvasKitVariant: 'full'}});
