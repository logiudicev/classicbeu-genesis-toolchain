# classicbeu-genesis-toolchain
SGDK toolchain for use with Classic Beat em Up Engine

## Pre-reqs: Java JRE
* sudo pacman -Syu jre-openjdk-headless

# commands
* chmod +x scripts/build_toolchain.sh
* ./scripts/build_toolchain.sh fetch --record

# checksum
* ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450  binutils-2.41.tar.xz
* e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da  gcc-13.2.0.tar.xz
* 5d34596cfe8ebdfb606a1d17ba0028eab8eb003dc1402902a4f2181b1a80467c  sgdk-v2.11.tar.gz

# commands continued
* ./scripts/build_toolchain.sh fetch

# commands (Arch Linux)
* sudo pacman -S --needed base-devel texinfo

# commands continued
* ./scripts/build_toolchain.sh build-gcc

# success will read:
* verified: 13.2.0 targets m68k-elf, LTO + libgcc OK

# commands continued
* ./scripts/build_toolchain.sh build-sgdk

## verify
* [toolchain] verified: release ROM builds (131072 bytes, header OK)
* [toolchain] verified: debug ROM builds (131072 bytes, header OK)