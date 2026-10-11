# AetherRoute 1.7.0 实施计划：配置覆写、按地区自动分组、Tailscale 共存

2026-10-11。目标：
- 订阅用户可以在不改原订阅的前提下整理节点与分组，订阅更新后改动仍在；
- 节点能按地区自动成组，并直接用上 1.6.0 的"自动最快 / 故障转移"；
- 与 Tailscale 同时运行时，TUN 与透明代理都能正常上网，也能访问 tailnet。

## 0. 调研结论（已核实）

| 事项 | 结论 | 位置 |
|---|---|---|
| 配置处理方式 | Swift 侧没有 YAML 库，现有流水线按文本行处理 YAML 顶层段落（`DomesticRoutingOptimizer.optimizedProfile`），连接时生成最终配置交给引擎。 | `DomesticRoutingOptimizer.swift` |
| 引擎分组能力 | 引擎（clash-rs）的分组不支持 `filter` / `include-all`，只认显式 `proxies` 列表与 `use`。 | `clash-lib/src/config/internal/proxy.rs` |
| 地区识别 | 已有保守的 `NodeRegion.resolve`（国旗、中文地名、整词英文代码），用于节点行的地区标识。 | `NodeRegion.swift` |
| **订阅更新丢设置（缺陷）** | 选中的节点、1.6.0 的模式与首选节点、DNS 覆盖都以"配置文本的哈希"为键。订阅内容一变（例如节点名里带剩余流量），这些设置全部回到默认。 | `ProxySelectionStore`、`DNSRuntimePolicy`、`TunnelManager+Failover` |
| Tailscale × TUN | Tailscale 开启 MagicDNS 时，系统把 `100.100.100.100` 排在我们的解析器之前，应用拿到被污染的真实 IP。引擎只对 Fake-IP 与透明代理流量做 TLS SNI 恢复，TUN 下的真实 IP 不恢复，所以"连上了但打不开网页"。 | 记忆记录、`dispatcher_impl.rs` 的 `sniff_tls_sni` 条件 |
| Tailscale × 透明代理 | 透明代理排除了 10/8、172.16/12、192.168/16 等私网，但没有排除 Tailscale 的 `100.64.0.0/10` 与 `fd7a:115c:a1e0::/48`，tailnet 流量会被接管。实际影响待真机验证。 | `TransparentProxyProvider.swift` |
| 测试环境 | 本机与 Mac mini 都运行 Tailscale（Mac mini 的 tailnet 地址为 100.64.0.3），可以做真机共存测试。测试 TUN 时改用局域网 IP 192.168.50.226 登录 Mac mini，避免把自己锁在外面。 | — |

## 1. 配置覆写

### 1.1 覆写内容（结构化，不执行脚本）

每个配置可以有一份"覆写"，按配置 ID 加密保存，订阅更新时不受影响：

| 覆写项 | 作用 | 例子 |
|---|---|---|
| **自定义分组** | 新增分组。成员由"规则"决定：按地区、包含关键词、排除关键词，或手选节点。 | 香港自动：地区 = HK，排除"游戏" |
| **加入到分组** | 把新分组加入某个已有分组的顶部或底部，主分组里就能直接选。 | 把"香港自动"放进"节点选择"顶部 |
| **隐藏节点** | 按关键词把节点从所有分组里拿掉（原订阅不变）。 | 隐藏"剩余流量""到期""官网" |

- 成员是规则而不是快照：每次订阅更新或连接时重新计算，新增的香港节点自动进组，下线的自动消失。
- 新分组一律生成为 `select` 型，节点选择沿用 1.6.0 的三种方式。默认"自动最快"，也可设为"故障转移"。不使用引擎的 url-test，保证行为、界面和健康检查是同一套。
- 不做 JavaScript / 任意 YAML 覆写：与"拒绝可执行配置"的安全原则一致，也避免把订阅凭据交给脚本。

### 1.2 实现

- **数据与存储**：新增 `ProfileOverride`（Kit 层，纯数据加验证），按配置 ID 加密保存，复用配置目录的 AES-GCM 密钥。名称与关键词长度、分组数量都设上限（例如 ≤ 32 个分组、每组 ≤ 512 个成员）。
- **编译**：新增 `ProfileOverrideCompiler`，在 `DomesticRoutingOptimizer` 之前对原始 YAML 生效：
  1. 用现有的 `ProfileConfigurationInspector` 取得节点名与分组。
  2. 计算各自定义分组的成员，按订阅原顺序。
  3. 输出新分组：追加在 `proxy-groups` 段末尾，统一用单行写法 `- {name: …, type: select, proxies: [...]}`，名称按 YAML 规则加引号转义。
  4. 修改"加入到"的父分组成员列表：同时支持单行（flow）和多行（block）两种写法；识别不了就不改，并在界面提示。
  5. 隐藏节点：从所有分组成员中移除。只剩空成员的分组保留 `DIRECT` 兜底，避免引擎报错。
  6. 生成结果再用解析器校验，失败就回退到原配置，并提示"覆写未生效"。
