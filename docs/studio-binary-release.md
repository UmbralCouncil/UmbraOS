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

The workflow rejects Rust sources, Cargo manifests, source maps, private build
paths, and Data Forensics material in the archive.

## Publish and pin

1. Create the public UmbraOS release `studio-v<version>`.
2. Attach both artifacts without unpacking them.
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
