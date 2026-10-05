# AetherRoute 1.2.1 / 1.3.0 实施方案：看得清、管得住

> 状态：**已定稿并开工（2026-10-05）**。1.2.1 已发布；M0 已完成（结论见 4.1）。
> 范围：仅 macOS；iOS 同步另行安排。
> 拆分：订阅流量与到期提醒先作为 **1.2.1** 单独发布；来源 App 识别与按 App 分流作为 **1.3.0** 发布。

## 0. 决策记录

| # | 问题 | 决定 | 理由 |
|---|---|---|---|
| D1 | 应用规则与自定义规则的优先级 | **应用规则 > 自定义规则 > 配置中的规则** | "让某个 App 直连/走代理"是用户最明确的意图，应当覆盖针对域名的规则；与 Surge 的使用习惯一致 |
| D2 | TUN 模式识别不了进程怎么办 | 先做技术验证（M0）；**验证不通过则接受"按 App 分流只在透明代理模式生效"**，界面明确提示 | 透明代理本来就是推荐的默认模式，系统能可靠提供来源 App；不为 TUN 引入额外权限或不稳定的实现 |
| D3 | 流量/到期提醒方式 | **App 内提醒默认开启**（订阅卡片、菜单栏面板）；**系统通知可选、默认关闭**，开启时才申请通知权限 | 不打扰、不在首次使用时就弹权限请求；需要的人可以打开 |
| D4 | 发布节奏 | 订阅流量先发 **1.2.1**；其余功能发 **1.3.0** | 订阅流量独立、风险低、用户收益立竿见影；拆开后 1.3.0 的验证范围更集中。两个版本之间先恢复虚拟机 `macos27` |

## 1. 背景与目标

与主流客户端（Clash Verge Rev、Mihomo Party、Surge、Stash 等）相比，AetherRoute 在系统集成、协议验证、安全与稳定性上已经持平或领先，但在**日常可见性与可控性**上有三处用户每天都能感受到的差距：

| 差距 | 用户场景 | 主流客户端 |
|---|---|---|
| 连接页看不到是哪个 App 发起的连接 | "为什么这个 App 不走代理 / 为什么这么多流量" | Verge、Surge 显示进程名与图标 |
| 没有"按 App 分流"的界面 | "让微信始终直连、让 Claude 始终走代理" | Surge、Stash 的核心功能 |
| 不显示订阅的已用流量和到期时间 | "我的机场还剩多少流量、什么时候到期" | 几乎所有 Clash 客户端都显示 |

目标是补齐这三项，并把"按 App 分流"做成 AetherRoute 的特色：macOS 透明代理本身就能可靠地识别每条连接的来源 App，这是基于 TUN 的客户端不容易做好的。

**非目标**：MITM 解密、请求改写、脚本、开放网页控制面板（风险高、与"安全省心"的定位冲突）；uTLS 浏览器指纹（单独评估，计划 1.4）；iOS 同步。

## 2. 现状调研结论

