#!/usr/bin/env python3
"""Build Native AOT/embedded-web archives and signed Android APKs locally."""

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RIDS = ('linux-musl-x64', 'linux-musl-arm64', 'win-x64', 'win-arm64')


def run(*args, cwd=ROOT):
    print('+', ' '.join(map(str, args)), flush=True)
    command = [str(a) for a in args]
    command[0] = shutil.which(command[0]) or command[0]
    subprocess.run(command, cwd=cwd, check=True)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_static(binary):
    # Inspect the actual ELF, including after UPX: neither a loader nor a shared
    # library is allowed in a Linux release. ldd alone can hide dlopen fallbacks.
    headers = subprocess.check_output(['readelf', '-l', str(binary)], text=True)
    dynamic = subprocess.check_output(['readelf', '-d', str(binary)], text=True)
    if 'INTERP' in headers or '(NEEDED)' in dynamic:
        raise RuntimeError(f'{binary}: Linux release must be fully static')
    result = subprocess.run(['ldd', str(binary)], capture_output=True, text=True)
    print('ldd:', (result.stdout + result.stderr).strip(), flush=True)


def publish_musl(rid, publish, version, web):
    arch = 'amd64' if rid.endswith('-x64') else 'arm64'
    image = 'codexlink-musl-build:' + arch
    run('docker', 'build', '--platform', 'linux/' + arch, '-t', image,
        '--build-arg', f'BUILD_UID={os.getuid() if hasattr(os, "getuid") else 1000}',
        '--build-arg', f'BUILD_GID={os.getgid() if hasattr(os, "getgid") else 1000}',
        '-f', ROOT / 'scripts/Dockerfile.musl', ROOT / 'scripts')
    # Mount a minimal build-only source tree. No host home, tokens, Android key,
    # production state, or unrelated workspace data is visible in the container.
    source = ROOT / '.local' / f'musl-source-{rid}'
    source.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'server/CodexLink.Server', source / 'server/CodexLink.Server',
                    dirs_exist_ok=True, ignore=shutil.ignore_patterns('bin', 'obj'))
    settings = json.loads((ROOT / 'global.json').read_text())
    settings['sdk']['version'] = '10.0.402'  # SDK in the pinned Alpine image
    (source / 'global.json').write_text(json.dumps(settings, indent=2) + '\n')
    cache = ROOT / '.local' / ('musl-nuget-' + arch)
    cache.mkdir(parents=True, exist_ok=True)
    publish.mkdir(parents=True, exist_ok=True)
    command = ['docker', 'run', '--rm', '--platform', 'linux/' + arch,
               '--mount', f'type=bind,src={source},dst=/src',
               '--mount', f'type=bind,src={web},dst=/web,readonly',
               '--mount', f'type=bind,src={publish},dst=/out',
               '--mount', f'type=bind,src={cache},dst=/tmp/nuget',
               '-e', 'NUGET_PACKAGES=/tmp/nuget', '-e', 'DOTNET_CLI_HOME=/tmp/dotnet']
    if hasattr(os, 'getuid'):
        command += ['--user', f'{os.getuid()}:{os.getgid()}']
    emulated_arm = arch == 'arm64' and platform.machine().lower() not in ('aarch64', 'arm64')
    if emulated_arm:
        # Avoid Native AOT compiler/thread-pool races under user-mode QEMU.
        # This limits only the build process, never the shipped server.
        command += ['-e', 'DOTNET_PROCESSOR_COUNT=1']
    command += [image, 'dotnet', 'publish', '/src/server/CodexLink.Server', '-c', 'Release',
                '-r', rid, '-p:UseNativeAotToolchain=true', '-p:PrebuiltFlutterWebDirectory=/web',
                '-p:Version=' + version, '-o', '/out']
    if emulated_arm:
        command += ['-p:IlcSingleThreaded=true']
    run(*command)
    verify_static(publish / 'CodexLink.Server')


