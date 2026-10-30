#!/usr/bin/env bash
# 拉随包的第三方程序（PLAN §1，E3）：不入库，按固定的 SHA256 从官方地址下载，谁都能复现。第一次构建前跑一次。
# - 7-Zip 的 7zz → Vendor/7zz（官方包是 universal、没签名：只留 arm64，构建时 Xcode 的「Embed 7zz」拷进包里并签名）；
#   它的许可证 → KittyBox/Resources/7zz-LICENSE.txt（入库，随包分发要带上）。
# - 画笔擦除的 LaMa 模型（Core ML，FP32，800×800）：Hugging Face 上 mlboydaisuke/LaMa-CoreML 固定版本的三个文件，
#   各自按 SHA256 校验，编译成 Vendor/LaMa.mlmodelc（构建时 Xcode 的「Embed LaMa」拷进 Resources）。约 216 MB。
#   M4 比过两份：Jia-Liu/big-lama-coreml 只有一半大，但它是半精度，补出来的地方明显偏色；这份补得几乎看不出来，速度一样。
#   许可证 Apache-2.0，全文在 KittyBox/Resources/lama-LICENSE.txt（入库）。
# 换版本：改下面的版本号和 SHA256 再跑；7zz 的和 GitHub release 页的 digest 核对，LaMa 的和 Hugging Face 上文件页的 SHA256 核对。
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

LAMA_REPO=https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/5ed76e3799ab4cad31381750d29880c267477e18
LAMA_FILES=(
  "Manifest.json c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58"
  "Data/com.apple.CoreML/model.mlmodel 06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953"
  "Data/com.apple.CoreML/weights/weight.bin d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184"
)
if [[ ! -d "$M/Vendor/LaMa.mlmodelc" ]]; then
  for entry in "${LAMA_FILES[@]}"; do
    read -r file sum <<< "$entry"
    mkdir -p "$(dirname "$WORK/LaMa.mlpackage/$file")"
    curl -fsSL -o "$WORK/LaMa.mlpackage/$file" "$LAMA_REPO/LaMa.mlpackage/$file"
    [[ "$(shasum -a 256 "$WORK/LaMa.mlpackage/$file" | cut -d' ' -f1)" == "$sum" ]] \
      || { echo "LaMa 的 $file SHA256 对不上，没装" >&2; exit 1; }
  done
  xcrun coremlcompiler compile "$WORK/LaMa.mlpackage" "$WORK" >/dev/null
  mv "$WORK/LaMa.mlmodelc" "$M/Vendor/LaMa.mlmodelc"
fi
echo "LaMa 模型已放到 Vendor/LaMa.mlmodelc"