| 项目 | 现状 | 依据 |
|---|---|---|
| 透明代理的来源 App | 系统为每条流提供 `NEFlowMetaData.sourceAppSigningIdentifier`（非可选）与 `sourceAppAuditToken`（可能为空），目前只用于识别 AetherRoute 自身的流量 | `Sources/AetherRouteTransparentProxySupport/TransparentProxySelfIdentityGuard.swift` |
| 透明代理的进程规则 | 引擎对透明代理流量**主动拒绝** `PROCESS-NAME` / `PROCESS-PATH`（配置加载报错） | `Core/Engine/clash-lib/src/embedded_flow.rs` |
| 流创建接口 | `clash_flow_tcp_create` / `clash_flow_udp_create` 只传源、目标地址 | `Core/Engine/clash-ffi/src/flow_ffi.rs` |
| TUN 的进程识别 | 引擎 `process` 特性（`sock2proc`）在两份发布核心中都**关闭**；主程序与两个扩展均启用 App Sandbox，能否读取其他进程信息未验证 | `clash-lib/Cargo.toml`，`scripts/build_core.sh`、`scripts/build_direct_core.sh`，`Config/*.entitlements` |
| 连接遥测 | 格式 v1（魔数 `ART1`），每条连接含传输层、目标、端口、上下行、开始时间、规则、规则载荷、代理链；TUN 与透明代理共用同一个编码函数 | `flow_ffi.rs` `encode_telemetry_snapshot`，`clash-ffi/src/lib.rs` `clash_packet_telemetry_snapshot_v1`，`Sources/AetherRouteKit/NetworkTelemetry.swift` |
| 规则解析 | 规则行按逗号切分，载荷中不能直接含逗号 | `clash-lib/src/config/internal/rule.rs`（`split_rule_tokens`） |
| 自定义规则 | DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / GEOIP 等，优先级最高，策略为直连/拒绝/指定代理，经 `DomesticRoutingOptimizer.optimizedProfile(for:customRules:)` 注入 | `Sources/AetherRouteKit/CustomRule.swift`、`DomesticRoutingOptimizer.swift` |
| 订阅响应头 | 下载订阅时已保存全部 HTTP 响应头，未解析 `subscription-userinfo` | `Sources/AetherRouteKit/ProfileSubscription.swift`（`ProfileSubscriptionHTTPResponse.headers`） |
| 系统通知 | App 已有申请通知权限、发送本地通知的代码 | `Sources/AetherRouteApp/AppAutomationController.swift` |

---

## 3. 1.2.1：订阅流量与到期提醒

### 3.1 用户体验

- **配置页订阅卡片**：
  - 进度条：已用 / 总量（上传 + 下载），右侧显示"剩余 xx GB"；
  - 到期：显示日期与剩余天数（"2026-11-30 到期 · 还剩 56 天"）；没有到期信息时不显示这一行；
  - 底部小字："数据来自订阅服务商，更新于 x 分钟前"。
- **提醒（App 内，默认开启）**：剩余流量 < 10% 或距到期 ≤ 3 天时，卡片标为橙色并显示提示；已到期或流量用尽时标为红色。菜单栏面板顶部显示一行同样的提示，点按跳到配置页。
- **系统通知（可选，默认关闭）**：设置 › 通用 新增"订阅即将到期或流量不足时通知我"。开启时才申请通知权限；同一订阅、同一类提醒每 24 小时最多一次。
- 服务商没有提供这些信息时，卡片保持现状，不显示空的进度条。

### 3.2 技术方案

- **解析**：新增 `SubscriptionUsage`（`AetherRouteKit`）：
  ```swift
  public struct SubscriptionUsage: Codable, Equatable, Sendable {
      public let uploadBytes: UInt64?
      public let downloadBytes: UInt64?
      public let totalBytes: UInt64?
      public let expiresAt: Date?        // expire=0 或缺失视为无到期日
      public let reportedAt: Date        // 获取时间
  }
  ```
  `subscription-userinfo` 的格式为 `upload=…; download=…; total=…; expire=…`：键不区分大小写，允许多余空格，`;` 或 `,` 分隔；非数字、负数和溢出的值忽略单个字段，不影响订阅更新本身。
- **保存**：`ProfileSubscription` 新增可选字段 `usage: SubscriptionUsage?`，缺失时按 nil 解码（兼容旧数据）；每次成功下载订阅时，用最新响应头更新；304（未修改）时保留原值，只更新 `reportedAt`。
- **顺带支持**：
  - `profile-update-interval`（单位小时，范围 1–168）：用户没有自定义时，作为该订阅的默认自动更新间隔；
  - `content-disposition` 中的文件名（含 RFC 5987 的 `filename*=`）：作为新订阅的默认名称，已有名称的不覆盖。
