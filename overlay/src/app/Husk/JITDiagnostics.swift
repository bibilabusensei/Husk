// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI
import Security
import UIKit
import Darwin

/// A fresh, deliberately small report. It never appends the raw native log,
/// a pairing identifier, certificates, or the contents of a pairing file.
enum JITDiagnostics {
    private enum RuntimeDebugPermission {
        case allowed
        case denied
        case absent
        case unknown(String)

        var description: String {
            switch self {
            case .allowed: return "true（从当前运行进程签名读取）"
            case .denied: return "false（从当前运行进程签名读取）"
            case .absent: return "不存在（运行进程未返回此权限）"
            case .unknown(let reason): return "未知（\(reason)）"
            }
        }
    }

    private struct ProfileSummary {
        let description: String
        let allowsDebugging: Bool?
    }

    /// This describes embedded.mobileprovision only. It must not be used as
    /// proof of the current process's entitlement or as a hard JIT gate.
    static var currentProfileAllowsDebugging: Bool? {
        profile(in: Bundle.main).allowsDebugging
    }

    @MainActor
    static func snapshot() -> String {
        let app = Bundle.main
        let appID = app.bundleIdentifier
        let permission = currentRuntimeDebugPermission()
        let helperURL = app.builtInPlugInsURL?.appendingPathComponent("HuskJITHelper.appex", isDirectory: true)
        let helperExists = helperURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let helper = helperURL.flatMap { Bundle(url: $0) }
        let helperID = helper?.bundleIdentifier
        let helperExtension = helper?.infoDictionary?["NSExtension"] as? [String: Any]
        let prefixMatches: String
        if let appID, let helperID {
            prefixMatches = helperID.hasPrefix(appID + ".") ? "符合" : "不符合：重新签名时需一起设置主 App 与扩展标识"
        } else {
            prefixMatches = "未知（缺少可读取的 bundle 标识）"
        }

        var lines = [
            "Husk Rebuilt · JIT 诊断报告 v1",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "系统构建：\(systemBuild())",
            "设备型号：\(HuskLog.deviceModel)",
            "App 版本：\(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知") (\(app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"))",
            "App bundle：\(appID ?? "未知")",
            "App 可执行文件：\(exists(app.executableURL))",
            "App 运行签名 get-task-allow：\(permission.description)",
            "App profile（仅本地材料，未验证 CMS 签名）：\(profile(in: app).description)",
            "",
            "JIT helper 包：\(helperExists ? "存在" : "缺失")",
            "JIT helper bundle：\(helperID ?? "未知")",
            "JIT helper 可执行文件：\(exists(helper?.executableURL))",
            "helper 标识从属主 App：\(prefixMatches)",
            "helper extension point：\(helperExtension?["NSExtensionPointIdentifier"] as? String ?? "未知")",
            "helper principal class：\(helperExtension?["NSExtensionPrincipalClass"] as? String ?? "未知")",
            "helper profile（仅本地材料，未验证 CMS 签名）：\(helper.map { profile(in: $0).description } ?? "无法读取 helper 包")",
            "helper 实际运行权限、主 App 与 helper 签名团队一致性：未知（此报告没有启动或验证 helper）",
            "",
        ]

        let frameworks = app.privateFrameworksURL
        let stikURL = frameworks?.appendingPathComponent("StikJIT.framework", isDirectory: true)
        let stikBundle = stikURL.flatMap { Bundle(url: $0) }
        lines += [
            "StikJIT.framework 包：\(exists(stikURL))",
            "StikJIT.framework bundle：\(stikBundle?.bundleIdentifier ?? "未知")",
            "StikJIT 可执行文件：\(exists(stikURL?.appendingPathComponent("StikJIT")))",
            "QEMU 动态库：\(exists(frameworks?.appendingPathComponent("libqemu-aarch64-softmmu.dylib")))",
            "ANGLE 动态库：\(exists(frameworks?.appendingPathComponent("libANGLE-shared.dylib")))",
            "框架代码签名与运行时加载：未知（文件存在不等于签名有效或能加载）",
            "",
            "本机配对文件：\(pairingSummary())",
            "LocalDevVPN 是否安装：\(LocalDevVPN.isInstalled ? "URL scheme 可打开" : "URL scheme 不可打开或未声明")",
            "LocalDevVPN 隧道、配对认证、DDI 下载/挂载：未执行；请运行分阶段设置检查",
            "调试器附加标记：\(JITBootstrap.debuggedFlag ? "是（此标记本身不证明 JIT 内存可执行）" : "否")",
            "JIT 内存已确认：\((JITBootstrap.prewarmed || JITBootstrap.isLive || JITBootstrap.mapJITResult == true) ? "是" : "否（未确认）")",
            "",
            "结论与建议：",
        ]

        switch permission {
        case .denied, .absent:
            lines.append("当前进程没有可确认的 get-task-allow=true。普通开发者调试连接可能因此失败；请使用匹配自身开发者证书和开发 profile 的签名，保留 App Extension，并在安装后再次读取运行签名。修改 bundle ID 本身不会授予此权限。")
        case .unknown:
            lines.append("此系统没有提供可靠的运行签名查询结果。需在签名后用 codesign 检查主 App 权限，并核对开发 profile；profile 或源码 entitlements 文件中的 true 不等于已安装 App 的实际权限。")
        case .allowed:
            lines.append("读取到了 get-task-allow=true；这只确认一个签名权限，不证明 helper 可启动、DDI 可挂载或 JIT 一定可启用。")
        }
        if !helperExists {
            lines.append("安装包缺少 HuskJITHelper.appex。请重新安装完整 IPA，并在签名工具中保留 App Extension。")
        }
        lines.append("配对文件通过结构检查也不代表属于当前设备或仍被当前系统接受。DDI 必须匹配实际系统，挂载和调试权限以分阶段检查的真实响应为准。")
        lines.append("本报告未附原始日志、私钥、配对标识、网络地址或设备 UDID。Android APK 兼容性和 JIT 可用性不能由这份报告保证。")
        return redact(lines.joined(separator: "\n"))
    }

    /// Error messages from networking/frameworks can contain addresses or raw
    /// pairing material. This is a conservative display filter, not a promise
    /// that arbitrary third-party logs are safe to publish. Exports use only
    /// the allowlisted fields constructed by snapshot().
    static func redact(_ text: String) -> String {
        // A third-party description may print a dictionary across several
        // lines. Removing just its private-key line could leave the pairing
        // identifier or an unlabelled continuation of the key in the report.
        if text.range(of: #"(?i)\b(?:private[_ -]?key|public[_ -]?key)\b"#,
                      options: .regularExpression) != nil {
            return "[消息包含配对密钥字段，内容已隐藏]"
        }
        var result = text
        let rules: [(String, String)] = [
            (#"(?is)-----BEGIN [^-]*(?:PRIVATE KEY|CERTIFICATE)[^-]*-----.*?(?:-----END [^-]+-----|$)"#, "[密钥或证书已隐藏]"),
            (#"(?is)(?:<\?xml\b[^>]*>\s*)?<plist\b[^>]*>.*?(?:</plist>|$)"#, "[plist 内容已隐藏]"),
            (#"(?is)<data\b[^>]*>.*?(?:</data>|$)"#, "[二进制数据已隐藏]"),
            (#"(?im)^.*\b(?:pairingData|pairingFileData|pairingIdentifier|identifier|HostID|SystemBUID|DeviceIdentifier|DeviceID|UniqueDeviceID|UDID)\s*[\"']?\s*[:=].*$"#, "[敏感配对或设备字段已隐藏]"),
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b|\b[0-9a-f]{40}\b|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#, "[设备或会话标识已隐藏]"),
            (#"(?<![A-Za-z0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9])"#, "[IPv4 已隐藏]"),
            (#"(?i)(?<![A-Za-z0-9:])(?:(?:[0-9a-f]{1,4}:){2,}[0-9a-f:]{0,39}|[0-9a-f]{1,4}::[0-9a-f:]{0,39}|::[0-9a-f:]{0,39})(?:%[A-Za-z0-9._-]+)?"#, "[IPv6 已隐藏]"),
            (#"(?i)(?:/private)?/var/mobile/(?:Containers|Library)/[^\s\"']+"#, "[设备容器路径已隐藏]"),
            (#"(?i)/(?:Users|home)/[^/\s]+"#, "[用户目录已隐藏]"),
            (#"(?i)<[0-9a-f\s]{32,}>"#, "[二进制数据已隐藏]"),
            (#"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{64,}={0,2}(?![A-Za-z0-9+/])"#, "[长编码数据已隐藏]"),
        ]
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        if result.count > 12_000 {
            result = String(result.prefix(12_000)) + "\n[消息过长，已截断]"
        }
        return result
    }

    // These documented C ABI signatures are resolved dynamically because the
    // iOS SDK does not consistently expose SecTask declarations to Swift.
    // No hard-linked private header, csops declaration, or signing bypass is
    // needed. A missing symbol or unreadable value is explicitly unknown.
    // Apple declarations: Security/sectask/SecTask.h in apple-oss-distributions.
    private typealias CreateTask = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEntitlement = @convention(c)
        (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?

    private static func currentRuntimeDebugPermission() -> RuntimeDebugPermission {
        guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL) else {
            return .unknown("Security 框架不可访问")
        }
        defer { dlclose(library) }
        guard let createSymbol = dlsym(library, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(library, "SecTaskCopyValueForEntitlement") else {
            return .unknown("运行签名查询符号不可用")
        }
        let create = unsafeBitCast(createSymbol, to: CreateTask.self)
        let copy = unsafeBitCast(copySymbol, to: CopyEntitlement.self)
        guard let created = create(nil) else { return .unknown("无法读取当前进程任务") }
        let task = created.takeRetainedValue()
        var error: Unmanaged<CFError>?
        let copied = copy(task, "get-task-allow" as CFString, &error)
        if let error {
            // Consume Copy's error ownership. Export no opaque error userInfo.
            _ = error.takeRetainedValue()
            if let copied { _ = copied.takeRetainedValue() }
            return .unknown("读取运行签名权限失败")
        }
        guard let copied else { return .absent }
        let value = copied.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return .unknown("权限值不是布尔类型")
        }
        return CFEqual(value, kCFBooleanTrue) ? .allowed : .denied
    }

    private static func profile(in bundle: Bundle) -> ProfileSummary {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProfileSummary(description: "未附带 profile", allowsDebugging: nil)
        }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return ProfileSummary(description: "存在，但无法安全读取", allowsDebugging: nil)
        }
        // Provisioning profiles are CMS envelopes. This extracts only their
        // embedded XML as unverified local metadata; it never claims CMS
        // validation, code-signature verification, or runtime authorization.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let dictionary = (try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil)) as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return ProfileSummary(description: "存在，XML 元数据无法解析；未验证", allowsDebugging: nil)
        }
        let debug = entitlements["get-task-allow"] as? Bool
        var description = "get-task-allow=\(debug.map { $0 ? "true" : "false" } ?? "未知")"
        if let expiration = dictionary["ExpirationDate"] as? Date {
            description += "；有效期截至 \(ISO8601DateFormatter().string(from: expiration))"
            if expiration < Date() { description += "（已过期）" }
        }
        return ProfileSummary(description: description, allowsDebugging: debug)
    }

    private static func exists(_ url: URL?) -> String {
        guard let url else { return "未知（无法定位）" }
        return FileManager.default.fileExists(atPath: url.path) ? "存在" : "缺失"
    }

    private static func pairingSummary() -> String {
        guard JITPairingFileStore.exists else { return "未保存" }
        let source: String
        switch JITPairingFileStore.source {
        case .onDevice?: source = "由本机配对流程保存"
        case .imported?: source = "导入文件（来源记录或旧版本默认值）"
        case nil: source = "来源未知"
        }
        guard let size = try? JITPairingFileStore.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 1024 * 1024,
              let data = try? JITPairingFileStore.data(),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            return "存在，但结构不合法或无法读取；\(source)"
        }
        return "结构合法；\(source)；未检查设备归属或认证有效性"
    }

    private static func systemBuild() -> String {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0,
              length > 0, length < 256 else { return "未知" }
        var buffer = [CChar](repeating: 0, count: length)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("kern.osversion", bytes.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return "未知" }
        return String(cString: buffer)
    }
}

/// The share button exports this allowlisted snapshot, not husk.log.
@MainActor
struct JITDiagnosticsPanel: View {
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("JIT 安装与签名诊断", systemImage: "stethoscope")
                .font(.headline)
            Text("显示本次安装能够读取的事实。未知状态需要设备实际检查；配对私钥、网络地址和设备 UDID 不会加入报告。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    report = JITDiagnostics.snapshot()
                    copied = false
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
                ShareLink(item: report) { Label("导出报告", systemImage: "square.and.arrow.up") }
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: { Label(copied ? "已复制" : "复制", systemImage: "doc.on.doc") }
            }
            .buttonStyle(.bordered)
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .onAppear { report = JITDiagnostics.snapshot() }
    }
}
