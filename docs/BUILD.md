# 构建与安装 / Build and install

此 fork 提供源码与 GitHub Actions 生成的未签名 IPA；没有 App Store 或 TestFlight 分发。安装 IPA 或从源码运行都需要自己的 Apple 开发签名；仓库不包含他人的证书或描述文件。

## 环境

- macOS 和 Xcode 27（包含 iOS 27 SDK）。源码引用 iOS 27 的条件 API；把部署目标设为 iOS 16 不代表旧 SDK 能编译。
- XcodeGen。安装方式参见 [XcodeGen 官方说明](https://github.com/yonaskolb/XcodeGen)。
- Python 3，用于快捷指令生成和发布目录检查。
- 工程部署目标为 iOS 16；实际设备记录仅覆盖 iPhone 17 Pro Max / iOS 27.0。旧系统运行和快捷指令兼容性尚未确认。

## 生成工程

```sh
git clone https://github.com/sudoHG/airwater-a3.git
cd airwater-a3
make generate
open AirwaterProbe.xcodeproj
```

在 Xcode 的 Signing & Capabilities 选择自己的 Team，并把 Bundle Identifier 改为自己的唯一标识。也可以先修改 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 再生成；重新生成工程会覆盖只在 Xcode 中修改的设置。不要把个人签名信息加入提交。

用数据线连接并解锁 iPhone，在 Xcode 选择这台手机后运行。按系统要求启用开发者模式、信任签名。不同开发账号的签名有效期与能力由 Apple 决定；源码开源不会消除这些限制。

Mac 只负责编译和 USB 安装，保持现有网络，不加入 iPhone 热点，不改 Mac 的 Wi-Fi、DNS 或路由。模拟器可用于界面/编译检查，不能验收真实 A3 的蓝牙及个人热点连接。

## 可选：生成快捷指令

`Shortcuts/` 包含可审查的 XML 模板，个人 Team ID 已替换成占位符。用与安装版相同的 Bundle ID 和 Team ID 生成：

```sh
python3 scripts/prepare_shortcuts.py \
  --bundle-id com.example.airwater \
  --team-id YOURTEAMID \
  --sign
make generate
```

`YOURTEAMID` 是示意值，请替换成自己的 10 位 Team ID。`--sign` 调用 macOS 自带的 `shortcuts sign`；可能需要本机 Shortcuts/iCloud 的正常配置。脚本仅生成和签名文件，不执行快捷指令、不切换任何网络。生成的个人文件受 `.gitignore` 排除。签名失败时可在 iPhone 上手动建立流程。

重新构建后，App 内可分享/添加「连接 A3」快捷指令。首次允许 Shortcuts 调用 App。编译成功不能保证换签名后的自动化在另一台手机上已验证。

手动建立一个名为「连接 A3」的快捷指令，顺序为：

1. 系统「设定个人热点」：关闭。
2. 本 App「准备 A3 连接」。
3. 系统「设定个人热点」：打开。
4. 本 App「打开 A3 控制页」，将「连接编号」绑定到第 2 步输出。

只想手动控制时，可以跳过快捷指令：关闭手机热点 → App 中「手动连接 / 准备本地服务」→ 服务就绪后开启手机热点 → 返回 App。首次需在手机系统设置中开启热点的「最大兼容性」，再使用 App 的蓝牙配网页交给 A3 热点名称和密码。

## 验证

```sh
make check
make build
```

`make check` 检查待公开文件、敏感文件类型、模板结构和隐私清单。它不是完整秘密扫描或真机测试。

`make build` 生成工程并执行不签名的 iOS 编译；默认要求 Data 卷至少空余 80 GiB，构建目录为 `.derivedData/opensource`。它不会安装、启动 App、改变网络或向 A3 发送命令。构建结束且没有相关编译进程使用该目录后，可删除这一任务目录释放空间。

2026-10-22 已用 Xcode 27.0 / iOS 27 SDK 验证该公开工程的 `make build` 成功；未做新的真机控制测试。快捷指令模板已使用示例身份生成并检查动作顺序与参数引用，未对公开版本执行签名或手机导入验收。

现有 `--run-self-check` 是仅解析器/合成数据检查；它在 App 沙盒写入结果。`--run-connection-checks` 会实际绑定网络监听端口，不能把它当作纯离线测试。调试参数 `--verify-power-roundtrip` 会真实改变设备电源；不要作为安装或验证默认参数，也不要在缺水、脏污或状态不明的设备上运行。正常无参数启动不会自动执行这些测试。

## iOS 17 首页交互修复（构建 8）

首页原先在 `body` 中创建 `bluetooth.$status.removeDuplicates()` 并通过 `onReceive` 写入会话日志。新订阅会立即收到当前状态；日志发布 `events` 后又会触发页面刷新。旧版 SwiftUI 若重建该订阅，可形成刷新和同步写盘的反馈环，表现为首页显示后点击无响应。`removeDuplicates` 只在同一次订阅内去重，无法防止这个跨订阅问题。

修复改用 iOS 16 起可用的 `onChange(of:)` 监听实际状态变化，首次出现时仅记录一次初始状态；会话层额外保存最近蓝牙状态，重复值不再发布日志或写盘。未改变连接协议、控制权限或热点流程。

构建 8 的 4 项单元测试和 2 项 UI 测试已在 iOS 27.0 模拟器通过；用户随后确认 iOS 17.1.1 首页恢复可点击。按用户要求，构建 9 移除这些测试源码、测试 target 和 CI 测试步骤，保留修复本身及发布目录检查。

## Simedge 一键连接（构建 9）

App 显示名称改为「秒新加湿器」，使用原创蓝青渐变水滴图标；Bundle ID、URL scheme 与 Keychain 服务名不变，便于原签名覆盖安装。

首次完成原有蓝牙配网，并开启首页「允许 Simedge 一键连接」。在配套 Simedge 的「快捷工具、URL 与快捷指令」中添加「连接秒新 A3」。后续无需苹果快捷指令，由 SpringBoard 端关闭热点 → App 准备本地服务 → SpringBoard 开启热点 → App 等到经过验证的设备报告 → 打开控制页。

两端只交换带短时请求编号的 Darwin 通知，绝不交换热点密码或设备 key，不启动加湿、不改模式和风量。不支持的系统热点接口、未安装配套 App、未授权、连接占用、锁屏或超时会明确失败；失败后尝试恢复本次操作前的热点状态。通知编号用于隔离旧回调，不是认证机制；仅在信任本机软件时开启接入。

优先尝试后台唤醒，但不使用强制常驻或无限后台权限。冷启动不支持或后台时间不足时，会提前打开 App 继续连接，所以不能保证所有设备都只在成功后才显示 App。连接成功仍需 App 在前台维持本地控制，每轮上限 10 分钟。

详细协议和接入步骤见 [Simedge 连接协议](SIMEDGE.md)。Simedge 部分依赖越狱环境的私有系统接口，需用户手动编译并在自己的 iOS 17.1.1 设备验收；IPA 编译成功不等于热点链路已实测。

## English quick guide

Use Xcode 27, XcodeGen and Python 3. Run `make generate`, open the generated project, set your own development team and unique bundle identifier, and install over USB. Keep the Mac on its existing network. No pre-signed app is distributed.

For the optional shortcut, run `scripts/prepare_shortcuts.py` with the **same** bundle/team identifiers and `--sign`, regenerate the project, then rebuild. Alternatively create the four-action workflow on the iPhone: hotspot off → Prepare A3 Connection → hotspot on → Open A3 Control Page (pass the preparation token). The manual connection path also works without Shortcuts.

`make build` compiles without signing, installation or device/network operations. Only one iPhone/iOS/A3 combination has historical hardware validation; compilation is not a hardware compatibility test.
