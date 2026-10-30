#!/usr/bin/env bash
# 拉随包的第三方程序（PLAN §1，E3）：不入库，按固定的 SHA256 从官方地址下载，谁都能复现。第一次构建前跑一次。
# - 7-Zip 的 7zz → Vendor/7zz（官方包是 universal、没签名：只留 arm64，构建时 Xcode 的「Embed 7zz」拷进包里并签名）；
#   它的许可证 → KittyBox/Resources/7zz-LICENSE.txt（入库，随包分发要带上）。
# 换版本：改下面两行再跑，SHA256 和 GitHub release 页的 digest 核对一遍。LaMa 模型 M4 再加到这里。
set -euo pipefail
M="$(cd "$(dirname "$0")" && pwd)"
SEVENZIP_VERSION=26.05
SEVENZIP_SHA256=12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570

ARCHIVE="7z${SEVENZIP_VERSION/./}-mac.tar.xz"
WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT
curl -fsSL -o "$WORK/$ARCHIVE" "https://github.com/ip7z/7zip/releases/download/$SEVENZIP_VERSION/$ARCHIVE"
[[ "$(shasum -a 256 "$WORK/$ARCHIVE" | cut -d' ' -f1)" == "$SEVENZIP_SHA256" ]] \
  || { echo "$ARCHIVE 的 SHA256 对不上，没装" >&2; exit 1; }
tar -xJf "$WORK/$ARCHIVE" -C "$WORK" 7zz License.txt
mkdir -p "$M/Vendor"
lipo "$WORK/7zz" -thin arm64 -output "$M/Vendor/7zz"
cp "$WORK/License.txt" "$M/KittyBox/Resources/7zz-LICENSE.txt"
"$M/Vendor/7zz" i >/dev/null
echo "7zz $SEVENZIP_VERSION 已放到 Vendor/7zz"