def package_server(rid, publish, output, version, use_upx, web=None):
    archive_rid = rid.replace('linux-musl-', 'linux-').replace('win-', 'windows-')
    name = f'CodexLink-v{version}-{archive_rid}'
    executable = 'CodexLink.Server.exe' if rid.startswith('win-') else 'CodexLink.Server'
    with tempfile.TemporaryDirectory(prefix='codexlink-package-') as temp:
        stage = Path(temp) / name
        stage.mkdir()
        binary = stage / executable
        shutil.copyfile(publish / executable, binary)
        binary.chmod(0o755)
        unpacked = binary.stat().st_size
        compressed = use_upx and rid != 'win-arm64'
        if compressed:
            run('upx', '--best', '--lzma', binary)
            run('upx', '-t', binary)
        elif use_upx:
            print('win-arm64: keeping Native AOT PE uncompressed (UPX format unsupported).', flush=True)
        if rid.startswith('linux-musl-'):
            verify_static(binary)
        # An allowlist keeps real host configuration, tokens, logs, symbols and
        # signing material out of the release even when present in the workspace.
        for source, target in [
            ('deploy/README.md', 'README.md'),
            ('deploy/README.zh-CN.md', 'README.zh-CN.md'),
            ('deploy/config.example.json', 'config.example.json'),
            ('deploy/devices.example.json', 'devices.example.json'),
            ('deploy/access-token.example.txt', 'access-token.example.txt'),
            ('LICENSE', 'LICENSE'),
            ('THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md'),
            ('client/assets/fonts/Roboto_LICENSE.txt', 'licenses/Roboto_LICENSE.txt'),
            ('client/web/fonts/OFL.txt', 'licenses/Noto_OFL.txt'),
            ('client/web/fonts/README.txt', 'licenses/Noto_README.txt'),
        ]:
            target_path = stage / target
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, target_path)
        shutil.copytree(ROOT / 'deploy/licenses', stage / 'licenses', dirs_exist_ok=True)
        web = web or ROOT / f'server/CodexLink.Server/obj/Release/net10.0/{rid}/flutter-web'
        shutil.copyfile(web / 'assets/NOTICES', stage / 'licenses/Flutter-NOTICES.txt')
        if rid.startswith('linux-'):
            for service in ('codexlink.service', 'codexlink.system.service', 'install-systemd.sh'):
                shutil.copyfile(ROOT / 'deploy' / service, stage / service)
                (stage / service).chmod(0o755 if service.endswith('.sh') else 0o644)
        info = {
            'version': version, 'runtimeIdentifier': rid, 'nativeAot': True,
            'embeddedWeb': True, 'optimizationPreference': 'Size',
            'staticExecutable': rid.startswith('linux-musl-'),
            'invariantGlobalization': rid.startswith('linux-musl-'),
            'upx': compressed, 'uncompressedBytes': unpacked,
            'executableBytes': binary.stat().st_size, 'sha256': digest(binary),
            'notes': 'UPX has no ARM64 PE support' if use_upx and rid == 'win-arm64' else None,
        }
        (stage / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
        suffix = '.zip' if rid.startswith('win-') else '.tar.gz'
        archive = output / (name + suffix)
        temporary = archive.with_suffix(archive.suffix + '.tmp')
        if suffix == '.zip':
            with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as packed:
                for file in sorted(stage.rglob('*')):
                    if file.is_file():
                        packed.write(file, file.relative_to(stage.parent).as_posix())
        else:
            def public_metadata(entry):
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = ''
                return entry
            with tarfile.open(temporary, 'w:gz', compresslevel=9) as packed:
                packed.add(stage, arcname=name, filter=public_metadata)
        os.replace(temporary, archive)
        print(f'{archive.name}: binary {unpacked:,} -> {binary.stat().st_size:,} bytes; archive {archive.stat().st_size:,} bytes', flush=True)
        return archive, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--all', action='store_true', help='Build all four server targets')
    parser.add_argument('--rids', nargs='+', choices=RIDS, default=['linux-musl-x64'])
    parser.add_argument('--android', action='store_true', help='Build signed ARM64, ARMv7, x86_64 and universal APKs')
    parser.add_argument('--skip-checks', action='store_true', help='Skip Flutter analyze/tests already run for this source')
    parser.add_argument('--no-upx', action='store_true', help='Keep every executable uncompressed')
    parser.add_argument('--version', help='Release version; defaults to client/pubspec.yaml')
    args = parser.parse_args()
    version = args.version or re.search(r'^version:\s*([^+\s]+)', (ROOT / 'client/pubspec.yaml').read_text(), re.M)[1]
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        parser.error('Use a semantic version without a leading v.')
    rids = RIDS if args.all else tuple(dict.fromkeys(args.rids))
    if not args.no_upx and any(r != 'win-arm64' for r in rids) and not shutil.which('upx'):
        parser.error('Install UPX, or explicitly use --no-upx.')
    client = ROOT / 'client'
    run('flutter', '--no-version-check', 'pub', 'get', cwd=client)
    if not args.skip_checks:
        run('flutter', '--no-version-check', 'analyze', cwd=client)
        run('flutter', '--no-version-check', 'test', cwd=client)
    output = ROOT / 'artifacts' / f'v{version}'
    output.mkdir(parents=True, exist_ok=True)
    assets, builds = [], []
    web = ROOT / '.local' / f'release-v{version}' / 'flutter-web'
    run('flutter', '--no-version-check', 'build', 'web', '--release',
        '--no-web-resources-cdn', '--output', web, cwd=client)
    for rid in rids:
        publish = ROOT / '.local' / f'release-v{version}' / rid
        if rid.startswith('linux-musl-'):
            publish_musl(rid, publish, version, web)
        else:
            run('dotnet', 'publish', ROOT / 'server/CodexLink.Server', '-c', 'Release', '-r', rid,
                '-p:Version=' + version, '-p:PrebuiltFlutterWebDirectory=' + str(web), '-o', publish)
        archive, info = package_server(rid, publish, output, version, not args.no_upx, web)
        assets.append(archive)
        builds.append(info)
    if args.android:
        run(os.sys.executable, ROOT / 'scripts/prepare-android-signing.py')
        run('flutter', '--no-version-check', 'build', 'apk', '--release', '--split-per-abi', '--no-pub', '--build-name=' + version, cwd=client)
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
            source = client / f'build/app/outputs/flutter-apk/app-{abi}-release.apk'
            target = output / f'CodexLink-v{version}-android-{abi}.apk'
            shutil.copyfile(source, target)
            assets.append(target)
        run('flutter', '--no-version-check', 'build', 'apk', '--release', '--no-pub', '--build-name=' + version, cwd=client)
        target = output / f'CodexLink-v{version}-android-universal.apk'
        shutil.copyfile(client / 'build/app/outputs/flutter-apk/app-release.apk', target)
        assets.append(target)
    # Hash every finished asset in this version directory, including targets built
    # by a previous explicit --rids invocation. Never include old debug binaries.
    assets = sorted(p for p in output.iterdir() if p.name.endswith(('.tar.gz', '.zip', '.apk')))
    (output / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in assets), encoding='ascii')
    print('Release assets:', output, flush=True)


if __name__ == '__main__':
    main()
