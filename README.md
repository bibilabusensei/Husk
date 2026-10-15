# Husk Rebuilt · JIT 诊断改写版

这是 Husk 的可重建改写版源码交付。保留上游真正的 QEMU Android 模拟器、Android 原生代码翻译层、ANGLE / MoltenVK 和 APK 导入流程，重写内置 JIT 设置检查与 helper 进度反馈。针对一直停在 “Checking LocalDevVPN and the Developer Disk Image…” 的问题，加入明确阶段、耗时、helper 心跳、可取消检查和诊断报告。

**当前交付的是源码与构建流程。此交付环境为 Windows，没有 Xcode，尚未完成 iOS 编译、产出 IPA 或设备验证。JIT 成功和具体 APK 兼容性不能保证。** 构建流程会真正编译上游运行时，失败即停止，不生成占位 App 或把旧 IPA 当成新构建。

## 实际改动

- 主 App 与 JIT helper 通过只绑定本机 IPv4 的随机端口交换进度，使用每次请求的随机令牌，避免需要额外 App Group 权限。
- 显示检查 VPN 可达性、检查 DDI、下载 DDI、挂载 DDI、验证 DDI、等待调试器的真实阶段。收到阶段不等于下一阶段已成功。
- 单独限制 helper 启动等待和调试器连接等待；正在正常传输的 DDI 下载不会被统一的短倒计时误判失败。长时间无阶段变化会给出处理入口。
- 检查 helper 是否保留、bundle ID 是否从属主 App、框架是否存在，以及当前主 App 运行签名的 `get-task-allow`。读取不到的状态明确显示“未知”。
- 导出当前系统、应用版本、必要状态和本次检查事件的诊断报告；不自动附原始日志、配对文件、密钥、证书、UDID 或网络地址。系统错误文本使用过滤后的内容。
- 保留真实 StikJIT 操作结果、取消与重试状态；不把 VPN App 安装状态或 profile 中的权限误当成 JIT 已启用。

详细边界和设备验证步骤见 [诊断与验证](docs/DIAGNOSTICS.md)。

## 源码来源和完整工程