- **提醒判断**：`SubscriptionUsageAlertPolicy`（纯函数，可单测）：输入用量和当前时间，输出 `none / low / expiring / exhausted / expired`。

### 3.3 涉及文件

`Sources/AetherRouteKit/ProfileSubscription.swift`（解析与保存）、新增 `SubscriptionUsage.swift`；`Sources/AetherRouteApp/ProfilesPageView.swift`（卡片）、菜单栏面板（`AetherRouteApp.swift`）、设置页通用分组、`AppAutomationController.swift`（复用通知）；`Localizable.xcstrings`。

### 3.4 验收标准

- 单元测试覆盖：完整头、缺字段、大小写/空格/逗号、`expire=0`、超大值与负数、非法字符；`profile-update-interval` 越界；`filename*=` 解码；提醒策略的边界（剩余 10%、到期前 3 天、已过期）；旧数据解码。
- 用本地测试服务器返回不同响应头，端到端验证卡片显示与刷新（UI 自动化或截图核对）。
- 完整发布 SOP（含虚拟机矩阵，见第 6 节）。

---

## 4. 1.3.0：来源 App 识别与按 App 分流

### 4.1 M0：技术验证（决定 TUN 的范围）

在实现前用 1–2 天验证，结论回填到本节：

| 问题 | 验证方法 | 通过标准 |
|---|---|---|
| 沙盒内的 Packet Tunnel 扩展能否按五元组查到进程 | 在扩展内调用 `sysctl net.inet.tcp.pcblist_n` 与 `proc_pidpath`（或临时启用 `sock2proc`），对 curl、Chrome、Safari 的连接取样 | 能拿到 pid 与可执行路径；不新增敏感权限 |
| 查询开销 | 每条新连接查一次，测 p50 / p95 | p95 < 1 ms；超过则改为异步查询，只用于展示、不参与路由 |
| 透明代理审计令牌转路径 | 扩展内由审计令牌取 pid，再取路径 | 能拿到时补充路径；拿不到时只用签名标识，功能不受影响 |
| 签名标识覆盖率 | 统计常用 App（浏览器、Electron、命令行工具、系统服务）的签名标识形态 | 归并规则覆盖主流 App；无签名的命令行工具有合理显示名 |

按 D2 决策：TUN 全部通过 → TUN 同样支持识别与应用规则；只能查到但慢 → TUN 只展示、不分流；查不到 → TUN 显示"未知应用"，按 App 分流要求透明代理。

#### M0 结论（2026-10-05，本机 macOS 27，ad hoc 签名 + App Sandbox 的最小 .app 探针）

| 问题 | 结果 |
|---|---|
| 沙盒内读取 `net.inet.tcp.pcblist_n` | ✅ 可以，读到完整列表（约 190 KB、309 个 TCP 套接字）。**非沙盒**的普通命令行进程反而只拿到 48 字节的空表；网络扩展运行在沙盒中，正好可用 |
| 按本地端口找到所属进程 | ✅ 按记录自带的长度与类型（`XSO_INPCB` / `XSO_SOCKET`）逐条遍历，`xinpcb_n` 偏移 18 为本地端口，`xsocket_n` 偏移 68 为 `so_last_pid`；对一个限速下载中的 curl，找回的 pid 与实际一致 |
| 沙盒内 `proc_pidpath` 读取其他进程 | ✅ 可以（`/usr/bin/curl`、`/sbin/launchd`）；透明代理的审计令牌 → pid → 路径同样可行 |
| 公开 API 枚举进程（`proc_listallpids` + `PROC_PIDFDSOCKETINFO`） | ❌ 沙盒内返回 0 个进程，不能作为方案 |
| 开销 | 整表读取 0.53 ms，遍历 0.02 ms；满足 p95 < 1 ms 的门槛。实现时按"新连接触发、短时间内复用同一份表"处理，避免每条连接都整表读取 |

