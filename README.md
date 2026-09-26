# classicbeu-genesis-toolchain

Builds the pinned Genesis toolchain used by the ClassicBEU editor:
SGDK 2.11, GCC 13.2 for the 68000, and a portable Java.

Everything downloaded is listed in `versions.env` and pinned by checksum in
`checksums.sha256`. All build output goes to `work/`, which is not committed.

## Prerequisites (Arch Linux, one time)

```bash
sudo pacman -S --needed base-devel texinfo jre-openjdk-headless
```

- `base-devel`, `texinfo`: needed to build GCC.
- `jre-openjdk-headless`: SGDK's tools run on Java during `build-sgdk`.

## Build

Run from the repo root, in order. Every step can be re-run safely;
finished parts are skipped.

1. **Download and verify sources**
   `./scripts/build_toolchain.sh fetch`
   Success: one `OK` per file, then `all sources verified on linux-x64`.

2. **Build the 68000 compiler** (10–25 minutes)
   `./scripts/build_toolchain.sh build-gcc`
   Success: `verified: 13.2.0 targets m68k-elf, LTO + libgcc OK`

3. **Build SGDK and test ROMs** (about 1 minute)
   `./scripts/build_toolchain.sh build-sgdk`
   Success:
   `verified: release ROM builds (131072 bytes, header OK)`
   `verified: debug ROM builds (131072 bytes, header OK)`

If a step fails, it prints the error lines and the path to its full log
in `work/logs/`.

## Changing a pinned version (rare)

Only when upgrading SGDK, GCC or Java, or adding a new download:

1. Edit `versions.env`.
2. Delete `checksums.sha256`.
3. `./scripts/build_toolchain.sh fetch --record` downloads everything and
   writes a new `checksums.sha256`.
4. Where the publisher lists checksums (Adoptium does, for Java), compare.
5. Commit `versions.env` and `checksums.sha256` together.
6. If GCC or SGDK changed: `./scripts/build_toolchain.sh clean`, then run
   the Build steps again.

## Starting over

`./scripts/build_toolchain.sh clean` deletes everything in `work/` except
the downloads, **including the built compiler**, so `build-gcc` takes the
full 10–25 minutes again.

## Pinned checksums (reference copy)

The live list is `checksums.sha256` — that is what the script checks.
This copy is for reading only and must be updated by hand whenever
`checksums.sha256` changes.

```
ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450  binutils-2.41.tar.xz
e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da  gcc-13.2.0.tar.xz
5d34596cfe8ebdfb606a1d17ba0028eab8eb003dc1402902a4f2181b1a80467c  sgdk-v2.11.tar.gz
2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500  OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz
dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84  OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz
d35f31e712f0fcf6ac5a093edc90204fbff22f720ba3950bd09d331d5e621636  OpenJDK21U-jre_x64_windows_hotspot_21.0.12.1_1.zip
```