- **一致性**：
  - 代理页、菜单栏、命令面板显示的分组都来自"覆写后的配置"。
  - 规则页"命中分组"的选择也包含新分组。
  - 规则模拟按覆写后的配置计算。

### 1.3 界面

- **代理页**分组栏末尾加"＋ 新建分组"，打开表单（沿用 1.5.2 的分组卡片表单样式）：
  - 名称；节点来源（地区多选，每个地区显示节点数 / 包含关键词 / 排除关键词 / 手选）；节点选择方式；加入到哪个分组及位置。
  - **实时预览**：匹配到的节点列表与数量。0 个时不能保存。
- 自定义分组卡片右上角显示"自定义"标签，菜单里可编辑、删除。原订阅分组不能删除。
- **配置页**每个配置的"更多"菜单加"覆写…"：列出该配置的全部覆写，包括隐藏节点关键词，可以统一管理。
- 覆写引用的父分组在订阅里消失时，覆写卡片显示"未找到分组 X，已跳过"，不阻止连接。

## 2. 按地区自动分组

- 新建分组表单的"节点来源 = 地区"直接列出订阅里识别到的地区与节点数（复用 `NodeRegion`）。
- **一键生成**：配置页"覆写…"中提供"按地区生成分组"：
  - 为节点数 ≥ 2 的地区各建一组，默认"自动最快"，按节点数排序。
  - 统一加入主分组（兜底规则所用分组）顶部。
  - 先预览再确认，可勾掉不要的地区。
- `NodeRegion` 识别不了的节点不会被猜进任何地区，可用"包含关键词"手动补。

## 3. 订阅更新后保留设置（缺陷修复）

- 订阅更新、或手动替换配置内容时，把以下设置从"旧内容哈希"迁移到"新内容哈希"：
  - 选中的节点（`proxy-selections.v1.json`，扩展启动时读取）；
  - 1.6.0 的节点选择模式与首选节点；
  - DNS 覆盖（`DNSRuntimePolicy`）。
- 只迁移在新配置里仍然存在的分组和节点。节点已不存在的，按原有规则回到默认。
- 不改扩展读取的文件格式与键规则，迁移只在 App 侧完成，旧扩展不受影响。

## 4. Tailscale 共存

| 问题 | 方案 |
|---|---|
| TUN + MagicDNS：拿到被污染的真实 IP | **引擎改动**：TUN 下目标为真实 IP、端口 443，且没有 Fake-IP 反查记录的 TCP 连接，读取 TLS SNI 按域名路由（与透明代理现有逻辑相同，复用 `sniff_tls_sni`，最多等 500 ms）。80 端口按 HTTP `Host` 头做同样的恢复。这样即使 MagicDNS 抢先解析，HTTPS / HTTP 也按域名走规则。 |
| TUN 抢先时，tailnet 名字（`*.ts.net`、MagicDNS 短名）解析不了 | 检测到 Tailscale 时，为 `+.ts.net` 加入 Fake-IP 排除并交给 `100.100.100.100` 解析。**先验证**引擎发往 100.100.100.100 的查询能否经 Tailscale 接口送达（引擎出站可能绑定物理网卡）；不能的话，改为在 TUN 的 DNS 设置中不接管这些域名，具体以真机结果为准。 |
| 透明代理接管 tailnet 流量 | 在排除规则中加入 `100.64.0.0/10` 与 `fd7a:115c:a1e0::/48`，tailnet 流量直接交给 Tailscale。修改前先在 Mac mini 实测现状。 |
| 用户不知道发生了什么 | 检测 Tailscale（有 100.64/10 地址的 utun，或解析器列表含 100.100.100.100）：<br>• DNS 页显示"已检测到 Tailscale，已自动兼容"；<br>• Tailscale 出口节点接管默认路由时，提示二者会争抢流量。<br>同时更新帮助文案（去掉"域名可能无法解析"）。 |

## 5. 涉及文件