**决定**：TUN 走"解析 `pcblist_n`（TCP/UDP 各一份）→ `so_last_pid` → `proc_pidpath`"的路线，支持识别与应用规则，不新增任何权限。私有结构的两个偏移量写成常量并加入运行时自检：读到的端口或 pid 不合理时，整份表视为不可用并显示"未知应用"，不影响路由。最终在 M2 / M4 的真机（root 身份的系统扩展）上再确认一次；若真机结论不同，按上表的降级方案执行。

### 4.2 来源 App 链路（M2）

**接口：扩展 → 引擎**（新增，保留 v1）

```c
int clash_flow_tcp_create_v2(engine,
    const uint8_t *source_endpoint, size_t source_endpoint_length,
    const uint8_t *destination_endpoint, size_t destination_endpoint_length,
    const uint8_t *source_app, size_t source_app_length,   // 可为空
    ClashFlowHandle **output);
// clash_flow_udp_create_v2 同理
```

`source_app` 编码：魔数 `ASA1` | u16 签名标识长度 | 签名标识 | u16 路径长度 | 路径（大端）。签名标识与路径各上限 512 字节，必须是合法 UTF-8；格式不对时返回 `CLASH_FLOW_INVALID_ARGUMENT`，扩展回退为不带来源 App 的 v1 调用并记录诊断计数。

**引擎**
- `Session` 新增 `source_app: Option<SourceApp { signing_identifier, executable_path }>`；跟踪连接时一并保存。
- TUN（视 M0）：在新连接建立时按五元组查询，结果写入同一字段；查询失败为 `None`。

**遥测 v2**（新增 `clash_flow_telemetry_snapshot_v2` / `clash_packet_telemetry_snapshot_v2`，保留 v1）
- 魔数 `ART2`；每条连接在 v1 的四个字符串之后追加两个长度字段与内容：`app_identifier`、`app_path`（各上限 512 字节，沿用现有的非 UTF-8 清理与截断）；总大小上限不变（1 MiB）。
- Swift 侧 `NetworkTelemetrySnapshot.decode` 同时支持 `ART1` / `ART2`；`ConnectionTelemetry` 新增可选的 `sourceApp`。App 优先调用 v2，扩展不支持时回退 v1。

**App 展示**
- `SourceAppResolver`（`AetherRouteKit`，带缓存）：
  1. 由可执行路径向上找到最外层 `.app`；
  2. 没有路径时，用签名标识在已安装 App 中查找（`NSWorkspace.urlForApplication(withBundleIdentifier:)`），辅助进程按前缀归并（`com.google.Chrome.helper` → `com.google.Chrome`）；
  3. 内置映射表处理系统代发：`com.apple.WebKit.Networking` → Safari，`com.apple.nsurlsessiond` 显示为"系统后台下载"；
  4. 都找不到时显示进程名或签名标识。
- 图标与显示名用 `NSWorkspace` 获取并缓存；只在主 App 中解析，扩展不做文件系统查询。

**连接页**
- 新增"应用"列（图标 + 名称，悬停显示签名标识与路径）；无法识别显示"未知应用"，悬停说明原因。
- 视图切换：按连接 / 按应用（每个 App 一行：连接数、上下行合计，可展开）。
- 应用筛选；右键菜单"此应用始终直连 / 始终走代理 / 始终拒绝"。

### 4.3 按 App 分流（M3）

**数据模型**（`AetherRouteKit`）

```swift
public struct ApplicationRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var bundleIdentifier: String
    public var bundlePath: String          // 用于路径匹配与显示
    public var displayName: String
    public var policy: CustomRulePolicy    // 直连 / 拒绝 / 指定策略组
    public var isEnabled: Bool
}
```

保存在 `CustomRuleStore` 的独立列表中（新增字段，缺失按空列表解码），上限 200 条。

**规则编译**
- 引擎新增内部规则 `AETHER-APP`，仅由 App 生成：
  `AETHER-APP,<bundleIdentifier>;<百分号编码的 bundlePath>,<policy>`
  （载荷里的路径做百分号编码，避开规则解析按逗号切分的问题。）
