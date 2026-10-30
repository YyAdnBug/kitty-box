# 第三方组件

Kitty Box 自己的代码以 MIT 许可证发布（见 [LICENSE](LICENSE)）。App 里随包分发的第三方东西如下，各按各的许可证：

| 组件 | 用途 | 许可证 | 来源 |
|---|---|---|---|
| 7-Zip 26.05（`7zz`） | 打包；解压 7z、RAR 等 | GNU LGPL 2.1，RAR 解压部分另有 unRAR 限制 | https://github.com/ip7z/7zip ，作为单独的程序放在 `Contents/MacOS/7zz`，许可证全文在 `Contents/Resources/7zz-LICENSE.txt` |

`7zz` 不在仓库里：`macos/fetch-vendor.sh` 按固定的 SHA256 从上面的地址下载官方包。以后加进来的组件（Gemini 去水印的 alpha 图、LaMa 模型）随它们的批次补进这张表。
