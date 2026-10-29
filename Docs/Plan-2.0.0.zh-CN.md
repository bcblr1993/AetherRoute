# AetherRoute 2.0.0 实施计划：机场订阅导入即用

> 起草：2026-10-29，基于 1.11.0（引擎 `d12ed6a`）的实测盘点。
> 目标读者：维护者。每个阶段完成后在本文件末尾的"进度"一节记录结论与证据目录。

## 1. 目标与验收标准

**一句话目标**：任何机场订阅，只要能在 Clash Verge / ClashX Meta（Mihomo 内核）、Surge 或 Shadowrocket 里使用，导入 AetherRoute 后同样能用；TUN 与透明代理两种模式都能直接连接。

可度量的验收标准（全部满足才发布 2.0.0）：

1. **协议对齐 Mihomo**：Mihomo 1.19.29 能加载的出站协议、传输层与 TLS 选项，除第 6 节列出的例外外全部支持。每种协议在真实服务器实验室（`scripts/protocol_lab.py`）至少一个节点，与 Mihomo 逐节点对照结果一致。
2. **不再静默丢弃**：导入时引擎无法使用的节点、规则或选项，必须在界面上逐条列出原因（例如"SSR ×3：协议暂不支持"）。目前这些会被悄悄丢掉，规则丢失还会让流量走错出口。
3. **TLS 指纹**：设置 `client-fingerprint: chrome` 时，握手的 JA4 与真实 Chrome 一致（GREASE 归一后）；REALITY 同样适用。
4. **App 端到端**：在 Mac mini 上导入完整实验室订阅，TUN 与透明代理两种模式下逐协议连通，并通过空闲复用与 2 MiB 上传检查。
5. **主流客户端对照**：同一份实验室订阅在 Shadowrocket（iPhone）与 Surge 上手工核对的结果，与我们一致或差异有明确原因（见第 5.4 节清单）。
6. **不回退**：现有全部门禁（`test.sh`、12 协议互通、三轨验收、物理机证据、UI 性能预算）继续通过；旧版本保存的配置与手动节点无需迁移即可使用。

## 2. 现状盘点（2026-10-29 实测）