- 匹配条件（任一成立）：会话签名标识等于 `bundleIdentifier`，或以 `bundleIdentifier.` 开头；可执行路径以 `bundlePath + "/"` 开头。不会把 `com.google.ChromeX` 误判为 `com.google.Chrome`。
- 生成运行配置时，按 D1 把应用规则放在最前：应用规则 → 自定义规则 → 国内优化规则 → 配置自带规则。
- 用户 YAML 里出现 `AETHER-APP` 时导入校验拒绝，避免外部配置伪造。

**兼容 mihomo 规则**
- 透明代理流量支持配置自带的 `PROCESS-NAME`（匹配可执行文件名）、`PROCESS-PATH`（完整路径）、`PROCESS-PATH-REGEX`，用会话里的来源 App 信息匹配，不再加载报错。
- 只有签名标识、没有路径时，`PROCESS-PATH*` 不匹配，`PROCESS-NAME` 退而用签名标识的最后一段比较。

**规则页**
- "应用规则"分组位于"自定义规则"之上，标题旁注明"优先级最高"。
- 添加流程：从"最近联网的应用"（连接页记录的最近 50 个 App）中选择，或用文件选择器选 `.app`；选择策略；保存后下次连接生效（连接中修改与自定义规则的现有生效方式一致）。
- 当前为 TUN 且 M0 不通过时，分组顶部显示"按应用分流需要透明代理模式"，并提供"切换到透明代理"按钮。
- 路由预览存在应用规则时提示"结果还取决于发起请求的应用"。

### 4.4 隐私

- 来源 App 信息只在本机内存和本地配置中使用，不上传、不进入遥测之外的日志。
- 诊断报告默认不包含 App 信息；导出时提供"附带应用信息"勾选项，默认不勾选。

### 4.5 涉及文件

| 位置 | 改动 |
|---|---|
| `Sources/AetherRouteTransparentProxy*/` | 建流时读取签名标识与审计令牌，调用 `*_create_v2` |
| `Core/Engine/clash-ffi/src/flow_ffi.rs`、`lib.rs` | `*_create_v2`、`*_telemetry_snapshot_v2`、`ASA1` / `ART2` 编解码 |
| `Core/Engine/clash-lib/src/session.rs`、`embedded_flow.rs`、`app/router/rules/` | `SourceApp`、`AETHER-APP`、透明代理下的 `PROCESS-*` |
| `Core/Engine`（TUN，视 M0） | 五元组查进程（`sock2proc` 或自研最小实现） |
| `Core/Headers/clashrs.h` | 新增接口声明 |
| `Sources/AetherRouteKit/NetworkTelemetry.swift`、新增 `SourceAppResolver.swift` | v1/v2 解码；App 归并与映射 |
| `Sources/AetherRouteKit/CustomRule.swift`、`CustomRuleStore.swift`、`DomesticRoutingOptimizer.swift`、`ProfileImportValidator.swift` | 应用规则模型、存储、编译顺序、拒绝外部 `AETHER-APP` |
| `Sources/AetherRouteApp/ConnectionsPageView.swift`、`ConnectionTableItem.swift`、`RulesPageView.swift`、`SupportDiagnosticsView.swift` | 应用列、分组、筛选、右键菜单；应用规则分组；诊断导出选项 |
| `Localizable.xcstrings`、`HelpTopics.swift` | 文案与帮助（TUN 限制、Safari 映射、优先级） |
| `Config/ProtocolCoreEvidence.json`、许可证清单 | 引擎变更后同步；启用 `sock2proc` 时补许可证审查 |

### 4.6 测试与验收标准

