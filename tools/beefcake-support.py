#!/usr/bin/env python3
"""Validate Umbra release bundles and update architecture-specific pins."""

import argparse
import base64
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit


SYSTEMS = ("x86_64-linux", "aarch64-linux")
RELEASE_FILES = {
    "bin/umbra-studio",
    "share/icons/hicolor/scalable/apps/umbra-studio.svg",
    "share/applications/umbra-studio.desktop",
    "share/licenses/umbra-studio/EULA.md",
}
NOTE_REQUIRED_FILES = {
    "bin/umbra-note",
    "lib/umbra-note/electron/electron",
    "lib/umbra-note/app/package.json",
    "share/icons/hicolor/512x512/apps/umbra-note.png",
    "share/applications/umbra-note.desktop",
}


def proxy_endpoint(value):
    """Accept an HTTP CONNECT endpoint, including lowercase usbproxy exports."""
    url = urlsplit(value if "://" in value else "http://" + value)
    if (url.scheme != "http" or not url.hostname or url.port is None
            or not 1 <= url.port <= 65535 or url.username is not None
            or url.password is not None or url.path not in ("", "/")
            or url.query or url.fragment
            or not re.fullmatch(r"[A-Za-z0-9._:\[\]-]+", url.netloc)):
        raise ValueError("proxy must be HTTP HOST:PORT without credentials, a path, or a query")
    return url.netloc


def daemon_dropin(endpoint):
    endpoint = proxy_endpoint(endpoint)
    value = "http://" + endpoint
    # proxy_endpoint excludes whitespace, quotes, percent signs, and backslashes,
    # so this is safe in systemd's Environment= syntax.
    lines = ["[Service]"]
    for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        lines.append(f'Environment="{name}={value}"')
    return "\n".join(lines) + "\n"


