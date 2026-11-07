# AetherRoute 对标主流客户端差距盘点与 macOS v2.4.0 规划方案

> **当前基线**：`v2.3.0`（Build `2026110602`）
> **对标对象**：**Surge for Mac 5**、**Clash Verge Rev / ClashX Meta (Mihomo)**、**Stash for macOS**
> **规划目标**：全面盘点 AetherRoute 与主流旗舰客户端的功能差距，给出高内聚、可验证的 **`v2.4.0` 实施计划** 与 **`v2.5.0` 演进路线图**。

---

## 1. 对标主流客户端：全景能力与差距盘点

基于对现有代码库（`Sources/AetherRouteKit`、`Sources/AetherRouteApp`、`Core/Engine`）的实测梳理，AetherRoute 在协议覆盖、双引擎架构（TUN + 透明代理）、内存控制（`~65 MB`）与零外部依赖自动化验收上已处于领先位置；但在 **日常高频交互、可观测性闭环与高阶可配置项** 上，对标主流客户端仍存在以下 **6 项明确差距**：

| 维度 | Surge for Mac 5 | Clash Verge Rev (Mihomo) | Stash for macOS | AetherRoute (v2.3.0 现状) | 差距定级与核心缺失点 |
|---|---|---|---|---|---|
| **1. 规则集（Rule Providers）可视管控** | ✅ 查看条数/更新时间、单项与全部刷新、预览规则内容 | ✅ 独立 Rule Providers 页，显示行为/格式/条数/更新时间与一键刷新 | ✅ 规则集状态、条数统计与手动刷新 | ⚠️ **后端已就绪，UI 缺失**<br/>`RuleProviderEngine.swift` 已实现拉取/缓存/编译/iCloud 同步，但无 UI 管理入口；`ProviderRow` 仅显示名称与类型 | 🔴 **P0 必补（v2.4.0）**<br/>缺自定义规则集增删改查/刷新/预览 UI；缺订阅 `rule-providers` 行为/格式/周期/出口透视 |
| **2. 连接详情路由决策回放与快捷分流** | ✅ 完整连接事件流（Mode → Hosts → Process → Rule → Outbound）+ 面板内一键建规则 | ⚠️ 仅显示命中规则与链路名称 | ✅ 路由决策路径展示 + 详情内直接转分流规则 | ⚠️ **半闭环**<br/>`v2.3.0` 已支持 `ART5` 建连耗时分解，但 `ConnectionInspector` 仅静态展示结果，创建规则需退回列表右键菜单 | 🔴 **P0 必补（v2.4.0）**<br/>缺 **6 步路由决策树回放**；缺详情面板内 **一键转分流规则** 与 **一键跳转规则页定位** |
| **3. DNS 交互式解析测试器（DNS Lookup）** | ✅ 内置 `DNS Lookup` 工具，实测 Hosts 命中、规则分流、上游响应 IP 与耗时 | ✅ 内置 `DNS Query` 调试器 | ✅ 支持域名解析测试与 Fake-IP 映射检查 | ❌ **缺失**<br/>`DNSPageView.swift` 只能看静态统计和编辑自定义 Hosts，无法输入域名测试 DNS 解析行为 | 🔴 **P0 必补（v2.4.0）**<br/>缺 **交互式 DNS 解析诊断器**（测试 Hosts 通配命中、Fake-IP 过滤判定、实测解析 IP 与毫秒延迟） |
| **4. 代理节点组内搜索过滤与多条件检索** | ✅ 节点关键字/协议搜索过滤 | ✅ 组内搜索过滤、协议筛选 | ✅ 组内节点过滤 | ⚠️ **部分缺失**<br/>`ProxiesPageView.swift` 支持排序与单关键字地区搜索，但缺少多词组合与传输层（`ws`/`grpc`）/ 前置代理（`dialer-proxy`）联合筛选 | 🟠 **P1 高优（v2.4.0）**<br/>补齐代理页 **组内多词组合搜索与协议/传输层/前置代理筛选** |
| **5. 多浏览器 TLS 指纹矩阵（uTLS）** | ⚠️ 基础 TLS 指纹 | ✅ 支持 `chrome` / `firefox` / `safari` / `ios` / `edge` / `random` 及全局覆盖 | ✅ 支持多浏览器 uTLS 指纹 | ⚠️ **仅 Chrome 原生实现**<br/>`v2.0.0` 已实现真实 Chrome 152 JA4 + ALPS，但 `firefox` / `safari` / `ios` 暂回退至 Chrome | 🟡 **P2 引擎演进（v2.5.0）**<br/>补齐 Firefox / Safari / iOS 真实 ClientHello Profile 与全局指纹 UI 覆盖开关 |
| **6. 外部自动化（URL Scheme / 快捷指令 / 高级传输）** | ✅ URL Scheme / Shortcuts / CLI 控制连接与模式 | ✅ 外部控制 API 与 URL Scheme | ✅ Shortcuts 与 URL Scheme 联动 | ⚠️ **仅支持订阅导入**<br/>`ExternalSubscriptionLink.swift` 仅处理 `subscribe`；`xhttp` 暂缺 HTTP/3 与 `download-settings` | 🟡 **P2 生态演进（v2.5.0）**<br/>扩展受控 URL Scheme（连接/断开/切模式）与 `xhttp` 高级传输选项 |

