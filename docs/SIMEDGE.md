# Simedge 一键连接 / Bridge v1

## 使用

1. 安装并打开配套「秒新加湿器」构建 9 或更新版；保留原签名身份、Bundle ID 可覆盖旧版。
2. 在 App 内用原有流程完成首次蓝牙配网。手机热点开启「最大兼容性」，以后保持热点名称和密码不变。
3. 在 App 首页开启「允许 Simedge 一键连接」（默认关闭）。这仅允许本机配套工具请求建立连接，不允许开机、改风量或传递任意命令。
4. 手动编译并安装配套 Simedge 源码，在其「快捷工具、URL 与快捷指令」添加「连接秒新 A3」。也支持经典 FV 工具列表、侧栏收藏、快捷仓和已有的动作选择方式。
5. 手机解锁时点击工具。连接成功会打开控制首页；请让 App 保持前台。本轮最长 10 分钟，结束后关闭热点。

## 流程与限制

- 先确认 App 已安装、支持协议并允许接入，再改热点，避免安装旧版 App 时无故断网。
- 关闭热点并读回配置状态，稳定 0.75 秒后通知 App 准备 DNS 53 / HTTP 80 / MQTT 1883。
- App 确认本地服务已就绪，Simedge 才开启热点及可发现状态，并再次读回配置。
- 读回不代表底层无线服务或 A3 已连接；最终成功只能由 App 原有验证逻辑确认设备状态和签名。
- 已有可控制的 A3 连接时直接打开控制页，不重复断开热点。其他正在运行的手动/快捷指令连接不抢占，会提示先结束本轮连接。
- 尝试标准的后台唤醒；1.5 秒内没有回应则前台兜底，整个流程到 12 秒仍未结束时也提前打开 App，避免依赖无限后台执行。具体 iOS 后台预算不可保证。
- App/Simedge 总流程约 110 秒上限；拒绝重复点击。失败、锁屏或取消会停止本轮服务，并尝试在 8 秒内恢复进入本轮前的热点配置；无法读回恢复状态时明确提醒手动检查。
- 不会修改热点名称、密码、蜂窝网络、最大兼容性或 A3 运行参数。热点切换会短暂断开其他客户端，建议热点只连接 A3。

## 消息约定

固定请求名：`com.honanq.airwater.simedge.v1.request`。

Simedge 保持 `notify_register_check` token，通过 `notify_set_state` 发布 64 位请求：`(unixSeconds << 32) | random32`，再 `notify_post`。App 启动/恢复前台时也读取 pending state，防止冷启动错过通知。请求接受窗口为过去 120 秒、未来最多 5 秒。

每轮前缀：`com.honanq.airwater.simedge.v1.<16位小写十六进制请求编号>`。

| 发送方 | 后缀 | 含义 |
| --- | --- | --- |
| App | `.accepted` | 用户允许、当前连接未占用，已注册本轮控制通知 |
| Simedge | `.hotspot-off` | 热点配置读回为关闭；允许开始准备服务 |
| App | `.ready` | 原有 `prepare()` 成功，本地监听就绪 |
| Simedge | `.hotspot-on` | 热点启用且可发现配置读回为开；允许等待设备 |
| App | `.connected` | `finish()` 完成且 `canControl` 为真；或已有有效连接 |
| App | `.failed` | notify state 为错误码：1 未授权、2 连接占用、3 服务准备失败、4 等待超时、5 取消、6 通道不可用、7 后台过期、8 热点错误 |
| Simedge | `.cancel` / `.hotspot-error` | 取消本轮或热点错误，App 清理自己拥有的会话 |

URL：`a3local://simedge/connect?request=<编号>` 为启动兜底，只有匹配实时 pending state 才受理；`a3local://simedge/show` 只返回首页，不创建连接。常规前台打开优先复用 Simedge 既有的单窗/多窗全屏交接通道，避免 URL 被小窗模式拦截。通过 URL scheme 解析应用标识，不写死重签后的 Bundle ID。

通知仅携带状态与关联编号，**不携带密码、设备 key、设备 ID 或任意命令**。随机编号隔离旧回调，**不是安全认证**；Darwin 通知是本机软件可访问的通道，应只在信任本机软件时开启授权。App 取消只清理自己拥有的连接，不抢占无关流程。

## 系统接口与验收

Simedge 动态加载 `Preferences.framework`，只在 `PSHotspotModeSettingsDetail` 的 `deviceSupportsPersonalHotspot`、`isEnabled`、`isDiscoverable`、`setEnabled:`、`setDiscoverable:` 均存在且签名匹配时调用；缺失时失败，不猜测其他选择器。依据 iOS 17.0.3 公开 runtime headers；未在用户的 iOS 17.1.1 上执行热点验收。

验收请检查：App 未授权/未安装、冷启动、后台/前台、热点原开/原关、重复点击、A3 断电、锁屏、手动取消与已连接情况。确认连接成功仍未改变加湿器电源/模式，故障时热点回到原状态。只有用户实机测试才能确认此设备和越狱环境的私有接口兼容。
