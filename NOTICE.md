# 第三方组件

Kitty Box 自己的代码以 MIT 许可证发布（见 [LICENSE](LICENSE)）。App 里随包分发的第三方东西如下，各按各的许可证：

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| 7-Zip 26.05（`7zz`） | 打包；解压 7z、RAR 等 | GNU LGPL 2.1，RAR 解压部分另有 unRAR 限制 | https://github.com/ip7z/7zip ，作为单独的程序放在 `Contents/MacOS/7zz`，许可证全文在 `Contents/Resources/7zz-LICENSE.txt` |
| Gemini 去水印的 α 图（4 张） | 还原 Gemini 生成图右下角的星标 | MIT | https://github.com/GargantuaX/gemini-watermark-remover （commit `ddd67a7` 的 `src/core/embeddedAlphaMaps.js`），放在 `Contents/Resources/gemini-alpha-*.bin`，许可证全文在 `Contents/Resources/gemini-watermark-LICENSE.txt`；反向 alpha 混合的算法也参考了它和 https://github.com/allenk/GeminiWatermarkTool （MIT） |
| LaMa 画笔擦除模型（Core ML，FP32） | 画笔擦除时补上涂掉的地方 | Apache-2.0 | 模型 [advimman/lama](https://github.com/advimman/lama)（Suvorov 等，WACV 2022），Core ML 版来自 https://huggingface.co/mlboydaisuke/LaMa-CoreML （revision `5ed76e3`），**不随包**：第一次用画笔擦除时由 App 从上面的地址下载（连不上时换镜像 hf-mirror.com），按 SHA256 校验，放在 `~/Library/Application Support/Kitty Box/Models/LaMa.mlmodelc`；许可证全文在 `Contents/Resources/lama-LICENSE.txt` |

`7zz` 不在仓库里：`macos/fetch-vendor.sh` 按固定的 SHA256 从上面的地址下载。LaMa 模型的版本和 SHA256 写在 `macos/KittyBox/Watermark/LaMaModel.swift`。