---

## 2. macOS `v2.4.0` 四大核心模块

### 2.1 模块一：规则集（Rule Providers）可视管控、即时刷新与订阅透视
1. **订阅内置 `rule-providers` 与 `proxy-providers` 详情透视**：
   - 扩展 `ProviderConfigurationSummary`（`Sources/AetherRouteKit/ProfileConfigurationSummary.swift`），解析并保留 `behavior`（`domain` / `ipcidr` / `classical`）、`format`（`yaml` / `text` / `mrs`）、`intervalSeconds`（更新间隔秒数）以及在 `rules:` 中被 `RULE-SET` 引用的次数 `referencedRuleCount` 与目标策略组列表 `referencedTargets: [String]`。
   - 升级 `ProviderRow`（`Sources/AetherRouteApp/FeatureViews.swift`），直观展示行为徽章、格式、更新周期、被引用次数与关联出口。
2. **自定义远程规则集（`RuleProviderEngine`）全套 UI 闭环**：
   - 新增 `Sources/AetherRouteApp/TunnelManager+RuleProviders.swift`，将 `RuleProviderEngine` 接入 `TunnelManager`（管理 `customRuleProviders`、`refreshingRuleProviderIDs`，支持添加、编辑、启停、单项强制刷新、全部刷新，并在变更后自动重算 `activeProfileSummary` 与热重载隧道）。
   - 在 `RulesPageView.swift` 新增 **「自定义规则集」（Custom rule providers）** 管理面板、添加/编辑弹窗（`RuleProviderEditorSheet`）以及缓存规则内容预览弹窗（`RuleProviderPreviewSheet`，支持按关键字搜索规则集内的条目并一键送入路由测试器）。

### 2.2 模块二：连接级 6 步路由决策树回放与一键分流闭环
1. **6 步路由决策回放引擎（`ConnectionRouteDecisionTrace`）**：
   - 在 `ProfileConfigurationSummary.swift` 中新增 `ConnectionRouteDecisionTrace`，针对任意 `ConnectionTelemetry` 还原完整决策路径：
     - **Step 1 · 路由模式（Routing Mode）**：`Rule` / `Global` / `Direct`；
     - **Step 2 · 本地 Hosts 映射（Hosts Override）**：检查 `destinationHost` 是否命中已启用的 `CustomHostMapping`（含精确、`*.`、`+.` 通配）；
     - **Step 3 · 应用分流规则（Application Rule）**：检查 `sourceAppIdentifier` / `sourceAppPath` 是否命中应用规则；
     - **Step 4 · 自定义目标规则（Custom Rule）**：检查是否命中用户自定义 `DOMAIN` / `DOMAIN-SUFFIX` / `IP-CIDR` / `DST-PORT` 规则；
     - **Step 5 · 订阅规则匹配（Profile Rule）**：展示命中的订阅规则类型与匹配值；
     - **Step 6 · 出站链路（Outbound Chain）**：展示最终多跳代理链路。
2. **升级 `ConnectionInspector`（`Sources/AetherRouteApp/ConnectionsPageView.swift`）**：
   - 新增 **「路由决策回放」（Route decision trace）** Section；
   - 新增 **「快捷分流规则」（Quick rule actions）** Section，支持在连接详情弹窗内一键设置或移除分流规则并自动断开旧流使其重连生效；
   - 新增 **「在规则页定位」（Locate in Rules）** 按钮，一键跳转至「分流规则」页并自动测试与高亮命中规则。

### 2.3 模块三：DNS 交互式解析诊断器（Interactive DNS Lookup Inspector）
1. **DNS 诊断评估器（`DNSLookupInspector` in `AetherRouteKit`）**：
   - 输入查询域名或 URL，输出结构化诊断报告（`DNSLookupReport`）：
     1. **本地 Hosts 映射命中**（含通配符匹配）；
     2. **生效解析模式判定**（`Fake-IP` / `Redir-host` / `Normal`）；
     3. **关联分流出口预判**（调用 `RouteMatchEngine` 给出匹配规则与出口）；
     4. **系统实测解析（Live Resolution）**（调用 `getaddrinfo` 解析 IPv4 / IPv6 地址，自动识别 `198.18.0.0/15` 与 `fc00::/18` Fake-IP 地址池并记录毫秒耗时）。
2. **「DNS」页交互式诊断卡片（`DNSPageView.swift`）**：
   - 新增 **「DNS 解析测试」（DNS lookup）** 卡片，支持输入任意域名或点击快捷示例一键解析。

### 2.4 模块四：代理节点组内多词搜索与协议/传输层/前置代理筛选
- 扩展 `ProxyPageNodeOrder.filtered`（`Sources/AetherRouteApp/ProxyPageNodeOrder.swift`）与 `NodeRegion.filterMembers`（`Sources/AetherRouteKit/NodeRegion.swift`），支持多词组合查询，跨语言匹配地区名/国旗、节点名、协议、传输层（如 `ws`、`grpc`）与前置代理（`dialer-proxy`）。
