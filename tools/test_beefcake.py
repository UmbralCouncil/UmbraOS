#!/usr/bin/env python3
"""Release orchestration tests: real files/hashes/audits, simulated external services."""

import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
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
            is_note = "Umbra Note" in target
            product = "note" if is_note else "studio"
            if fail == product + ":" + system: sys.exit(1)
            source_system = "x86_64-linux" if fail == "wrong-architecture" else system
            output = pathlib.Path(args[args.index("-o") + 1])
            output.unlink(missing_ok=True)
            output.symlink_to(root / (("note-" if is_note else "") + source_system + ".tar.zst"))
        elif target.endswith(".iso"):
            if fail == "iso:" + system: sys.exit(1)
            output = pathlib.Path(args[args.index("-o") + 1]) / "iso"
            output.mkdir(parents=True, exist_ok=True)
            (output / (system + ".iso")).write_bytes(b"test ISO " + system.encode())
        else: sys.exit("unexpected build target: " + target)
    else: sys.exit("unexpected nix invocation")
elif command == "gh":
    if args[:2] == ["release", "view"]:
        if not os.environ.get("BEEFCAKE_TEST_EXISTING"): sys.exit(1)
        if "--json" in args:
            repo = args[args.index("--repo") + 1]
            assets = os.environ.get("BEEFCAKE_TEST_NOTE_EXISTING_ASSETS" if repo.endswith("UmbraNote")
                                    else "BEEFCAKE_TEST_EXISTING_ASSETS")
            if assets is None:
                prefix = "umbra-note" if repo.endswith("UmbraNote") else "umbra-studio"
                assets = ",".join(
                    f"{prefix}-{system}.tar.zst{suffix}"
                    for system in ("x86_64-linux", "aarch64-linux")
                    for suffix in ("", ".sha256")
                )
            print("\n".join(filter(None, assets.split(","))))
        sys.exit(0)
    if args[:2] in (["release", "create"], ["release", "upload"]):
        for arg in args:
            path = pathlib.Path(arg)
            if path.is_file(): shutil.copy2(path, root / "remote" / path.name)
elif command == "git":
    if args[-2:] == ["branch", "--show-current"]:
        print("main")
    elif args[-3:] == ["diff", "--cached", "--quiet"]:
        sys.exit(1 if os.environ.get("BEEFCAKE_TEST_GIT_DIRTY") else 0)
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


def make_note_archive(path, machine=183, launcher=b"#!/bin/sh\nexec true\n"):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", header, 18, machine)
    entries = {name: b"release asset" for name in SUPPORT.NOTE_REQUIRED_FILES}
    entries["bin/umbra-note"] = launcher
    entries["lib/umbra-note/electron/electron"] = bytes(header)
    with tempfile.TemporaryFile() as raw:
        with tarfile.open(fileobj=raw, mode="w") as tar:
            for name, data in entries.items():
                member = tarfile.TarInfo("./" + name)
                member.mode = 0o755 if name in ("bin/umbra-note", "lib/umbra-note/electron/electron") else 0o644
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        raw.seek(0)
        with path.open("wb") as output:
            subprocess.run(["zstd", "-q", "-c"], stdin=raw, stdout=output, check=True)


