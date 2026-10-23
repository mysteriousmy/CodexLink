# Third-party notices

CodexLink's own code is licensed under the MIT license in `LICENSE`. Third-party components retain their respective licenses. CodexLink is an independent project and is not an official OpenAI product. Codex is installed and authenticated separately; it is not included in these packages.

| Component | License / notices |
| --- | --- |
| .NET runtime and ASP.NET Core | MIT; upstream: https://github.com/dotnet/runtime and https://github.com/dotnet/aspnetcore |
| musl (static Linux C runtime) | MIT; `licenses/musl-COPYRIGHT.txt` in server archives |
| OpenSSL (static Linux cryptography) | Apache License 2.0; `licenses/OpenSSL-LICENSE.txt` |
| zlib | zlib license; `licenses/zlib-LICENSE.txt` |
| GCC runtime components | GPLv3 with GCC Runtime Library Exception; `licenses/GPLv3.txt` and `GCC-RUNTIME-EXCEPTION.txt` |
| StuDev.AotAnywhere (build tool) | MIT; https://github.com/StuDevLabs/AotAnywhere |
| Flutter and Dart | BSD-style licenses; the generated Flutter `assets/NOTICES` contains bundled dependency notices |
| CanvasKit / Skia | BSD-style and component licenses, included in Flutter's generated notices |
| Roboto | Apache License 2.0; `client/assets/fonts/Roboto_LICENSE.txt` in source, `licenses/Roboto_LICENSE.txt` in server archives |
| Noto CJK, Noto Sans Mono, Noto Symbols 2 and Noto Emoji | SIL Open Font License 1.1; `client/web/fonts/OFL.txt` and `README.txt` in source, `licenses/Noto_OFL.txt` and `Noto_README.txt` in archives |
| UPX (build tool and executable decompression stub) | GPL with special exception for compressed executables; https://github.com/upx/upx/blob/devel/LICENSE |

The UPX exception allows distributing compressed executables under their original licenses. The UPX build tool itself is not bundled. Windows ARM64 executables are not UPX-packed because UPX does not support ARM64 PE.

Server archives also include `licenses/Flutter-NOTICES.txt`, generated from the actual Flutter build. The same notice file is embedded in the web application at `/assets/NOTICES`; Android packages contain Flutter's generated notices.

Full notices for the native runtime/toolchain are kept in `deploy/licenses/` in source and `licenses/` in server packages. These include .NET third-party notices and the UPX exception. Not every component is linked on every platform; the Linux static packages include musl and OpenSSL.
