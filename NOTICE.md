# 第三方组件

Kitty Box 自己的代码以 MIT 许可证发布（见 [LICENSE](LICENSE)）。App 里随包分发的第三方东西如下，各按各的许可证：

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| 7-Zip 26.05（`7zz`） | 打包；解压 7z、RAR 等 | GNU LGPL 2.1，RAR 解压部分另有 unRAR 限制 | https://github.com/ip7z/7zip ，作为单独的程序放在 `Contents/MacOS/7zz`，许可证全文在 `Contents/Resources/7zz-LICENSE.txt` |
| Gemini 去水印的 α 图（4 张） | 还原 Gemini 生成图右下角的星标 | MIT | https://github.com/GargantuaX/gemini-watermark-remover （commit `ddd67a7` 的 `src/core/embeddedAlphaMaps.js`），放在 `Contents/Resources/gemini-alpha-*.bin`，许可证全文在 `Contents/Resources/gemini-watermark-LICENSE.txt`；反向 alpha 混合的算法也参考了它和 https://github.com/allenk/GeminiWatermarkTool （MIT） |
| LaMa 补图模型（Core ML，FP32，「标准」） | 画笔擦除、AI 水印里补上涂掉 / 认出的地方 | Apache-2.0 | 模型 [advimman/lama](https://github.com/advimman/lama)（Suvorov 等，WACV 2022），Core ML 版来自 https://huggingface.co/mlboydaisuke/LaMa-CoreML （revision `5ed76e3`），**不随包**：用到时由 App 下载（连不上时换镜像 hf-mirror.com），按 SHA256 校验，放在 `~/Library/Application Support/Kitty Box/Models/`；许可证全文在 `Contents/Resources/lama-LICENSE.txt` |
| Big LaMa 2048（Core ML，「高清」） | 同上，一次补 2048 见方 | Apache-2.0 | 同 LaMa 的模型和权重（[smartywu/big-lama](https://huggingface.co/smartywu/big-lama)），Core ML 版来自 https://huggingface.co/local-vision-models/lama-2048-coreml 的 `LaMa2048.mlpackage.zip`，**不随包**，在设置里选了才下载，按 SHA256 校验 |
| BiRefNet Lite 1024（Core ML，去背景「精细」） | 去背景：抠出前景 | MIT | [ZhengPeng7/BiRefNet](https://github.com/ZhengPeng7/BiRefNet)（Zheng 等，CAAI AIR 2024）的 BiRefNet_lite，Core ML 版来自 https://huggingface.co/metaclass/birefnet-lite-coreml （revision `519543b`，`fp16compute-fp32io/r1`；转换脚本 [miracle2k/birefnet-lite-coreml](https://github.com/miracle2k/birefnet-lite-coreml)，MIT），**不随包**，选了「精细」才下载，按 SHA256 校验；许可证和 NOTICE 全文在 `Contents/Resources/birefnet-LICENSE.txt` |
| MI-GAN 512 Places2（Core ML，「快速」） | 同上，小而快 | MIT | [Picsart-AI-Research/MI-GAN](https://github.com/Picsart-AI-Research/MI-GAN)（Sargsyan 等，ICCV 2023），Core ML 版来自 https://huggingface.co/BryanHaley/photowagon-models 的 `migan/MIGAN.mlpackage.zip`，**不随包**，在设置里选了才下载，按 SHA256 校验；许可证全文在 `Contents/Resources/migan-LICENSE.txt` |

`7zz` 不在仓库里：`macos/fetch-vendor.sh` 按固定的 SHA256 从上面的地址下载。补图模型、抠图模型的来源和 SHA256 写在 `macos/KittyBox/Watermark/AIModel.swift`。访达扩展里「新建文件」的五个模板（`macos/KittyBoxFinder/Templates/`）是自己做的，不是第三方的。
