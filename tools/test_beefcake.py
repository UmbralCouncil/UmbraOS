#!/usr/bin/env python3
"""Release orchestration tests: real files/hashes/audits, simulated external services."""

import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("beefcake_support", TOOLS / "beefcake-support.py")
SUPPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUPPORT)

MOCK = r'''#!/usr/bin/env python3
import base64, hashlib, json, os, pathlib, shutil, sys, urllib.parse
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["BEEFCAKE_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([command, args, os.environ.get("BEEFCAKE_PROBE_SYSTEM")]) + "\n")
fail = os.environ.get("BEEFCAKE_TEST_FAIL", "")
if command == "nix":
    if "hash" in args:
        print("sha256-" + base64.b64encode(hashlib.sha256(pathlib.Path(args[-1]).read_bytes()).digest()).decode())
    elif "build" in args:
        if "--expr" in args:
            sys.exit(1 if fail == "probe:" + os.environ["BEEFCAKE_PROBE_SYSTEM"] else 0)
        target = next(x for x in args if "#" in x)
        system = "aarch64-linux" if "aarch64-linux" in target else "x86_64-linux"
        if "release-bundle" in target:
            if fail == "studio:" + system: sys.exit(1)
            source_system = "x86_64-linux" if fail == "wrong-architecture" else system
            output = pathlib.Path(args[args.index("-o") + 1])
            output.unlink(missing_ok=True)
            output.symlink_to(root / (source_system + ".tar.zst"))
        elif target.endswith(".iso"):
            if fail == "iso:" + system: sys.exit(1)
            output = pathlib.Path(args[args.index("-o") + 1]) / "iso"
            output.mkdir(parents=True, exist_ok=True)
            (output / (system + ".iso")).write_bytes(b"test ISO " + system.encode())
        elif "umbraIsoSizeCheck" in target:
            if fail == "size:" + system: sys.exit(1)
        else: sys.exit("unexpected build target: " + target)
    else: sys.exit("unexpected nix invocation")
elif command == "gh":
    if args[:2] == ["release", "view"]:
        if not os.environ.get("BEEFCAKE_TEST_EXISTING"): sys.exit(1)
        if "--json" in args:
            assets = os.environ.get("BEEFCAKE_TEST_EXISTING_ASSETS")
            if assets is None:
                assets = ",".join(
                    f"umbra-studio-{system}.tar.zst{suffix}"
                    for system in ("x86_64-linux", "aarch64-linux")
                    for suffix in ("", ".sha256")
                )
            print("\n".join(filter(None, assets.split(","))))
        sys.exit(0)
    if args[:2] in (["release", "create"], ["release", "upload"]):
        for arg in args:
            path = pathlib.Path(arg)
            if path.is_file(): shutil.copy2(path, root / "remote" / path.name)
elif command == "curl":
    url = next(x for x in args if x.startswith("https://"))
    name = pathlib.PurePosixPath(urllib.parse.urlsplit(url).path).name
    data = (root / "remote" / name).read_bytes()
    if fail == "download:aarch64-linux" and "aarch64" in name: data += b"corruption"
    pathlib.Path(args[args.index("--output") + 1]).write_bytes(data)
elif command == "rsync":
    for arg in args:
        if arg.endswith(".iso") or arg.endswith(".sha256"):
            assert pathlib.Path(arg).is_file(), arg
elif command == "date":
    print("20260910" if args == ["+%Y%m%d"] else "1789000000")
elif command not in ("git", "ssh", "nix-instantiate"):
    sys.exit("unexpected mock: " + command)
'''


