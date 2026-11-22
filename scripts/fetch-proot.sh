#!/usr/bin/env bash
# Puts proot (and the two libraries it needs) into the app's jniLibs, so the
# built-in Ubuntu runs with no other app installed.
#
# The binaries come from Termux's package repository, pinned by version and
# SHA-256. They are named lib*.so so Android installs them into the app's
# native library directory, the one place an app may execute files from.
set -euo pipefail

JNI_LIBS=${1:-app/android/app/src/main/jniLibs}
MIRROR=https://packages-cf.termux.dev/apt/termux-main
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# abi  termux-arch  package-path  sha256
PACKAGES=(
  "arm64-v8a   aarch64 pool/main/p/proot/proot_5.1.107.102_aarch64.deb                    10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030"
  "arm64-v8a   aarch64 pool/main/libt/libtalloc/libtalloc_2.5.0_aarch64.deb               556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7"
  "arm64-v8a   aarch64 pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb   0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6"
  "armeabi-v7a arm     pool/main/p/proot/proot_5.1.107.102_arm.deb                        d6912a83e1a149b3403afc116109d2974b378af599599b0124a68b07b2ca0c78"
  "armeabi-v7a arm     pool/main/libt/libtalloc/libtalloc_2.5.0_arm.deb                   98ace4f1fcbb04b75e859a12b689a9ae4ac91ff8fd34ab221e5359c95ba47f52"
  "armeabi-v7a arm     pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_arm.deb       5832fd11dca9be2a288dd8fbc2b2799b289c812c7a8764f1f8234c425aa64ce5"
  "x86_64      x86_64  pool/main/p/proot/proot_5.1.107.102_x86_64.deb                     2497064226c15971be8131c7facead94a06c225347796326a383c832dca57758"
  "x86_64      x86_64  pool/main/libt/libtalloc/libtalloc_2.5.0_x86_64.deb                b8c6d95f20075dc1f9ec6573575b2444e8d526e48e0d8d6d5cf4e071e6e06530"
  "x86_64      x86_64  pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_x86_64.deb    ffa9e4c87467b158b148d0ff92dda796aa038276c2075af3269cdcdb06f25797"
)

for row in "${PACKAGES[@]}"; do
  read -r abi _arch path sha <<<"$row"
  deb="$WORK/$(basename "$path")"
  curl -sfL "$MIRROR/$path" -o "$deb"
  echo "$sha  $deb" | sha256sum -c --quiet
  dir="$WORK/x-$(basename "$path" .deb)"
  mkdir -p "$dir"
  (cd "$dir" && ar x "$deb" && tar -xf data.tar.*)
  usr="$dir/data/data/com.termux/files/usr"
  out="$JNI_LIBS/$abi"
  mkdir -p "$out"
  case "$path" in
    */proot_*)
      install -m 755 "$usr/bin/proot" "$out/libproot.so"
      install -m 755 "$usr/libexec/proot/loader" "$out/libproot-loader.so"
      if [ -f "$usr/libexec/proot/loader32" ]; then install -m 755 "$usr/libexec/proot/loader32" "$out/libproot-loader32.so"; fi
      ;;
    */libtalloc_*) install -m 644 "$(readlink -f "$usr/lib/libtalloc.so.2")" "$out/libtalloc.so" ;;
    */libandroid-shmem_*) install -m 644 "$usr/lib/libandroid-shmem.so" "$out/libandroid-shmem.so" ;;
  esac
done
echo "proot installed into $JNI_LIBS"
