# Shipping proprietary Umbra Studio

UmbraOS does not import the private UmbraStudio source repository. It consumes
a source-free archive published with the public UmbraOS releases, while the
Umbra Core microVM remains reproducible from this repository.

## Produce the archive

In the private UmbraStudio repository, tag the release or run the **Build
proprietary release bundle** workflow manually. Download these workflow
artifacts:

- `umbra-studio-x86_64-linux.tar.zst`
- `umbra-studio-x86_64-linux.tar.zst.sha256`
- `umbra-studio-aarch64-linux.tar.zst`
- `umbra-studio-aarch64-linux.tar.zst.sha256`

The workflow builds each architecture on a native runner. Keep the archive
and checksum names architecture-specific; each target has its own hash in
`modules/studio/package.nix`. See [ARM64 builds](arm64.md) for the initial ARM
release prerequisite.

The workflow rejects Rust sources, Cargo manifests, source maps, private build
paths, and Data Forensics material in the archive.

## Publish and pin

1. Create the public UmbraOS release `studio-v<version>`.
2. Attach both architectures' archives and checksum files without unpacking them.
3. Set the same version in `modules/studio/package.nix`.
4. Run an UmbraOS build. The first build fails with the expected fixed-output
   hash and prints the archive's actual Nix hash.
5. Replace `lib.fakeHash` with that `sha256-...` value.
6. Build the persistent configuration and ISO.

```sh
nix build .#nixosConfigurations.default.config.system.build.toplevel
nix build .#iso
```

The installed closure contains the compiled Studio application, its desktop
assets and EULA, plus the open Umbra Core guest runner. It does not contain the
private Studio repository or external courses.

## Automated release: BEEFCAKE

Run the interactive release orchestrator from the UmbraOS checkout:

```sh
./tools/beefcake
```

It first tests that both x86 and ARM builds can execute, then updates Studio's
version and builds both source-free bundles. Before publishing, it checks each
archive for the expected files and ELF architecture. It publishes the archives
and checksums to the same GitHub release, verifies both public downloads, and
updates both SRI hashes in UmbraOS. It then builds and size-checks both ISOs and
uploads the pair and their checksums to SourceForge using resumable rsync.

ISO names include the architecture, for example:

```text
UmbraOS-26.05-20260910-x86_64-linux.iso
UmbraOS-26.05-20260910-aarch64-linux.iso
```

If either local filename already exists, both use the next shared revision
(`20260910v2`, and so on). An existing file is not overwritten. A per-checkout
lock prevents overlapping BEEFCAKE runs. SourceForge receives neither ISO until
both builds and size checks pass. GitHub Studio publication occurs earlier;
a later ISO failure does not roll back the Studio release. Re-running reuses
Nix build results and replaces the GitHub assets with `--clobber`.

Pass a CONNECT proxy interactively or with `--proxy HOST:PORT`.
`--skip-sourceforge` skips both ISO uploads but still releases Studio to GitHub.
`--check-builders` only tests the build setup; it never edits versions or
publishes. `--jobs` and `--cores` control local build parallelism. See the
[ARM64 builder guide](arm64.md) for local QEMU emulation, optional SSH builders,
and Android limitations.

Run the orchestration regression tests without building or publishing:

```sh
python3 tools/test_beefcake.py
```

Use `./tools/beefcake --help` for path and account overrides. Run it as the
normal development user; the Nix daemon performs privileged builds.