**引擎单元测试**
- `ASA1` 编解码：正常、空、超长、非 UTF-8、截断；v1 接口行为不变。
- 来源 App 从建流到遥测的完整链路；`ART2` 编码上限与清理。
- `AETHER-APP` 匹配：相等、前缀（含不误匹配同名前缀）、路径前缀、百分号编码路径（含逗号、空格、中文）。
- 透明代理下 `PROCESS-NAME` / `PROCESS-PATH` / `PROCESS-PATH-REGEX` 加载并生效。

**App 单元测试**
- `ART1` / `ART2` 解码与回退；`SourceAppResolver` 的归并、映射表与缓存。
- 应用规则存储兼容、上限、编译顺序（位于最前）、策略生成；导入校验拒绝 `AETHER-APP`。

**端到端验收**（扩展 `scripts/test_runtime_acceptance.sh`，透明代理与 TUN 各跑一次）
- **来源识别**：用 curl 发请求，通过 QA 自动化接口读取遥测，确认连接归属 curl。
- **应用分流**：给 curl 加"直连"规则，出口 IP 应为本地宽带 IP；改为"走代理"后应为节点 IP；删除规则后恢复原行为。
- TUN 的预期结果按 M0 结论写定（不支持时，断言连接显示"未知应用"、应用规则不生效且界面有提示）。

**性能**：透明代理建流耗时增加 < 0.1 ms（p95）；TUN（若支持）新连接查询 p95 < 1 ms；遥测 v2 单次快照大小在 128 条连接时不超过 v1 的 1.5 倍。

**发布门禁**：完整 SOP（本地回归、协议互通门禁、虚拟机 6 维矩阵、Mac mini 真机双模式、公证发布）。

---

## 5. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| TUN 下无法识别进程（沙盒限制） | TUN 用户没有按 App 分流 | M0 先验证；按 D2 诚实提示需要透明代理 |
| 进程查询拖慢新连接 | 首包延迟增加 | p95 < 1 ms 为门槛，超出改异步、只展示 |
| 归并不准（辅助进程、系统代发） | 规则对某些 App 不生效 | 前缀 + 路径双重匹配、内置映射表；连接页显示真实进程便于自查 |
| 遥测与建流接口升级 | App 与扩展版本不一致时出错 | v1/v2 并存、按能力回退；扩展与 App 同版本发布 |
| 外部配置伪造 `AETHER-APP` | 绕过用户意图 | 导入校验拒绝；只由 App 在生成运行配置时注入 |
| 隐私 | 连接记录包含 App 信息 | 仅本机使用；诊断默认不含，需用户勾选 |
| 订阅信息格式不规范 | 显示错误数值 | 宽松解析、异常字段忽略，不影响订阅更新 |
| 虚拟机未恢复 | 发布验证不完整 | 1.2.1 发布前恢复 `macos27`；否则沿用 1.2.0 的真机替代方案并写入例外说明 |

## 6. 里程碑与节奏

| 阶段 | 内容 | 预计 | 产出 |
|---|---|---|---|
| P0 | 恢复虚拟机 `macos27`（下载固件、创建、维护者完成界面设置与扩展批准） | 0.5 天（含等待） | 可用的虚拟机矩阵 |
| M1 | 订阅流量与到期提醒 | 1 天 | **发布 1.2.1** |
| M0 | 技术验证，回填 4.1 结论 | 1–2 天 | TUN 范围定稿 |
| M2 | 来源 App 链路与连接页 | 2–3 天 | 可在开发版中看到来源 App |
| M3 | 按 App 分流、`PROCESS-*` 兼容、规则页 | 2–3 天 | 应用规则可用 |
| M4 | TUN 支持（视 M0）、端到端验收脚本、帮助文案 | 1–2 天 | 验收脚本覆盖两种引擎 |
| M5 | 完整发布流程 | 0.5–1 天 | **发布 1.3.0** |

每个阶段结束都运行本地回归与协议互通门禁；涉及 `Core/Engine` 的改动在提交前运行互通门禁（AGENTS.md 要求）。