真实上游为 [Leviidev/Husk](https://github.com/Leviidev/Husk)，固定基线为 [`37aff7c3973861afa67370dc4fbc7d3e6b6f266a`](https://github.com/Leviidev/Husk/tree/37aff7c3973861afa67370dc4fbc7d3e6b6f266a)。StikJIT 使用上游随附的 1.9.0 XCFramework，其对应源码固定为 [`32287268fa5824f9edce4cb359f5833ce0cf7b00`](https://github.com/StikDebug/StikJIT/tree/32287268fa5824f9edce4cb359f5833ce0cf7b00)。全部来源记录在 [UPSTREAM.json](UPSTREAM.json)。

压缩交付包采用“固定上游 + 改写源码 overlay”，以免复制大量已有运行时和二进制框架。`scripts/prepare-source.sh` 获取完整上游到 `build/source`，核对 commit，覆盖 `overlay/src/app/...`；原生依赖构建完成后由上游打包脚本用 XcodeGen 重新生成 `Husk.xcodeproj`，保证依赖路径已存在。工程包含主 App、`HuskJITHelper` 和 `HuskDownloadsWidget` 三个目标。GitHub fork 中对应改写也应同步到原工程 `src/app/...`，便于直接阅读与审查；可重建工作流以 overlay 为来源。

上游 README 报告 iOS / iPadOS 16.0 起可安装，内置 StikJIT helper 目标要求 iOS 26.0；更早系统沿用上游外部 StikDebug 路径。当前内置 DDI 实现按系统选择 iOS 26.4 之前的 personalized 三文件格式或 26.4 起的 cryptex 五文件格式。配对、下载服务器、设备接受挂载和调试权限仍由上游与 iOS 实际行为决定。详见 [上游 JIT 文档](https://github.com/Leviidev/Husk/blob/37aff7c3973861afa67370dc4fbc7d3e6b6f266a/docs/06-built-in-jit.md)。

本次没有重新实现完整 Android 系统。APK 支持程度继承固定的上游版本及其实际构建内容：原生翻译层主要依赖 64 位 `arm64-v8a` 引擎，Java-only、32 位 APK、Google Play 登录/付费服务等能力不能由这次改写保证；模拟路径仍需真实 Android 客体资源，且 iOS 下 CPU 模拟性能有限。官方构建链未准备的可选 Java runtime 与 Android 字体资源仍会按上游方式报告缺失。

## 在 Mac 上构建

需要完整 Xcode、足够磁盘空间、网络和 Rust iOS 工具链。初次构建会下载并编译 QEMU、ANGLE、virglrenderer、MoltenVK 和 Rust 配对库，通常耗时数小时。

```sh
brew install meson ninja pkg-config xcodegen qemu cmake autoconf automake libtool
rustup target add aarch64-apple-ios
bash scripts/build.sh
```

构建脚本会在 `build/host-python` 创建独立 Python 环境并安装固定版本的 PyYAML，供 virglrenderer 生成格式表；启动原生构建前会确认该模块可导入。

默认 bundle ID 为 `com.husk.rebuilt`，两个扩展分别追加 `.JITHelper` 与 `.Downloads`。需要自身 App ID 时，在开始构建前设置：

```sh
export HUSK_BUNDLE_IDENTIFIER=com.yourteam.huskrebuilt
bash scripts/build.sh
```

脚本为 clean build 设计，拒绝覆盖已有 `build/source`。重建时请使用新的交付目录，或保留已有目录作为诊断材料后在新的副本中运行。原生依赖构建与项目生成完成后，完整工程位于 `build/source/src/app/Husk.xcodeproj`。

上游 StikJIT `.swiftinterface` 的 compiler 标记为 **Apple Swift 6.4**。脚本自动选择已安装的最高稳定 Xcode，并在耗时构建前实际检查 `import StikJIT`。若失败，查看 `artifacts/logs/stikjit-import.txt` 并换用兼容的新 Xcode；不通过改写框架接口来伪装兼容。可通过 `XCODE_PATH=/Applications/Xcode_26.6.app` 指定已安装版本。GitHub 官方当前 [macos-26 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)包含 Xcode 26.6 / 26.5 / 26.4.1，[macos-15 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)列出的最高版本较旧；镜像内容可能更新，实际检查结果为准。

## GitHub Actions 和 IPA

`.github/workflows/ios-build.yml` 在 `codex/jit-rebuild` 分支 push 时执行无开发者证书构建，也支持 Actions 中手动运行。默认 runner 为 `macos-26`，手动输入可选 `macos-15`、Xcode 路径和 App ID。Fork 可能需要先在自己的仓库启用 Actions。独立的轻量检查 job 先直接编译生产消息/进度源码并运行消息兼容与本机 Network 传输检查，通过后才执行耗时的运行时构建；这些检查未在当前 Windows 环境执行，检查成功也不能代替完整 iOS 构建或设备 JIT 验证。

构建成功后分别上传：

| Artifact | 用途 |
| --- | --- |
| `unsigned-ipa` | 真正未签名的 App 包，普通 iOS 不能直接安装。 |
| `adhoc-ipa-resign-required` | 本地 ad hoc 代码签名包，供 SideStore / AltStore 等工具重新签名；这不是已获 Apple 授权的 Ad Hoc 分发。 |
| `development-device-ipa` | 仅手动开启 development signing 且签名材料有效时产生，供 profile 中注册的设备安装。 |
| `build-logs-and-provenance` | 构建日志、工具链信息、固定上游与 overlay commit / 内容摘要、实际依赖 commit 与下载归档摘要。失败也上传已有内容。 |
| `corresponding-source` | 本次构建源码快照，含已获取的上游、运行时依赖源树、StikJIT 对应源代码、overlay、脚本和许可证。 |

App 包同时含 `HuskRebuildProvenance.json`，用于核对构建来源。Provenance 记录依赖实际解析结果；Homebrew 工具版本、上游下载渠道和未完全固定的传递依赖意味着此流程尚不能承诺位级可重复构建。对外分发时应将对应源代码与二进制一起长期保存，Actions 临时 artifact 不是长期源码发布。

重新签名时应保留 **两个 App Extensions**，统一设置 App 和扩展 ID 与签名团队，并在已安装 App 内检查实际 `get-task-allow`。需要自行开发者签名时，参阅 [签名说明](docs/SIGNING.md)。**不要把 P12、密码、配对文件或私钥发送到聊天。**

## 许可与归因

Husk 和本次改写采用 **GPL-2.0-or-later**；根目录 [LICENSE](LICENSE) 保留上游 GPLv2 全文。作者归因与第三方范围见 [THIRD_PARTY.md](docs/THIRD_PARTY.md)。StikJIT 源文件为 MPL-2.0，包含的 idevice 使用其自己的 MIT 许可；各第三方源树原有 LICENSE、NOTICE 和版权声明应保留。发布源码、修改和二进制时继续遵守各自许可证。