class NoteAuditTests(unittest.TestCase):
    def test_accepts_portable_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "note.tar.zst"
            make_note_archive(archive)
            SUPPORT.audit_note(archive, "aarch64-linux")

    def test_rejects_producer_store_shebang(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "note.tar.zst"
            make_note_archive(
                archive,
                launcher=b"#!/nix/store/deadbeef-bash/bin/sh\nexec true\n",
            )
            with self.assertRaisesRegex(ValueError, "portable /bin/sh"):
                SUPPORT.audit_note(archive, "aarch64-linux")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beefcake-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.os = self.root / "Umbra OS"
        self.studio = self.root / "Umbra Studio"
        self.note = self.root / "Umbra Note"
        self.api = self.root / "umbra-api"
        for directory in [self.os / ".git", self.studio / ".git", self.note / ".git", self.api / ".git",
                          self.root / "bin", self.root / "remote"]:
            directory.mkdir(parents=True)
        self.pin = self.os / "modules/studio/package.nix"
        self.pin.parent.mkdir(parents=True)
        shutil.copy2(TOOLS.parent / "modules/studio/package.nix", self.pin)
        self.note_pin = self.os / "modules/note/package.nix"
        self.note_pin.parent.mkdir(parents=True)
        shutil.copy2(TOOLS.parent / "modules/note/package.nix", self.note_pin)
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
        (self.note / "package.json").write_text('{"name":"umbra-note","version":"0.1.9"}\n')
        (self.note / "package-lock.json").write_text('{"name":"umbra-note","version":"0.1.9","packages":{"":{"version":"0.1.9"}}}\n')
        (self.note / "flake.nix").write_text('version = "0.1.9";\n"umbra-note-${version}-${system}.tar.zst"\n')
        for system, machine in [("x86_64-linux", 62), ("aarch64-linux", 183)]:
            make_archive(self.root / (system + ".tar.zst"), machine)
            make_note_archive(self.root / ("note-" + system + ".tar.zst"), machine)
        for command in ["git", "gh", "nix", "curl", "rsync", "ssh", "nix-instantiate", "date"]:
            path = self.root / "bin" / command
            path.write_text(MOCK)
            path.chmod(0o755)
        attach_iso = self.os / "attach-iso.sh"
        attach_iso.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "root = pathlib.Path(os.environ['BEEFCAKE_TEST_ROOT'])\n"
            "with (root / 'calls.jsonl').open('a') as f:\n"
            "    f.write(json.dumps(['attach-iso.sh', sys.argv[1:], None]) + '\\n')\n"
            "sys.exit(1 if os.environ.get('BEEFCAKE_TEST_FAIL') == 'attach' else 0)\n"
        )
        attach_iso.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        UMBRA_OS_DIR=str(self.os), UMBRA_STUDIO_DIR=str(self.studio),
                        UMBRA_NOTE_DIR=str(self.note),
                        UMBRA_API_DIR=str(self.api),
                        BEEFCAKE_TEST_ROOT=str(self.root), UMBRA_BUILDERS="",
                        UMBRA_BUILD_JOBS="auto", UMBRA_BUILD_CORES="0")
        for name in ("http_proxy", "https_proxy", "ftp_proxy", "ssl_proxy", "all_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "FTP_PROXY", "SSL_PROXY", "ALL_PROXY"):
            self.env.pop(name, None)

    def run_release(self, *extra, fail="", check=False, input_text=None):
        args = [str(TOOLS / "beefcake")]
        if check:
            args += ["--check-builders"]
        else:
            args += ["--version", "0.2.0", "--tag", "studio-v0.2.0",
                     "--note-version", "0.0.1", "--note-tag", "v0.0.1",
                     "--no-proxy", "--yes"]
        return subprocess.run(args + list(extra), env=dict(self.env, BEEFCAKE_TEST_FAIL=fail),
                              input=input_text, text=True, capture_output=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def publications(self):
        return [args for command, args, _ in self.calls()
                if command == "gh" and args[:2] in (["release", "create"], ["release", "upload"])]

    def seed_existing_release(self, asset_names=None):
        if asset_names is None:
            asset_names = [
                f"{product}-{system}.tar.zst{suffix}"
                for product in ("umbra-studio", "umbra-note")
                for system in SUPPORT.SYSTEMS
                for suffix in ("", ".sha256")
            ]
        remote = self.root / "remote"
        for name in asset_names:
            target = remote / name
            system = next(system for system in SUPPORT.SYSTEMS if system in name)
            source = self.root / f"{'note-' if name.startswith('umbra-note') else ''}{system}.tar.zst"
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
        self.assertEqual(len(self.publications()), 2)
        assets = [x.name for x in (self.root / "remote").iterdir()]
        self.assertEqual(len(assets), 8)
        for system in SUPPORT.SYSTEMS:
            archive = self.root / "remote" / f"umbra-studio-{system}.tar.zst"
            expected = "sha256-" + base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
            self.assertIn(expected, self.pin.read_text())
            iso = self.os / "result-beefcake-release" / f"UmbraOS-26.05-20260910-{system}.iso"
            self.assertTrue(iso.exists())
            self.assertTrue(iso.is_symlink())
            self.assertFalse((self.os / iso.name).exists())
            self.assertIn(hashlib.sha256(iso.read_bytes()).hexdigest(), Path(str(iso) + ".sha256").read_text())
        uploads = [args for command, args, _ in self.calls() if command == "rsync"]
        self.assertEqual(len(uploads), 1)
        self.assertIn("--copy-links", uploads[0])
        self.assertEqual(len([arg for arg in uploads[0] if arg.endswith((".iso", ".sha256"))]), 4)
        for command, args, _ in self.calls():
            if command == "nix" and "build" in args:
                self.assertEqual(args[args.index("--builders") + 1], "ssh-ng://builder@arm aarch64-linux")
                self.assertEqual(args[args.index("--cores") + 1], "2")
                self.assertEqual(args[args.index("--max-jobs") + 1], "1")
        self.assertNotIn("lib.fakeHash", self.pin.read_text())
        self.assertNotEqual(stale.read_bytes(), b"stale")

    def test_update_commits_and_syncs_all_four_repositories(self):
        self.env["BEEFCAKE_TEST_GIT_DIRTY"] = "1"
        result = self.run_release("--update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        git_calls = [args for command, args, _ in self.calls() if command == "git"]
        commits = [args for args in git_calls if "commit" in args]
        pulls = [args for args in git_calls if "pull" in args]
        pushes = [args for args in git_calls if "push" in args]
        self.assertEqual(len(commits), 4)
        self.assertEqual(len(pulls), 4)
        self.assertEqual(len(pushes), 4)
        self.assertTrue(any(args[-2:] == ["-m", "Pin Umbra Studio 0.2.0 and Note 0.0.1 releases"]
                            and args[:2] == ["-C", str(self.os)] for args in commits))
        self.assertIn('version = "0.2.0";', self.pin.read_text())
        self.assertIn('version = "0.0.1";', self.note_pin.read_text())
        self.assertNotIn("lib.fakeHash", self.pin.read_text())
        self.assertNotIn("lib.fakeHash", self.note_pin.read_text())
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))
        self.assertFalse(any(command == "nix" and any(arg.endswith(".iso") for arg in args)
                             for command, args, _ in self.calls()))
        for repo in (self.api, self.studio, self.note, self.os):
            self.assertTrue(any(args[:2] == ["-C", str(repo)] and "push" in args
                                for args in git_calls))

    def test_no_emu_builds_only_x86_64_in_regular_run(self):
        result = self.run_release("--no-emu")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any("aarch64-linux" in " ".join(args)
                             for _, args, _ in calls))
        self.assertEqual([system for command, _, system in calls if command == "nix" and system],
                         ["x86_64-linux"])
        uploads = [args for command, args, _ in calls if command == "rsync"]
        self.assertEqual(len([arg for arg in uploads[0] if arg.endswith((".iso", ".sha256"))]), 2)
        self.assertTrue((self.os / "result-beefcake-release" /
                         "UmbraOS-26.05-20260910-x86_64-linux.iso").exists())

    def test_no_emu_update_preserves_arm_pin(self):
        before = self.pin.read_text()
        arm_block = re.search(r'aarch64-linux = \{.*?\n\s*\};', before, re.DOTALL).group(0)
        result = self.run_release("--update", "--no-emu")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        after = self.pin.read_text()
        self.assertIn(arm_block, after)
        x86_block = re.search(r'x86_64-linux = \{.*?\n\s*\};', after, re.DOTALL).group(0)
        self.assertIn('version = "0.2.0";', x86_block)
        self.assertFalse(any("aarch64-linux" in " ".join(args)
                             for _, args, _ in self.calls()))
        self.assertFalse(any(command == "nix" and any(arg.endswith(".iso") for arg in args)
                             for command, args, _ in self.calls()))

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
        result = self.run_release(fail="iso:aarch64-linux")
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
            iso = self.os / "result-beefcake-release" / f"UmbraOS-26.05-20260910v2-{system}.iso"
            self.assertTrue(iso.exists())
            self.assertTrue(iso.is_symlink())
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

    def test_vm_test_requires_explicit_approval_before_sourceforge(self):
        result = self.run_release("--test", input_text="NO\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(command == "attach-iso.sh" for command, _, _ in self.calls()))
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

        (self.root / "calls.jsonl").write_text("")
        self.env["BEEFCAKE_TEST_EXISTING"] = "1"
        result = self.run_release("--test", input_text="SHIP\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        attaches = [args for command, args, _ in self.calls() if command == "attach-iso.sh"]
        self.assertEqual(len(attaches), 1)
        self.assertIn("x86_64-linux.iso", attaches[0][0])
        self.assertEqual(len([1 for command, _, _ in self.calls() if command == "rsync"]), 1)

    def test_vm_test_failure_never_uploads_to_sourceforge(self):
        result = self.run_release("--test", fail="attach", input_text="SHIP\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SourceForge upload cancelled", result.stderr)
        self.assertFalse(any(command == "rsync" for command, _, _ in self.calls()))

    def test_existing_release_uploads_only_missing_studio_assets(self):
        self.env["BEEFCAKE_TEST_EXISTING"] = "1"
        existing_assets = [
            "umbra-studio-x86_64-linux.tar.zst",
            "umbra-studio-x86_64-linux.tar.zst.sha256",
            "umbra-studio-aarch64-linux.tar.zst",
        ]
        self.env["BEEFCAKE_TEST_EXISTING_ASSETS"] = ",".join(existing_assets)
        self.env["BEEFCAKE_TEST_NOTE_EXISTING_ASSETS"] = ",".join(
            f"umbra-note-{system}.tar.zst{suffix}"
            for system in SUPPORT.SYSTEMS for suffix in ("", ".sha256")
        )
        self.seed_existing_release(existing_assets)
        self.seed_existing_release(
            f"umbra-note-{system}.tar.zst{suffix}"
            for system in SUPPORT.SYSTEMS for suffix in ("", ".sha256")
        )
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
            SUPPORT.pin(self.pin, "0.2.0", {
                "x86_64-linux": digest,
                "aarch64-linux": digest,
            })
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
