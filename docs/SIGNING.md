# 开发者签名和安装

无证书构建得到的 `HuskRebuilt-adhoc-resign-required.ipa` 需要通过 SideStore / AltStore 等侧载器重新签名。`codesign --sign -` 只是本地 ad hoc 签名，不是 Apple Developer 的 Ad Hoc provisioning profile，不会使普通 iPhone 自动允许运行。

为调试器附加准备的开发者签名需要当前有效的 Apple Development 证书和对应私钥，以及 **主 App 和两个扩展各一个 iOS App Development profile**。三个 profile 必须属于同一团队，授权同一证书，包含要安装的设备，并允许 `get-task-allow=true`。默认显式 App ID 为：

```
com.husk.rebuilt
com.husk.rebuilt.JITHelper
com.husk.rebuilt.Downloads
```

手动运行工作流时若设置了其他 `bundle_id`，三个 profile 的 App ID 必须同时使用那个前缀。仅修改 bundle ID 不会授予调试权限。使用自己的开发者账户按 [Apple 开发 profile 文档](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)创建 profile。主 App 和扩展采用同一签名方式，符合 [Apple App Extension 文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html) 的要求。

在自己仓库的 Settings → Secrets and variables → Actions 设置以下 Secrets，或放入工作流使用的 `ios-development-signing` Environment：

| Secret | 值 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | 含 Apple Development 证书和私钥的 P12 的 Base64 内容。 |
| `IOS_CERTIFICATE_PASSWORD` | P12 导出密码。 |
| `IOS_APP_PROFILE_BASE64` | 主 App 的 `.mobileprovision` 文件 Base64。 |
| `IOS_HELPER_PROFILE_BASE64` | JIT helper 的 `.mobileprovision` 文件 Base64。 |
| `IOS_WIDGET_PROFILE_BASE64` | Downloads widget 的 `.mobileprovision` 文件 Base64。 |
| `IOS_TEAM_ID` | 10 位 Apple Developer Team ID。 |

Base64 是编码，不是加密；材料只放在自己的 GitHub Secrets 中，不提交到仓库或聊天。GitHub 的官方临时 keychain 流程见 [macOS runner 证书安装文档](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。

工作流默认为不接触这些 Secrets。需要签名时，从自己的分支手动 Run workflow，将 `development_sign` 打开。先完成真正的运行时构建，再在单独的签名 job 中解码三个 profile、检查团队/有效期/App ID/允许证书、建立临时 keychain、从内部代码到扩展再到主 App 签名，最后使用 `codesign --verify --deep --strict` 核对。临时私钥和独立 profile 文件不会成为 artifact；可安装 IPA 必须按 Apple 格式嵌入 profile，所以这个 IPA 自身会携带 profile 中的注册设备和证书信息。

签名只声明开发 profile 授权的 `get-task-allow`、应用标识和团队标识，不沿用上游 `dynamic-codesigning` 或其他私有权限。由此 Android 可用内存可能与上游特殊安装环境不同，按设备实际可用资源运行。`get-task-allow` 是必要检查之一，不能单独证明 helper 能启动或 JIT 能成功。

`development-device-ipa` 只适用于三个 profile 注册的设备，不能分发给任意 iPhone。安装后按 iOS 提示信任自己的开发者证书，并在需要时启用 Developer Mode；建议先用 Xcode 的 Devices and Simulators 安装到自己的设备再检查诊断。实际代码签名权限与 profile 的关系由 [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)解释。此签名路径不上传 App Store，也不声称绕过系统 JIT 限制。
