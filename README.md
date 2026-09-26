# classicbeu-genesis-toolchain

Builds the Genesis toolchain for the ClassicBEU editor:
SGDK 2.11 + GCC 13.2 (68000) + portable Java.
Finished bundles land in `out/`.

## Arch Linux

One-time setup:

```bash
sudo pacman -S --needed base-devel texinfo jre-openjdk-headless zip unzip
```

Build (run from the repo root, in order):

| Command | Time | Success line |
|---|---|---|
| `./scripts/build_toolchain.sh fetch` | ~1 min | `all sources verified on linux-x64` |
| `./scripts/build_toolchain.sh build-gcc` | 10–25 min | `verified: 13.2.0 targets m68k-elf, LTO + libgcc OK` |
| `./scripts/build_toolchain.sh build-sgdk` | ~1 min | `verified: debug ROM builds (131072 bytes, header OK)` |
| `./scripts/build_toolchain.sh package` | few min | `package finished: out/...-linux-x64.tar.xz` |

Every step is safe to re-run. On failure, the error and log path are printed.

## macOS

Not built locally yet. The Mac bundle will be built by the GitHub Action;
this section gets filled in once that's verified.

## Windows

Nothing to run. The Windows bundle is made on Linux, and the editor
downloads it.

## Reference

**Reset:** `./scripts/build_toolchain.sh clean` wipes `work/` except
downloads, including the compiler (next `build-gcc` takes the full time).
`out/` is kept.

**Upgrading SGDK / GCC / Java:** edit `versions.env`, delete
`checksums.sha256`, run `fetch --record`, update the copy below, commit.
Then `clean` and rebuild.

**Bundle contents:** `gcc/`, `sgdk/`, `java/`, and `toolchain.json`,
which tells the editor where each tool is.

**Pinned checksums** (copy of `checksums.sha256`, which is what the script checks):

```
ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450  binutils-2.41.tar.xz
e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da  gcc-13.2.0.tar.xz
5d34596cfe8ebdfb606a1d17ba0028eab8eb003dc1402902a4f2181b1a80467c  sgdk-v2.11.tar.gz
2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500  OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz
dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84  OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz
d35f31e712f0fcf6ac5a093edc90204fbff22f720ba3950bd09d331d5e621636  OpenJDK21U-jre_x64_windows_hotspot_21.0.12.1_1.zip
```