| 模块 | 文件 |
|---|---|
| 覆写数据与编译 | 新增 `Kit/ProfileOverride.swift`、`Kit/ProfileOverrideCompiler.swift`、`Kit/ProfileOverrideStore.swift`；改 `DomesticRoutingOptimizer` 调用链、`TunnelManager+Profiles`（摘要与连接时应用）、`TunnelManager.swift`（启动流水线） |
| 设置迁移 | `ProxySelectionStore`（迁移接口）、`DNSRuntimePolicy`、`TunnelManager+Failover`、订阅更新路径 |
| 界面 | `ProxiesPageView`（新建分组、自定义标签）、新增 `ProxyGroupOverrideSheet.swift`、`ProfilesPageView`（覆写管理、按地区生成）、`RulesPageView`（目标分组列表）、`Localizable.xcstrings` |
| 引擎（Core/Engine） | `dispatcher_impl.rs`（TUN 真实 IP 的 SNI / Host 恢复条件）、`fake_ip_sni.rs`（HTTP Host 解析）、相应 Rust 单测；DNS 策略按验证结果改 |
| Tailscale | `TransparentProxyProvider.swift`（排除网段）、新增 `Kit/TailscalePresence.swift`（检测）、`DNS` 页与帮助文案 |
| 文档与证据 | `Docs/Design.md`、`Docs/ProductDesign.md`、`Config/ProtocolCoreEvidence.json`（引擎提交变更后更新） |

## 6. 测试计划

1. **单元测试**：
   - 覆写编译：单行和多行两种写法；名称含空格、中文、emoji、引号；父分组不存在；隐藏后分组为空；成员上限。
   - 用仓库里 `Tests/ExternalProfiles`、`Tests/ExternalSubscriptions` 的真实订阅样本，验证覆写后引擎能正常启动（沿用现有"禁网启动两种核心"检查）。
   - 地区生成：沿用 `NodeRegion` 用例并扩充。
   - 订阅更新迁移：节点仍在、节点消失、分组改名。
   - Tailscale 检测解析。
2. **引擎**：
   - Rust 单测覆盖 TUN 真实 IP 的 SNI / Host 恢复：不重复读取、超时回退、不影响非 443/80 端口。
   - 12 协议互通门禁（引擎有改动，必须在提交前运行）。
   - 更新 `ProtocolCoreEvidence.json` 并校验。
3. **UI 测试**：
   - 新建分组表单、地区预览、保存后分组出现在代理页与主分组中；
   - 编辑与删除；按地区一键生成；覆写管理；
   - 无障碍审计；中英文、深浅色、800 pt 窄窗口截图审查。
4. **端到端**（VM 克隆，沿用 `test_failover_e2e.sh` 的方式）：
   - 本机起 HTTP 服务模拟订阅：第一次提供 A、B 两个"香港"节点，自定义"香港自动"分组。
   - 更新订阅，改名并新增一个香港节点：分组自动包含新节点；故障转移模式与首选节点保留；流量照常。
5. **Tailscale 真机**（Mac mini，通过局域网 IP 登录）：
   - TUN + MagicDNS 开启：HTTPS 网站正常访问、走规则正确；`ssh 主机名.ts.net` 正常；访问 tailnet IP 正常。
   - 透明代理：同上三项。
   - 关闭 Tailscale 后行为与 1.6.0 一致。
   - 测完恢复 Mac mini 原状态（透明代理模式，Tailscale 照常运行）。
6. **完整发布 SOP**：
   - 回归套件、`test.sh`、互通门禁；
   - VM 矩阵与 Mac mini 远程门禁并行；
   - 真机空闲复用与 2 MiB 上传；
   - UI 性能与内存门禁（预算不放宽）；
   - 包大小与图标核对；
   - 公证、Appcast、GitHub Release、官网同步。

## 7. 风险

| 风险 | 对策 |
|---|---|
| 文本方式改 YAML 出错，导致配置无法启动 | 只做三类定点修改；生成后重新解析校验，失败就回退原配置；用真实订阅样本做启动测试。 |
| 引擎改动影响全部流量 | 只扩展已有 SNI 恢复的触发条件，且只针对"没有 Fake-IP 记录的真实 IP + 443/80"；跑互通门禁、VM 矩阵、真机。 |
| 大订阅（几千节点）下成员计算拖慢切页 | 成员在配置变更时计算一次并缓存，界面只读结果；性能门禁的 large 档（500 节点）兜底。 |
| 与 Tailscale 的 DNS 方案在真机上不成立 | 第 4 节第二项先验证再定方案；SNI / Host 恢复本身不依赖它，能独立解决"打不开网页"。 |
| 测 TUN 时把 Mac mini 的 SSH 断掉 | 全程用局域网 IP 登录；测试脚本结束时自动恢复透明代理模式。 |

## 8. 版本与顺序

1.7.0（新增功能）。实施顺序：
1. 订阅更新保留设置（地基，独立可测）；
2. 覆写数据、编译与单测；
3. 界面与按地区生成；
4. 引擎 SNI / Host 恢复与互通门禁；
5. Tailscale 排除、检测与真机验证；
6. 全量测试与发布。
