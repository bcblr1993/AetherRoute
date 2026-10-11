# AetherRoute 1.6.0 实施计划：节点故障转移

2026-10-11。目标：节点出问题时自动切到可用节点，并且用户能看到发生了什么、可以信任它。引擎（`Core/Engine`）与系统扩展不改动，全部在 App 侧完成。

## 1. 现状（已核实）

- 选择型（`select`）分组只有一个"自动选择最快节点"开关，开启后：
  - 每 15 秒检查一次当前节点：活动延迟加 Google 204 数据面探测。
  - 失败就重新测速，切到最快的可用节点。
  - 代码位置：`TunnelManager+Telemetry.swift` 的 `refreshAutomaticRouteHealth`，以及 `TunnelManager+ProxySelection.swift` 的 `selectFastestAvailableProxy`。
- 缺口：
  1. 自动切换后没有关闭坏节点上的旧连接。`closeConnectionsAfterProxySwitch` 只在手动切换时调用，应用的长连接会一直卡到超时。
  2. 没有"首选节点"的概念。只能追最低延迟，延迟一波动就跳节点，打断长连接。
  3. 切换没有任何提示或记录。
  4. 只在 MATCH 分组上一定有巡检。其他开了自动的分组，要等访问过代理页才会被纳入巡检。
  5. 菜单栏面板在自动模式下仍可点选节点，与代理页、命令面板的行为不一致。
  6. 单次探测失败就立即重选，没有"再确认一次"，偶发抖动也会切走。

## 2. 产品设计

### 2.1 节点选择方式（每个选择型分组三选一）

| 模式 | 行为 |
|---|---|
| 手动 | 用户点选节点，坏了也不自动换。与现在一致，并保持现有测试"手动钉住时绝不回退"。 |
| 自动最快 | 等于现有的"自动选择最快节点"。补上：失败先确认再切换、切换后关闭旧连接、切换记录。 |
| 故障转移（新增） | 用户点选的节点就是"首选节点"。首选无响应时，自动切到其余节点中可用且最快的一个；首选恢复并连续稳定后，自动切回。 |

- 代理页分组卡片的开关改为三段的 `AetherSegmentedPicker`（手动 / 自动最快 / 故障转移），下方一行说明当前模式的作用。
- 故障转移模式下：
  - 首选节点的行带"首选"标签，正在使用的备用节点带"备用中"标签。
  - 正在使用备用节点时，卡片顶部显示一条提示：首选节点无响应，已于 14:02 切到 B；A 恢复后会自动切回。
- 分组卡片标题行新增"切换记录"按钮（时钟图标），弹出最近 20 条自动切换：时间、从哪个节点切到哪个、原因（无响应 / 首选已恢复）。
- 菜单栏面板与命令面板：
  - 自动最快模式下，节点不可点选，与代理页一致。
  - 故障转移模式下，点选节点即设为首选并切过去。

### 2.2 切换提示

- 设置页 → 通知新增"节点自动切换提醒"，默认关闭，开启时才请求系统权限（与"订阅提醒"一致）。
- 通知内容遵守现有隐私承诺：不含配置名、节点名、地址。例如"当前节点无响应，已自动切换到可用节点。打开 AetherRoute 查看详情。"
- App 在前台时不发通知（与现有连接通知一致），由代理页提示承担。
- 切换记录只保存在本次运行的内存中，不写盘。

### 2.3 切换时机与防抖

- 巡检间隔 15 秒改为 10 秒（`automaticRouteHealthIntervalSeconds`）。
- 当前节点探测失败后，1 秒后对同一节点复测一次，仍失败才切换，避免偶发抖动。
- 切换前对候选节点逐个做 204 数据面验证，通过才提交；全部失败则保留原节点并标记连接质量"较差"（沿用现有行为）。
- 由故障触发的切换：关闭"经过坏节点"的连接（`ConnectionCloseRequest.proxyChainMember(坏节点)`），不受"切换节点时关闭连接"设置限制。坏节点上的连接已经不可用。
- 切回首选：
  - 使用备用节点期间，每 60 秒对分组测一次速。
  - 首选连续 2 次有响应，才尝试切回：选中首选并做 204 验证，失败就回到备用。
  - 切回时是否关闭旧连接，遵守"切换节点时关闭连接"设置，因为备用节点上的连接还能用。
- 连接后，所有处于"自动最快 / 故障转移"的分组都纳入巡检（最多 4 个），不再依赖访问代理页。

### 2.4 存储与兼容

- 模式：沿用按"配置 + 分组"摘要命名的 UserDefaults 键，新键存 `manual` / `fastest` / `failover`。旧版的布尔开关为真时，自动视为 `fastest`。降级回旧版本时，旧键仍在，行为不变。
- 首选节点：新增加密存储 `proxy-preferences.v1.json`，复用 `ProxySelectionStore` 的 AES-GCM 信封与密钥。不改动扩展读取的 `proxy-selections.v1.json` 格式，旧扩展不受影响。
- 首选节点缺省：
  - 切换到故障转移模式时，默认取当时选中的节点。
  - 如果没有选中节点，取分组中第一个可用节点。
  - 配置更新后首选节点不存在了，就回落到同样的缺省规则。

## 3. 代码改动

