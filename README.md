# classicbeu-genesis-toolchain

Builds the toolchain for the ClassicBEU editor (Retro Game Studio):
SGDK 2.11 + GCC 13.2 (68000, and SH-2 for the 32X) + portable Java, and for
the Dreamcast (Linux and macOS bundles) KallistiOS with its own SH-4 GCC 13.2
and newlib.
Finished bundles land in `out/`, and are published as GitHub releases.

## Publish a release (normal use)

1. Actions tab → **Build toolchain release** → **Run workflow** → **Run workflow**.
2. Wait about 1.5–2 hours. All five jobs should go green:
   `Check the release name is free`, `Linux x64`, `macOS arm64`,
   `Windows x64 (test the bundle)`, `Publish release`.
3. The release appears under **Releases**, named after `TOOLCHAIN_ID`
   (currently `sgdk2.11-gcc13.2.0-r3`).

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
| `./scripts/build_toolchain.sh build-dc` | 30–60 min | `verified: Dreamcast C and C++ programs link with KallistiOS; makeip makes IP.BIN` |
| `./scripts/build_toolchain.sh package` | few min | `package finished: out/...-linux-x64.tar.xz` |
| `./scripts/build_toolchain.sh package-windows` | <1 min | `package-windows finished: out/...-windows-x64.zip` |

### macOS (Apple Silicon)

Same commands as the GitHub Action's macOS job. One-time setup (Homebrew):

```bash
brew install texinfo make
export PATH="$(brew --prefix texinfo)/bin:$(brew --prefix make)/libexec/gnubin:$PATH"
```

The `export` line is needed in every new terminal before building. Then run
`fetch`, `build-gcc`, `build-sh2`, `build-sgdk`, `build-dc` and `package` from the table above
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
in `GCC_PATCHES` and `KOS_PATCHES` in `versions.env`. Each file explains what
it fixes and where the fix came from: GCC 13.3's fix that lets GCC 13.2
build with Apple's libc++ on macOS, and makeip without libpng.

**Bundle contents:** `gcc/` (not on Windows; the `m68k-elf-*` and
`sh-elf-*` tools), `sh2/` (Windows only: the SH-2 compiler built for
Windows), `sgdk/`, `java/`, `dreamcast/` (not on Windows: KallistiOS and its
compiler), and `toolchain.json`, which tells the editor where each tool is
(its `"sh2"` section is the 32X compiler, `"dreamcast"` KallistiOS).

**The 32X compiler** (`sh-elf`, SH-2): the same GCC and binutils as the
68000 one, so no extra downloads. No Sega code is in any bundle.

**The Dreamcast** (`build-dc`, the bundle's `dreamcast/`), built the way
KallistiOS's own `kos-chain` builds it, from the same GCC and binutils plus
two pinned sources (KallistiOS at a commit, newlib):
- `sh-elf/`: GCC (C and C++) for the SH-4 with newlib and KallistiOS's
  threads, its patches applied (they ship inside KallistiOS's source, in
  `utils/kos-chain/patches`). Not the 32X's compiler: the same name, another
  CPU, so it has its own folder.
- `kos/`: KallistiOS, built, with `makeip` (disc boot sectors; its bootstrap
  is KallistiOS's own copyright-free one). `makeip` is built without libpng
  (`patches/kallistios-makeip-without-libpng.patch`) so it runs on any Mac
  or Linux; it takes boot logos as MR images, which the editor makes.
- `environ.sh`: KallistiOS's environment for wherever the bundle is. Set
  `RGS_DREAMCAST_DIR` to the `dreamcast/` folder, then source it:
  `RGS_DREAMCAST_DIR=$PWD/dreamcast . dreamcast/environ.sh && kos-cc ...`

**Adding a source:** add it to `ARTIFACTS` in `versions.env`, then pin it
with `fetch --record-missing` (it pins only what has no checksum, keeps
every other pin and still checks them), or on GitHub: Actions tab → **Pin
new sources** → Run workflow, and copy the printed lines into
`checksums.sha256`.

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
96ff13295c7d509fa44c5a1bd97023da1d4d33b4a8b8e0895e66c46760f6bcbd  KallistiOS-d458073c00025f065cc68bebb8ef15ea83264e2b.tar.gz
83a62a99af59e38eb9b0c58ed092ee24d700fff43a22c03e433955113ef35150  newlib-4.3.0.20230120.tar.gz
```
