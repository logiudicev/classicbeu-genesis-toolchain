# classicbeu-genesis-toolchain

Builds the Genesis toolchain for the ClassicBEU editor:
SGDK 2.11 + GCC 13.2 (68000, and SH-2 for the 32X) + portable Java.
Finished bundles land in `out/`, and are published as GitHub releases.

## Publish a release (normal use)

1. Actions tab → **Build toolchain release** → **Run workflow** → **Run workflow**.
2. Wait about 45–75 minutes. All five jobs should go green:
   `Check the release name is free`, `Linux x64`, `macOS arm64`,
   `Windows x64 (test the bundle)`, `Publish release`.
3. The release appears under **Releases**, named after `TOOLCHAIN_ID`
   (currently `sgdk2.11-gcc13.2.0-r1`).

A release name can only be used once. To publish again, bump
`TOOLCHAIN_REVISION` in `versions.env` first; otherwise the first job stops
the run.

## Building locally

### Arch Linux

One-time setup:

```bash
sudo pacman -S --needed base-devel texinfo jre-openjdk-headless zip unzip mingw-w64-gcc
```

Build (from the repo root, in order):

| Command | Time | Success line |
|---|---|---|
| `./scripts/build_toolchain.sh fetch` | ~1 min | `all sources verified on linux-x64` |
| `./scripts/build_toolchain.sh build-gcc` | 10–25 min | `verified: 13.2.0 targets m68k-elf, LTO + libgcc OK` |
| `./scripts/build_toolchain.sh build-sh2` | 10–25 min | `verified: 13.2.0 targets sh-elf (m2), LTO + libgcc OK` |
| `./scripts/build_toolchain.sh build-sh2-windows` | 10–25 min | `build-sh2-windows finished: ...` (needs `mingw-w64`) |
| `./scripts/build_toolchain.sh build-sgdk` | ~1 min | `verified: debug ROM builds (131072 bytes, header OK)` |
| `./scripts/build_toolchain.sh package` | few min | `package finished: out/...-linux-x64.tar.xz` |
| `./scripts/build_toolchain.sh package-windows` | <1 min | `package-windows finished: out/...-windows-x64.zip` |

### macOS (Apple Silicon)

Same commands as the GitHub Action's macOS job. One-time setup (Homebrew):

```bash
brew install texinfo make
export PATH="$(brew --prefix texinfo)/bin:$(brew --prefix make)/libexec/gnubin:$PATH"
```

The `export` line is needed in every new terminal before building. Then run
`fetch`, `build-gcc`, `build-sh2`, `build-sgdk` and `package` from the table above
(success lines say `macos-arm64` instead of `linux-x64`).

### Windows

Nothing to run on Windows. The Windows bundle is made on Linux with
`package-windows`, test-built by the GitHub Action on a Windows machine, and
downloaded by the editor.

Every step is safe to re-run. On failure, the error lines and log path are
printed; logs are in `work/logs/`.

## Reference

**Reset:** `./scripts/build_toolchain.sh clean` wipes `work/` except
downloads, including the compiler (next `build-gcc` takes the full time).
`out/` is kept.

**Upgrading SGDK / GCC / Java:** edit `versions.env`, delete
`checksums.sha256`, run `fetch --record`, update the copy below, commit.
Then `clean` and rebuild, and bump `TOOLCHAIN_REVISION` only if no version
in the ID changed.

**Patches:** `patches/` holds our small fixes to upstream sources, listed
in `GCC_PATCHES` in `versions.env`. Each file explains what it fixes and
where the fix came from. Currently one: GCC 13.3's fix that lets GCC 13.2
build with Apple's libc++ on macOS.

**Bundle contents:** `gcc/` (not on Windows; the `m68k-elf-*` and
`sh-elf-*` tools), `sh2/` (Windows only: the SH-2 compiler built for
Windows), `sgdk/`, `java/`, and `toolchain.json`, which tells the editor
where each tool is (its `"sh2"` section is the 32X compiler).

**The 32X compiler** (`sh-elf`, SH-2): the same GCC and binutils as the
68000 one, so no extra downloads. No Sega code is in any bundle.

**Known harmless message (Windows only):** a ROM build prints one
`make[1]: [...ltrans0.ltrans.o] Error 127 (ignored)` line. It comes from a
Unix tool GCC looks for during the link; the ROM is byte-identical with or
without it.

**Pinned checksums** (copy of `checksums.sha256`, which is what the script checks):

```
ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450  binutils-2.41.tar.xz
e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da  gcc-13.2.0.tar.xz
5d34596cfe8ebdfb606a1d17ba0028eab8eb003dc1402902a4f2181b1a80467c  sgdk-v2.11.tar.gz
2413149700df0f7d440500a84a8f764c535f21e5a5e87d38328b64eec2c5b500  OpenJDK21U-jre_x64_linux_hotspot_21.0.12.1_1.tar.gz
dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84  OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz
d35f31e712f0fcf6ac5a093edc90204fbff22f720ba3950bd09d331d5e621636  OpenJDK21U-jre_x64_windows_hotspot_21.0.12.1_1.zip
```