| 文件 | 改动 |
|---|---|
| `Sources/AetherRouteKit/ProxySelectionMode.swift`（新） | 模式枚举；旧布尔值迁移；`FailoverPolicy`（候选排序首选优先、切回滞回计数、关闭连接决策）；`ProxySwitchEvent` 与容量 20 的环形记录。全部为纯逻辑，可单测。 |
| `Sources/AetherRouteKit/ProxySelectionStore.swift` | 新增 `ProxyPreferenceStore`（复用信封编解码，独立文件）。 |
| `Sources/AetherRouteKit/TunnelStartupTimingPolicy.swift` | 巡检 10 秒；复测延迟 1 秒；切回扫描间隔 60 秒、连续 2 次。 |
| `Sources/AetherRouteApp/TunnelManager.swift` | 发布 `proxySelectionModes`、`preferredProxyMembers`、`proxySwitchEvents`；载入时迁移。 |
| `Sources/AetherRouteApp/TunnelManager+ProxySelection.swift` | `setProxySelectionMode`；`selectFastestAvailableProxy` 支持首选优先；故障转移模式下 `selectProxy` 改为设首选。 |
| `Sources/AetherRouteApp/TunnelManager+Telemetry.swift` | 巡检：失败复测、故障切换后关闭旧连接、记录事件、切回首选。 |
| `Sources/AetherRouteApp/TunnelManager+ConnectionLifecycle.swift` | 连接时按模式选节点；纳入所有自动分组。 |
| `Sources/AetherRouteApp/TunnelManager+Profiles.swift` | 载入模式与首选节点。 |
| `Sources/AetherRouteApp/ProxiesPageView.swift` | 模式分段控件、首选/备用标签、备用提示条、切换记录弹层。 |
| `Sources/AetherRouteApp/AetherRouteApp.swift` | 菜单栏节点行按模式禁用或设首选；设置页新增"节点自动切换提醒"。 |
| `Sources/AetherRouteApp/CommandPaletteView.swift` | 节点项按模式处理。 |
| `Sources/AetherRouteApp/AppAutomationController.swift` | 订阅切换事件并发送通知。 |
| `Sources/AetherRouteApp/Localizable.xcstrings` | 新文案（中英）。 |
| `Sources/AetherRouteApp/TunnelManager` 审查模式夹具 | `AETHERROUTE_UI_REVIEW_FAILOVER=1`：故障转移模式、正在使用备用节点、两条切换记录，用于截图与 UI 测试。 |
| `Docs/Design.md`、`Docs/ProductDesign.md` | 记录三种模式与布局规则（包括"不要把 `ViewThatFits` 与弹性控件并排"）。 |

## 4. 测试计划

1. **单元测试**（`Tests/AetherRouteKitTests`）：
   - 模式迁移：旧布尔值为真得到 `fastest`，缺省为 `manual`。
   - 候选排序：首选有响应时排第一；首选无响应时按延迟排其余节点。
   - 防抖：一次失败不切换，复测失败才切换。
   - 切回滞回：连续 2 次才切回，中间一次失败就清零。
   - 关闭连接决策：故障切换总是关闭坏节点连接；切回时遵守设置。
   - 切换记录：容量 20，最新的在前。
   - `ProxyPreferenceStore`：加密往返、密文不含节点名、无密钥时读为空。
   - 巡检调度：10 秒间隔。
2. **UI 测试**（`Tests/AetherRouteUITests`，VM 全量）：
   - 三段模式控件存在且可切换。
   - 故障转移模式下显示首选标签、备用提示条、切换记录弹层能打开并列出记录。
   - 自动最快模式下节点不可点选；菜单栏行为一致。
   - 设置页提醒开关存在。
   - 无障碍审计通过；中英文、深浅色、800 pt 窄窗口截图审查。
3. **真实故障转移端到端**（新脚本 `scripts/test_failover_e2e.sh`，在 `macos27` VM 上用 QA 候选包，TUN 与透明代理各一轮）：
   - 宿主机起两个独立的 vmess 夹具进程 A、B，配置中 A 在前（首选）。
   - 连接后确认流量走 A。
   - 停止 A：必须在 30 秒内恢复访问，且 B 收到连接，同时检查坏节点上的旧连接已被关闭。
   - 重启 A：必须在 3 分钟内切回 A。
   - 手动模式钉住 A 后停止 A：必须连接失败，且不切到 B（保留现有安全语义）。
4. **完整发布 SOP**：
   - 回归套件、`test.sh`、12 协议互通门禁（引擎未改动，仍按规范运行）。
   - VM 六维矩阵与 Mac mini 远程门禁并行。
   - 真机：空闲复用与 2 MiB 上传；在 Mac mini 上用故意不可用的首选节点实测一次切换。
   - UI 性能与内存门禁：预算不放宽。
   - CHANGELOG、例外说明、公证、Appcast、GitHub Release、官网同步。

## 5. 风险

| 风险 | 对策 |
|---|---|
| 频繁切换打断长连接 | 复测确认；切回需连续 2 次；切回时不强制关闭连接。 |
| 测速流量增加 | 只在使用备用节点时每 60 秒测一次组，分组成员上限沿用 64。 |
| 节点名泄露 | 通知不含节点名；记录不落盘；首选节点加密存储。 |
| 与"手动钉住不回退"的安全语义冲突 | 手动模式完全不变，端到端测试中保留该用例。 |
| 页面变慢 | 模式控件只用一个 `AetherSegmentedPicker`，不放进 `ViewThatFits` 或弹性横排；性能门禁兜底。 |

## 6. 版本

1.6.0（新增功能，次版本号）。构建号按发布当天编号。