方法：用与 App 相同特性集的引擎（`build/differential-target`）和 Mihomo 1.19.29 加载最小配置，查看启动结果、实际加载的节点与规则。Surge 依据官方手册（[协议总览](https://manual.nssurge.com/policies/overview.html)）；Shadowrocket 没有官方协议列表，依据 App Store 更新说明与第三方整理，**需在 5.4 节手工确认**。

### 2.1 出站协议与传输

| 能力 | AetherRoute 1.11 | Mihomo 1.19.29 | Surge | Shadowrocket（待确认） |
|---|---|---|---|---|
| SS（AEAD / 2022 / 流加密 / none） | ✅ | ✅ | ✅ | ✅ |
| SS 插件 obfs / v2ray-plugin / shadow-tls | ✅ | ✅ | 待确认 | ✅ |
| VMess / VLESS / Trojan（TCP·WS·gRPC·H2·httpupgrade） | ✅ | ✅ | VLESS ❌ | ✅ |
| VLESS REALITY + Vision | ✅（无浏览器指纹） | ✅ | ❌ | ✅ |
| AnyTLS | ✅（1.10.1 起） | ✅ | ✅ | ✅ |
| Hysteria2 / TUIC v5 / WireGuard / SSH | ✅ | ✅ | ✅ | ✅ |
| **SSR** | ❌ 静默丢弃 | ✅ | ❌ | ✅ |
| **Hysteria v1** | ❌ 静默丢弃 | ✅ | ❌ | ✅ |
| **Snell** | ❌ 静默丢弃 | ✅ | ✅（v1–v6） | ✅ |
| **xhttp 传输** | ❌ | ✅ | ❌ | ✅ |
| **VLESS encryption**（mlkem768x25519plus） | ❌ 能加载但连不上 | ✅ | ❌ | 待确认 |
| **TUIC v4**（token） | ❌ | ✅ | ✅（`tuic`） | ✅ |
| **Mieru** | ❌ | ✅ | ❌ | ✅ |
| **smux / sing-mux 多路复用** | ❌ 选项被忽略 | ✅ | ❌ | 待确认 |
| **client-fingerprint（uTLS）** | ❌ 被忽略 | ✅ | 待确认 | ✅ |
| `global-client-fingerprint` | ❌ | ✅ | — | — |
| ECH（`ech-opts`） | ❌ | ✅ | 待确认 | 待确认 |

### 2.2 规则

已支持：DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、DOMAIN-REGEX、GEOSITE、GEOIP、IP-CIDR(6)、SRC-IP-CIDR、SRC-PORT、DST-PORT、NETWORK、PROCESS-NAME、PROCESS-PATH(-REGEX)、RULE-SET（yaml / text / mrs）、AND / OR / NOT、MATCH。

**缺失且被静默丢弃**（Mihomo 均支持）：IP-ASN、DOMAIN-WILDCARD、IP-SUFFIX、SRC-GEOIP、SRC-IP-ASN、SRC-IP-SUFFIX、PROCESS-NAME-REGEX / -WILDCARD、IN-PORT / IN-TYPE / IN-NAME / IN-USER、UID、DSCP、SUB-RULE。实测：带 `IP-ASN,13335,P` 的配置启动后只剩 MATCH 一条规则，没有任何警告。

### 2.3 DNS 与其他

已支持：fake-ip、nameserver-policy、fallback-filter、proxy-server-nameserver、respect-rules、DoH 等。待补：`direct-nameserver`、`fake-ip-filter-mode`、`prefer-h3` / DoQ、`sniffer` 段、hosts 通配；订阅已支持 `subscription-userinfo`、`profile-update-interval` 与 Clash Verge UA。

### 2.4 分享链接

已支持：ss、vmess、vless（含 reality、httpupgrade）、trojan、hysteria2/hy2、tuic（v5）、anytls、wireguard、ssh、shadowquic、socks5、http(s)。待补：`ssr://`、`hysteria://`、tuic v4、vless 的 xhttp 与 encryption 参数、`mieru://`、SIP008 JSON。

## 3. 分阶段实施（每阶段先写测试，确认在旧代码上失败，再实现）

开发分支：主仓库与引擎各建 `release/2.0`。`main` 只接收 1.11.x 热修复，定期合入 `release/2.0`。每阶段合入前跑 `test_fast_lane.sh`（引擎改动强制互通门禁）。

### M0 可见性：不再静默丢弃（最先做）
- 引擎在加载配置时记录"加载报告"：跳过的节点（名称、类型、原因）、跳过的规则（原文、原因）、被忽略的选项（节点、键名）。
- 新增 FFI 导出读取报告（按 `new-ffi-export-checklist`：头文件、ABI 表、4 份符号清单、ABI 计数门禁）。
- App：导入完成与配置详情页显示"可用 N 个节点；暂不支持 M 个（按原因分组）；跳过规则 K 条"。未知规则沿用"跳过并报告"，不像 Mihomo 那样让整份配置失败。
- 测试：引擎单测（每类跳过原因）、两种核心的 FFI 冒烟、Swift 视图模型测试。

### M1 TLS 指纹（uTLS，方案 A：扩展 rustls 分支）
- 在引擎使用的 rustls 分支（锁定 rev）加入 `ClientHelloProfile`：控制密码套件、曲线、签名算法列表、GREASE、扩展集合（含 ALPS、证书压缩、status_request、SCT、session_ticket）与填充。先做 Chrome；`edge`、`360`、`qq`、`random` 暂用 Chrome 并给出警告；Firefox、Safari/iOS 列为 M1b。
- 接入：VMess / VLESS / Trojan 的 TLS、WS、gRPC、H2，AnyTLS、HTTPS、SOCKS-TLS、REALITY、shadow-tls；支持 `global-client-fingerprint`。
- 测试：分支单测核对 ClientHello 内容；新增指纹门禁（本地服务端抓取 ClientHello 计算 JA4，与内置浏览器访问 tls.peet.ws 取得的真实 Chrome 值比对）；12 协议互通全部带指纹重跑；REALITY 对 Xray 服务端。

#### M1 设计细节（2026-10-29 确定）
- **参考指纹**：`Tests/Fingerprint/chrome-152.json`（内置浏览器访问 tls.peet.ws 取得），JA4 `t13d1516h2_8daaf6152771_806a8c22fdea`。
- **rustls 已随引擎内置**：`Core/Engine/vendor/rustls-0.23.40`（引擎 `7dd44c4`，与 Watfaq 分支源码逐字节一致）。
- **改动点**（`ClientConfig.client_hello_profile`，为空时行为不变）：
  1. 线上密码套件列表按配置发送（含 GREASE；CBC / RSA 套件只宣告不实现，服务端选中即握手失败）；
  2. supported_groups、supported_versions、signature_algorithms 按配置发送并插入 GREASE；key_share 增加 1 字节 GREASE 项；
  3. `ClientExtensions` 编码支持额外原始扩展：首尾 GREASE、SCT(18)、session_ticket(35)、renegotiation_info(65281)、ALPS(17613, h2)；
  4. 开启 rustls `brotli` 特性并只用 brotli 解压证书（compress_certificate 27）；
  5. ECH GREASE 用 rustls 自带的 `EchMode::Grease`；
  6. 服务端协商 ALPS 时，在客户端 Finished 之前发送带空设置的 EncryptedExtensions（BoringSSL 行为）；未实现前先明确报错。
- **验证**：本机抓取 ClientHello 计算 JA4，与参考一致（扩展顺序本就随机，JA4 已排序）；对 www.google.com、www.cloudflare.com 真实握手；12 协议互通全部带指纹重跑；REALITY 对 Xray。

### M2 协议补齐（按机场常见程度排序）
1. Hysteria v1（含端口跳跃、obfs、up/down）
2. SSR（常见 protocol / obfs 组合）
3. xhttp 传输（VLESS；packet-up / stream-up / stream-one 模式）
4. VLESS encryption（mlkem768x25519plus）
5. TUIC v4（token）
6. Snell v1–v5
7. smux / sing-mux（h2mux、smux、yamux）
8. Mieru
9. ECH（`ech-opts`）、AmneziaWG 参数

每项：引擎实现 + 单测 → 互通门禁用例（服务端二进制固定 SHA-256）→ 实验室节点 → 分享链接解析与导出 → Mihomo 对照通过。

### M3 规则与 DNS 补齐
- 规则：第 2.2 节缺失的全部类型，含 `sub-rules` 段与 `no-resolve` / `src` 参数。
- DNS：`direct-nameserver`、`fake-ip-filter-mode`、DoQ / DoH3、`sniffer`、hosts 通配。
- 测试：每种规则的匹配单测；用 Mihomo 的规则集样例做对照（同一流量两边命中同一出口）。

### M4 导入格式补齐
- 分享链接：`ssr://`、`hysteria://`、tuic v4、vless xhttp / encryption、`mieru://`、Shadowrocket 特有参数（如 `obfsParam`、`peer`）。
- SIP008 JSON；手动节点编辑器支持新协议的导入与导出。

### M5 验证体系（贯穿各阶段，最后整体复核）
1. **实验室扩充**：`protocol_lab.py` 覆盖全部协议（sing-box、Xray、官方 Hysteria v1 / TUIC v4 / snell-server / mita / SSR 服务端，均固定 SHA-256），只占用 31001–31040 端口，用完停止。
2. **订阅语料库**：按开源面板 Xboard / V2Board / SSPanel 的订阅模板生成各协议的 Clash Meta 与分享链接夹具，再加上维护者自己的真实订阅（对照工具只在临时目录处理，报告不含地址与凭据）。
3. **App 端到端**：Mac mini 上导入完整实验室订阅，TUN 与透明代理逐协议连通；纳入物理机证据流程。
4. **主流客户端手工对照**：生成分享链接与二维码页面，维护者在 Shadowrocket（iPhone）与 Surge 上导入，按清单记录每个节点能否连通（约 15 分钟），与我们的结果对照。

### M6 发布 2.0.0
- 完整 `test.sh`、互通门禁、Mihomo 对照、三轨验收、物理机证据、UI 性能预算。
- CHANGELOG、发布说明、官网兼容性矩阵；确认旧配置与手动节点无需迁移。

## 4. 版本号说明

2.0.0 作为"订阅兼容性"里程碑。会改变已有行为的地方：带 `client-fingerprint` 的节点改用浏览器指纹握手；原先静默丢弃的规则改为执行或明确报告。旧数据格式保持兼容。

## 5. 验证细节

### 5.1 每个协议的完成定义
引擎单测 → 互通门禁（本机回环、真实服务端）→ 实验室真实网络与 Mihomo 对照 → 分享链接往返 → App 端到端（TUN 与透明代理）。

### 5.2 指纹门禁
抓取 ClientHello，计算 JA4 与排序后的 JA3（JA3N），与锁定的 Chrome 版本参考值比较；Chrome 升级后指纹变化时门禁失败，提示更新配置。

### 5.3 回归
每阶段：`test_fast_lane.sh`；涉及引擎时强制互通门禁。发布前：完整 SOP。

### 5.4 Shadowrocket / Surge 手工清单
逐节点记录"导入成功 / 连通 / 延迟"，与我们的对照报告并排；差异写入发布例外说明。

## 6. 不在本次范围

- Clash Premium `script`、Surge 模块 / 脚本 / MITM、外部代理程序：涉及执行任意代码或改写 HTTPS，与本项目的安全边界冲突，导入时继续拒绝并说明原因。
- Tor、Tailscale 出站的新增能力：保持现状。
- kcptun、restls、gost-plugin 等少见 SS 插件：报告"暂不支持"，视需求再评估。

## 7. 风险

| 风险 | 应对 |
|---|---|
| uTLS 需要长期维护 rustls 分支 | 锁定 rev；指纹门禁在 Chrome 指纹变化时报警；升级 rustls 时单独评估 |
| 宣告了 rustls 不实现的密码套件，个别服务端选中后握手失败 | 现代 TLS 1.3 服务端不会选；互通门禁与实验室覆盖 |
| xhttp、VLESS encryption 协议仍在演进 | 锁定 Xray 版本做互通；随 Mihomo 升级复核 |
| 工作量大 | 分阶段合入，每阶段独立可测；`main` 保留热修复通道 |
| Snell 服务端闭源 | 仅用于测试，使用官方发布的固定版本 |

## 8. 进度

| 阶段 | 状态 | 证据 |
|---|---|---|
| 盘点 | 完成（2026-10-29） | 本文第 2 节 |
| M0 | 进行中：引擎能力清单（引擎 `22f8322`）、App 兼容性报告与提示、fast lane 加入引擎单测与能力一致性检查；热修复 VMess/Trojan `network: tcp`（1.11.1） | `ProfileCompatibilityReportTests`、`config::capabilities` 测试 |
| M1 | 完成（引擎 `83ab7ce`）：Chrome 152 指纹 JA4 与真机逐字一致；VMess / VLESS / Trojan / AnyTLS / REALITY 与 `global-client-fingerprint` 生效；ALPS 客户端；12 协议互通门禁带指纹与不带指纹均通过；9 个真实站点（含 Google）握手并交换数据通过。已知：REALITY 不发送 MLKEM 密钥份额（会触发服务端 HRR） | `tls_fingerprint` 测试、`AETHER_INTEROP_CLIENT_FINGERPRINT=chrome` 互通 |
| M2 | 未开始 | |
| M3 | 未开始 | |
| M4 | 未开始 | |
| M5 | 未开始 | |
| M6 | 未开始 | |
