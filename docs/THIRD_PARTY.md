# 来源与许可证

本项目改写基于 [Husk](https://github.com/Leviidev/Husk)，作者与贡献者信息以固定基线原文件版权声明和 Git 历史为准。所有原有声明应保留。本次新增和修改的 Swift 与交付脚本采用 GPL-2.0-or-later，不能据此重标第三方源文件许可证。

| 组件 | 来源与用途 | 许可处理 |
| --- | --- | --- |
| Husk | GPL Android 模拟/翻译宿主及 iOS App | GPL-2.0-or-later；保留根 LICENSE 和源码。 |
| QEMU | 上游固定 UTM 衍生源树和补丁 | GPLv2 范围；随对应源码发布构建脚本与修改。 |
| ANGLE / MoltenVK / virglrenderer / 原生依赖 | 由固定 Husk 构建脚本下载并链接 | 保留每个下载源树的 LICENSE、NOTICE 和版权文件；不要将所有依赖泛称 GPL。 |
| StikJIT 1.9.0 | 未修改的上游随附 XCFramework；对应源代码固定 `32287268fa5824f9edce4cb359f5833ce0cf7b00` | MPL-2.0；准备脚本同时获取其完整源树并保留 MPL 正文。 |
| idevice | StikJIT 源树内的相关设备通信代码 | 按其源树 MIT LICENSE 保留声明。 |
| Rust 配对库及 crates | Husk 官方构建脚本准备并编译 | 保留项目许可证及 Cargo.lock；构建 provenance 记录实际源 commit 和 lockfile 摘要。 |

`HuskRebuilt-corresponding-source.tar.gz` 包含本次准备和构建中保留的完整上游源树与依赖源树、StikJIT 源树、本次 overlay、脚本和文档；为控制体积，排除 `.git`、编译产物目录和顶层 build 输出，但不排除 `third_party/build` 中的依赖源码。上游构建脚本、补丁、下载归档和 Cargo.lock 同时保留，可与 provenance 对照。

源码归档和实际源码清单不等于自动的许可证合规证明；分发二进制前，应将构建使用的 Rust crates、其他缓存外源代码和第三方 notices 与构建源码一起长期发布。只有链接源码地址或短期 Actions artifact 不能替代需要提供的对应源码。此项目不附 Android 商业 APK、游戏、Apple 开发证书、配对文件或 DDI 下载文件。