def make_archive(path, machine=183, extra=None):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", header, 18, machine)
    entries = {name: b"release asset" for name in SUPPORT.RELEASE_FILES}
    entries["bin/umbra-studio"] = bytes(header)
    entries.update(extra or {})
    with tempfile.TemporaryFile() as raw:
        with tarfile.open(fileobj=raw, mode="w") as tar:
            for name, data in entries.items():
                member = tarfile.TarInfo("./" + name)
                member.mode = 0o755 if name == "bin/umbra-studio" else 0o644
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        raw.seek(0)
        with path.open("wb") as output:
            subprocess.run(["zstd", "-q", "-c"], stdin=raw, stdout=output, check=True)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beefcake-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.os = self.root / "Umbra OS"
        self.studio = self.root / "Umbra Studio"
        for directory in [self.os / ".git", self.studio / ".git", self.root / "bin", self.root / "remote"]:
            directory.mkdir(parents=True)
        self.pin = self.os / "modules/studio/package.nix"
        self.pin.parent.mkdir(parents=True)
        shutil.copy2(TOOLS.parent / "modules/studio/package.nix", self.pin)
        files = {
            "crates/umbra-gui/Cargo.toml": 'version = "0.1.9"\n',
            "flake.nix": 'version = "0.1.9";\n"umbra-studio-0.1.9-${system}.tar.zst"\n',
            "crates/umbra-gui/ui/app.slint": '"Umbra Studio 0.1.9"\n',
            "crates/umbra-gui/src/model_store.rs": '"UmbraStudio/0.1.9"\n',
            "Cargo.lock": '[[package]]\nname = "umbra-studio-native"\nversion = "0.1.9"\n',
        }
        for name, contents in files.items():
            path = self.studio / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        for system, machine in [("x86_64-linux", 62), ("aarch64-linux", 183)]:
            make_archive(self.root / (system + ".tar.zst"), machine)
        for command in ["git", "gh", "nix", "curl", "rsync", "ssh", "nix-instantiate", "date"]:
            path = self.root / "bin" / command
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        UMBRA_OS_DIR=str(self.os), UMBRA_STUDIO_DIR=str(self.studio),
                        BEEFCAKE_TEST_ROOT=str(self.root), UMBRA_BUILDERS="",
                        UMBRA_BUILD_JOBS="auto", UMBRA_BUILD_CORES="0")
        for name in ("http_proxy", "https_proxy", "ftp_proxy", "ssl_proxy", "all_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "SSL_PROXY", "ALL_PROXY"):
            self.env.pop(name, None)

    def run_release(self, *extra, fail="", check=False):
        args = [str(TOOLS / "beefcake")]
        if check:
            args += ["--check-builders"]
        else:
            args += ["--version", "0.2.0", "--tag", "studio-v0.2.0", "--no-proxy", "--yes"]
        return subprocess.run(args + list(extra), env=dict(self.env, BEEFCAKE_TEST_FAIL=fail),
                              text=True, capture_output=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def publications(self):
        return [args for command, args, _ in self.calls()
                if command == "gh" and args[:2] in (["release", "create"], ["release", "upload"])]

    def seed_existing_release(self, asset_names=None):
        if asset_names is None:
            asset_names = [
                f"umbra-studio-{system}.tar.zst{suffix}"
                for system in SUPPORT.SYSTEMS
                for suffix in ("", ".sha256")
            ]
        remote = self.root / "remote"
        for name in asset_names:
            target = remote / name
            system = next(system for system in SUPPORT.SYSTEMS if system in name)
            source = self.root / f"{system}.tar.zst"
            if name.endswith(".sha256"):
                digest = hashlib.sha256(source.read_bytes()).hexdigest()
                target.write_text(f"{digest}  {name.removesuffix('.sha256')}\n")
            else:
                shutil.copy2(source, target)

    def test_full_release_pins_and_uploads_both_architectures(self):
        # Re-running the same version must replace Nix-style read-only local
        # archives left by an interrupted release.
        dist = self.studio / "dist"
        dist.mkdir()
        stale = dist / "umbra-studio-0.2.0-x86_64-linux.tar.zst"
        stale.write_bytes(b"stale")
        stale.chmod(0o444)
        result = self.run_release("--builders", "ssh-ng://builder@arm aarch64-linux", "--jobs", "1", "--cores", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.publications()), 1)
        assets = [x.name for x in (self.root / "remote").iterdir()]
        self.assertEqual(len(assets), 4)
        for system in SUPPORT.SYSTEMS:
            archive = self.root / "remote" / f"umbra-studio-{system}.tar.zst"
            expected = "sha256-" + base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
            self.assertIn(expected, self.pin.read_text())
            iso = self.os / f"UmbraOS-26.05-20260910-{system}.iso"
            self.assertTrue(iso.exists())
            self.assertIn(hashlib.sha256(iso.read_bytes()).hexdigest(), Path(str(iso) + ".sha256").read_text())
        uploads = [args for command, args, _ in self.calls() if command == "rsync"]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(len([arg for arg in uploads[0] if arg.endswith((".iso", ".sha256"))]), 4)
        for command, args, _ in self.calls():
            if command == "nix" and "build" in args:
                self.assertEqual(args[args.index("--builders") + 1], "ssh-ng://builder@arm aarch64-linux")
                self.assertEqual(args[args.index("--cores") + 1], "2")
                self.assertEqual(args[args.index("--max-jobs") + 1], "1")
        self.assertNotIn("lib.fakeHash", self.pin.read_text())
        self.assertNotEqual(stale.read_bytes(), b"stale")

    def test_builder_check_has_no_release_side_effects(self):
        before = self.pin.read_bytes()
        result = self.run_release(check=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([system for command, _, system in self.calls() if command == "nix"], list(SUPPORT.SYSTEMS))
        self.assertEqual(before, self.pin.read_bytes())
        self.assertFalse(self.publications())

    def test_missing_arm_builder_stops_before_versions_change(self):
        before = (self.studio / "flake.nix").read_bytes()
        result = self.run_release(fail="probe:aarch64-linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aarch64-linux builder unavailable", result.stderr)
        self.assertEqual(before, (self.studio / "flake.nix").read_bytes())
        self.assertFalse(self.publications())

    def test_second_studio_build_failure_does_not_publish_first(self):
        result = self.run_release(fail="studio:aarch64-linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.publications())

    def test_wrong_architecture_is_not_published(self):
        result = self.run_release(fail="wrong-architecture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not aarch64-linux", result.stderr)
        self.assertFalse(self.publications())

    def test_bad_arm_download_does_not_update_either_pin(self):
        before = self.pin.read_bytes()
        result = self.run_release(fail="download:aarch64-linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.pin.read_bytes())
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

    def test_iso_failure_does_not_upload_partial_pair(self):
        for stage in ["iso:aarch64-linux", "size:aarch64-linux"]:
            with self.subTest(stage=stage):
                result = self.run_release(fail=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

    def test_existing_release_and_filename_collision(self):
        self.env["BEEFCAKE_TEST_EXISTING"] = "1"
        self.seed_existing_release()
        existing = self.os / "UmbraOS-26.05-20260910-aarch64-linux.iso"
        existing.write_bytes(b"previous release")
        result = self.run_release("--skip-sourceforge")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.publications())
        self.assertEqual(existing.read_bytes(), b"previous release")
        for system in SUPPORT.SYSTEMS:
            self.assertTrue((self.os / f"UmbraOS-26.05-20260910v2-{system}.iso").exists())
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

    def test_existing_release_uploads_only_missing_studio_assets(self):
        self.env["BEEFCAKE_TEST_EXISTING"] = "1"
        existing_assets = [
            "umbra-studio-x86_64-linux.tar.zst",
            "umbra-studio-x86_64-linux.tar.zst.sha256",
            "umbra-studio-aarch64-linux.tar.zst",
        ]
        self.env["BEEFCAKE_TEST_EXISTING_ASSETS"] = ",".join(existing_assets)
        self.seed_existing_release(existing_assets)
        result = self.run_release("--skip-sourceforge")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        publications = self.publications()
        self.assertEqual(len(publications), 1)
        self.assertEqual(publications[0][:2], ["release", "upload"])
        uploaded = [Path(arg).name for arg in publications[0]
                    if Path(arg).name.startswith("umbra-studio-")]
        self.assertEqual(uploaded, ["umbra-studio-aarch64-linux.tar.zst.sha256"])
        self.assertNotIn("--clobber", publications[0])

    def test_continue_sourceforge_resumes_newest_complete_iso_pair_only(self):
        older = "UmbraOS-26.05-20260909"
        newest = "UmbraOS-26.05-20260910"
        for prefix in (older, newest):
            for system in SUPPORT.SYSTEMS:
                iso = self.os / f"{prefix}-{system}.iso"
                iso.write_bytes(f"{prefix} {system}".encode())
                digest = hashlib.sha256(iso.read_bytes()).hexdigest()
                Path(str(iso) + ".sha256").write_text(f"{digest}  {iso.name}\n")

        result = subprocess.run(
            [str(TOOLS / "beefcake"), "--continue-sourceforge", "--no-proxy"],
            env=self.env, text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uploads = [args for command, args, _ in self.calls() if command == "rsync"]
        self.assertEqual(len(uploads), 1)
        uploaded = [Path(arg).name for arg in uploads[0] if arg.endswith((".iso", ".sha256"))]
        self.assertEqual(len(uploaded), 4)
        self.assertTrue(all(name.startswith(newest) for name in uploaded))
        self.assertFalse(any(command in ("nix", "gh", "curl") for command, _, _ in self.calls()))

    def test_pin_failure_is_atomic(self):
        self.pin.write_text(self.pin.read_text().replace("aarch64-linux =", "missing-arm ="))
        before = self.pin.read_bytes()
        digest = "sha256-" + base64.b64encode(bytes(32)).decode()
        with self.assertRaisesRegex(ValueError, "aarch64-linux"):
            SUPPORT.pin(self.pin, "0.2.0", [digest, digest])
        self.assertEqual(before, self.pin.read_bytes())

    def test_audit_rejects_source_material(self):
        archive = self.root / "bad.tar.zst"
        make_archive(archive, extra={"src/main.rs": b"private source"})
        with self.assertRaisesRegex(ValueError, "unexpected"):
            SUPPORT.audit(archive, "aarch64-linux")

    def test_usbproxy_endpoint_forms_are_normalized(self):
        self.assertEqual(SUPPORT.proxy_endpoint("172.31.134.127:8228"), "172.31.134.127:8228")
        self.assertEqual(SUPPORT.proxy_endpoint("http://172.31.134.127:8228"), "172.31.134.127:8228")
        for value in ("https://proxy.test:8228", "http://user:pass@proxy.test:8228",
                      "http://proxy.test:8228/path", "proxy.test", "proxy.test:70000"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                SUPPORT.proxy_endpoint(value)

    def test_daemon_dropin_sets_both_proxy_casings(self):
        dropin = SUPPORT.daemon_dropin("172.31.134.127:8228")
        self.assertTrue(dropin.startswith("[Service]\n"))
        for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
            self.assertIn(f'Environment="{name}=http://172.31.134.127:8228"', dropin)


if __name__ == "__main__":
    unittest.main()