def audit(archive, system):
    """Inspect without extracting paths or executing the release binary."""
    expected_machine = {"x86_64-linux": 62, "aarch64-linux": 183}[system]
    forbidden = re.compile(rb"data-forensics|/home/[^\x00\s]*/UmbraStudio|/build/source")
    seen = set()
    size = 0
    with subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE) as process:
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as bundle:
                for member in bundle:
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or ".." in path.parts:
                        raise ValueError(f"unsafe archive path: {member.name}")
                    if member.isdir():
                        continue
                    name = str(path)
                    if not member.isfile() or name not in RELEASE_FILES or name in seen:
                        raise ValueError(f"unexpected, linked, or duplicate archive entry: {name}")
                    size += member.size
                    if size > 256 * 1024 * 1024:
                        raise ValueError("release bundle exceeds the 256 MiB audit limit")
                    seen.add(name)
                    contents = bundle.extractfile(member).read()
                    if forbidden.search(contents):
                        raise ValueError(f"private development material in {name}")
                    if name == "bin/umbra-studio":
                        if len(contents) < 64 or contents[:6] != b"\x7fELF\x02\x01":
                            raise ValueError("Studio must be a 64-bit little-endian ELF executable")
                        if struct.unpack_from("<H", contents, 18)[0] != expected_machine:
                            raise ValueError(f"Studio executable is not {system}")
                        if not member.mode & 0o111:
                            raise ValueError("Studio executable has no execute permission")
            # Finish consuming zstd so decompression/checksum errors are observed.
            if len(process.stdout.read(1024 * 1024 + 1)) > 1024 * 1024:
                raise ValueError("unexpected trailing archive data")
            if process.wait() != 0:
                raise ValueError("zstd decompression failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    if seen != RELEASE_FILES:
        raise ValueError(f"release bundle is missing: {sorted(RELEASE_FILES - seen)}")
    print(f"Audited source-free {system} bundle: {archive}")


def audit_note(archive, system):
    """Audit a self-contained Electron bundle without extracting it."""
    expected_machine = {"x86_64-linux": 62, "aarch64-linux": 183}[system]
    forbidden_suffixes = (".ts", ".tsx", ".map")
    seen = set()
    size = 0
    with subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE) as process:
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as bundle:
                for member in bundle:
                    path = PurePosixPath(member.name)
                    if path.is_absolute() or ".." in path.parts:
                        raise ValueError(f"unsafe archive path: {member.name}")
                    if member.isdir():
                        continue
                    name = str(path)
                    if name.startswith("./"):
                        name = name[2:]
                    if not (name == "bin/umbra-note" or name.startswith("lib/umbra-note/")
                            or name.startswith("share/applications/")
                            or name.startswith("share/icons/")):
                        raise ValueError(f"unexpected archive entry: {name}")
                    if name.endswith(forbidden_suffixes) or name.endswith("package-lock.json"):
                        raise ValueError(f"source or development file in release: {name}")
                    if member.isfile():
                        size += member.size
                        if size > 768 * 1024 * 1024:
                            raise ValueError("Umbra Note release exceeds the 768 MiB audit limit")
                        seen.add(name)
                        if name == "bin/umbra-note":
                            if member.size > 4096:
                                raise ValueError("Umbra Note launcher is unexpectedly large")
                            contents = bundle.extractfile(member).read()
                            if not contents.startswith(b"#!/bin/sh\n"):
                                raise ValueError("Umbra Note launcher must use portable /bin/sh")
                            if b"/nix/store/" in contents:
                                raise ValueError("Umbra Note launcher contains a producer Nix store path")
                            if not member.mode & 0o111:
                                raise ValueError("Umbra Note launcher has no execute permission")
                        elif name == "lib/umbra-note/electron/electron":
                            contents = bundle.extractfile(member).read(64)
                            if len(contents) < 64 or contents[:6] != b"\x7fELF\x02\x01":
                                raise ValueError("Umbra Note Electron runtime must be a 64-bit little-endian ELF")
                            if struct.unpack_from("<H", contents, 18)[0] != expected_machine:
                                raise ValueError(f"Umbra Note runtime is not {system}")
                            if not member.mode & 0o111:
                                raise ValueError("Umbra Note runtime has no execute permission")
                    elif not member.issym():
                        raise ValueError(f"unexpected archive member type: {name}")
            if process.wait() != 0:
                raise ValueError("zstd decompression failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    missing = NOTE_REQUIRED_FILES - seen
    if missing:
        raise ValueError(f"Umbra Note bundle is missing: {sorted(missing)}")
    print(f"Audited source-free Umbra Note {system} bundle: {archive}")


def pin(path, version, hashes):
    path = Path(path)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("invalid Studio version")
    if not hashes:
        raise ValueError("at least one system/hash pair is required")
    if any(system not in SYSTEMS for system in hashes):
        raise ValueError("unknown Studio system")
    text = path.read_text()
    for system, digest in hashes.items():
        if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", digest):
            raise ValueError(f"invalid SRI hash for {system}")
        if len(base64.b64decode(digest[7:], validate=True)) != 32:
            raise ValueError(f"invalid SHA-256 length for {system}")
        pattern = (
            r"(" + re.escape(system) + r"\s*=\s*\{\s*version\s*=\s*)"
            r'"\d+\.\d+\.\d+"(\s*;\s*hash\s*=\s*)'
            r'(?:"sha256-[A-Za-z0-9+/=]+"|lib\.fakeHash)(\s*;\s*\})'
        )
        text, count = re.subn(
            pattern,
            lambda match: (match[1] + '"' + version + '"' + match[2]
                           + '"' + digest + '"' + match[3]),
            text,
        )
        if count != 1:
            raise ValueError(f"expected exactly one release block for {system}")
    # Validate every requested replacement before replacing the file.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(text)
        temporary.chmod(path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    proxy_parser = commands.add_parser("proxy-endpoint")
    proxy_parser.add_argument("value")
    daemon_parser = commands.add_parser("daemon-dropin")
    daemon_parser.add_argument("endpoint")
    audit_parser = commands.add_parser("audit")
    audit_parser.add_argument("archive", type=Path)
    audit_parser.add_argument("system", choices=SYSTEMS)
    note_audit_parser = commands.add_parser("audit-note")
    note_audit_parser.add_argument("archive", type=Path)
    note_audit_parser.add_argument("system", choices=SYSTEMS)
    pin_parser = commands.add_parser("pin")
    pin_parser.add_argument("path", type=Path)
    pin_parser.add_argument("version")
    pin_parser.add_argument("release", nargs="+", metavar="SYSTEM_OR_HASH")
    args = parser.parse_args()
    try:
        if args.command == "audit":
            audit(args.archive, args.system)
        elif args.command == "audit-note":
            audit_note(args.archive, args.system)
        elif args.command == "pin":
            if len(args.release) % 2:
                raise ValueError("pin requires SYSTEM HASH pairs")
            hashes = dict(zip(args.release[::2], args.release[1::2], strict=True))
            if len(hashes) != len(args.release) // 2:
                raise ValueError("duplicate Studio system")
            pin(args.path, args.version, hashes)
        elif args.command == "proxy-endpoint":
            print(proxy_endpoint(args.value))
        else:
            print(daemon_dropin(args.endpoint), end="")
    except (ValueError, OSError, tarfile.TarError) as error:
        parser.exit(1, f"BEEFCAKE: {error}\n")


if __name__ == "__main__":
    main()
