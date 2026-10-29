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

#### M2-2 SSR 实现决定（2026-10-29）
- **许可证**：Mihomo 为 GPL-3.0，只作行为参考与互通客户端，不移植其代码；依据 Apache-2.0 的 Python 版 ShadowsocksR（shadowsocksrr/shadowsocksr，akkariiin/dev 分支，提交 `b365980`，源码包 SHA-256 `63f1578f…3a3f`）实现，并在 NOTICE 中致谢。
- **互通服务端**：同一 Python 服务端（python3 + Homebrew OpenSSL 3 的 libcrypto），每种组合一个进程，端口 59060 起；已用 Mihomo 作客户端验证（aes-128-cfb + auth_aes128_md5 + http_simple，HTTP 200）。
- **分层**：TCP → obfs（plain / http_simple / http_post / random_head / tls1.2_ticket_auth）→ 流加密（IV + 流密码，EVP_BytesToKey 派生）→ protocol（origin / auth_sha1_v4 / auth_aes128_md5 / auth_aes128_sha1 / auth_chain_a / auth_chain_b）→ 地址头与数据。
- **顺序**：先流加密 + origin + plain，再各 obfs，再各 protocol；每加一种都先加互通用例（先失败），最后做 UDP。

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

## 3A. 排期与任务清单（2026-10-29 更新）

按"连续推进、不被外部条件阻塞"估算，剩余约 4–6 个工作日；发布流程本身约 2 小时。每一项都按"先写测试并确认在旧代码上失败 → 实现 → 互通 / 对照通过 → 接入门禁"完成，完成后在第 8 节记录证据。

| 顺序 | 任务 | 测试先行的内容 | 互通服务端 | 估算 |
|---|---|---|---|---|
| ✅ | M0 不再静默丢弃 | 兼容性报告单测、能力清单双向一致 | — | 完成 |
| ✅ | M1 Chrome 指纹 + ALPS | JA4 对比真机、各协议抓包、真实站点握手 | sing-box、Xray、9 个真实站点 | 完成 |
| ✅ | M2-1 Hysteria v1 | 编解码、分片重组、配置 | sing-box | 完成 |
| ✅ | M2-2 SSR（TCP：6 种 protocol × 5 种 obfs × 流加密；UDP 见 3B） | 加密已知答案、帧往返、ticket 握手 | Python ShadowsocksR（Apache-2.0，固定提交） | 完成 |
| ✅ | M2-3 xhttp（packet-up / stream-up / stream-one / auto，TLS · REALITY · 明文） | 配置加载与拒绝、路径与填充、Xray 互通 8 例 | Xray 26.3.27 | 完成 |
| ✅ | M2-4 VLESS encryption（mlkem768x25519plus） | 配置加载与拒绝、密钥派生与分帧、Xray 互通 8 例 | Xray 26.3.27 | 完成 |
| 4 | M2-5 TUIC v4（token） | 帧格式 | 官方 tuic-server v0.8 | 0.5 天 |
| 5 | M2-6 Snell v1–v5 | 帧格式与加密 | 官方 snell-server（固定版本） | 0.5 天 |
| 6 | M2-7 smux / sing-mux（h2mux、smux、yamux） | 多路复用帧 | sing-box | 0.5 天 |
| 7 | M2-8 Mieru、AmneziaWG 参数、ECH（`ech-opts`） | 各自协议 | mita、amneziawg、sing-box | 0.5–1 天 |
| 8 | M3 规则与 DNS 补齐 | 每种规则的匹配单测，与 Mihomo 命中同一出口 | Mihomo | 0.5–1 天 |
| 9 | M4 分享链接、SIP008、App 协议目录与手动节点编辑器 | 每种链接往返、旧数据解码 | — | 0.5 天 |
| 10 | M5 实验室扩充到全部协议、订阅语料库、App 端到端、Shadowrocket / Surge 手工清单 | 每协议真实网络与 Mihomo 一致 | 腾讯云实验室 | 0.5–1 天 |
| 11 | M6 发布 2.0.0 | 第 5.5 节全部门禁 | VM、Mac mini | 0.5 天 |

"支持所有协议"指 Mihomo 1.19.29 能加载的出站全部支持，以下除外并在导入时明确提示：Hysteria v1 的 `faketcp`（需要原始套接字，macOS 网络扩展不允许）、Clash Premium `script` 与 Surge 模块 / MITM（见第 6 节）。若某个服务端无法取得（如闭源服务端没有对应版本），该协议仍实现，但在发布说明中注明只做了单测与对照测试。

## 3B. 后续任务详细计划（2026-10-29 整理）

本节列出 3A 表中每项剩余任务的范围、做法、测试先行的内容和完成标准。完成标准统一为第 5.1 节的五步。各项通用要求：
- 先写失败测试，并在提交说明中写明它在旧代码上失败；
- 互通服务端固定版本和 SHA-256，并加入 `fetch_interop_tools.sh`；
- 新协议加入能力清单（`engine_capabilities.py write`），App 导入时不再列为"暂不支持"；
- 同步 `ProtocolCoreEvidence.json`（核心提交、核心哈希、源码哈希、互通用例）与许可证；
- 若移植第三方代码，只取 MIT / Apache-2.0 / BSD 来源，并写入 NOTICE。Mihomo、sing-box、Xray 不在此列：Mihomo、sing-box 为 GPL，Xray 为 MPL-2.0。它们只用作行为参考和互通对端。

### M2-2 SSR（TCP 已完成，剩余 UDP）
- **已完成**（引擎 `b28f37f`）：
  - 6 种 protocol、5 种 obfs 与全部流加密；
  - 13 种组合对 Python 服务端互通，连续 5 轮通过；
  - 修复 tls1.2_ticket_auth 遇到服务端追加 NewSessionTicket 时的偶发握手失败。
- **剩余**：SSR UDP。
  - origin 的 UDP 与 SS 流加密 UDP 相同；
  - auth_aes128_* 与 auth_chain_* 的 UDP 有各自的包格式（带 uid 与 HMAC 尾部）。
- **测试先行**：
  - 先对照 Python 参考实现的 `client_udp_pre_encrypt` / `client_udp_post_decrypt` 写包格式单测；
  - 再在 SSR 互通用例中加入 8 包 UDP 回显（与其他协议同一检查，重复送达即失败）。
- **决定**：UDP 计划放进 2.0。若服务端 UDP 在本机回环上无法稳定复现，则 2.0 只支持 TCP，导入时提示"该节点 UDP 不可用"，并写进发布说明。

### M2-3 xhttp 传输（VLESS）
- **背景**：1.10.0 的对照工具发现，订阅里只要有一个 xhttp 节点，Mihomo 和我们都会拒绝整份配置。现在我们改为跳过并报告，下一步是真正支持。
- **范围**：Mihomo `xhttp-opts` 的字段：
  - `path`、`host`、`mode`（`auto` / `packet-up` / `stream-up` / `stream-one`）、`headers`；
  - `no-grpc-header`、`x-padding-bytes`、`sc-max-each-post-bytes`、`sc-min-posts-interval-ms`；
  - `reuse-settings`（xmux）、`download-settings`（上下行分离）。
- **底层**：
  - TLS / REALITY 上的 HTTP/2；
  - 无 TLS 时用 HTTP/1.1（packet-up）或 h2c；
  - HTTP/3 先列为后续。
- **做法**：
  - packet-up：每段上行一个 POST，路径带会话 ID 与序号；下行用一个长 GET 流；
  - stream-up：上行一个流式 POST，下行一个 GET；
  - stream-one：单个双向 POST；
  - 填充放在 Referer / 请求头的 `x_padding`，与 Xray 一致。
- **测试先行**：
  - 单测：会话 ID 与序号路径、填充长度区间、POST 分段上限、乱序到达时服务端按序号重组（模拟服务端）；
  - 互通：Xray（已固定版本）开 3 种模式 × {TLS, REALITY} 共 6 个用例，与现有矩阵同一套检查（2 MiB、空闲复用、证书固定 / 拒绝）；
  - 对照：Mihomo 加载同一 xhttp 节点，两边都能连通。
- **风险**：xhttp 仍在演进。锁定 Xray 版本，字段以 Mihomo 1.19.29 为准；遇到不认识的 `extra` 字段时，跳过该字段并报告。

- **完成情况（2026-10-29）**：引擎 `5a9fc33`。所有请求走 HTTP/2：TLS 用 ALPN h2，REALITY 与明文用 h2c（Xray 服务端支持）。同一代理连接的所有请求共用一条 HTTP/2 连接。
- **已知限制**：
  - 明文 xhttp 经只支持 HTTP/1.1 的 CDN（80 端口）暂不支持；
  - `download-settings`、`x-padding-obfs-mode`、header / query / cookie 位置、非 POST 上行会让节点加载失败，并在日志中写明选项名；
  - App 兼容性提示只解析节点的顶层键，看不到这些嵌套选项；
  - 以上列入"2.0 之后"，视用户反馈处理。

### M2-4 VLESS encryption（`encryption: mlkem768x25519plus...`）
- **背景**：现在这类节点能加载但连不上，比不支持更糟。实现之前，先改为明确报告"暂不支持"，这一步先做（先写测试）。
- **范围**：
  - Xray 的客户端 encryption 串，形式为 `mlkem768x25519plus.<native|xorpub|random>.<1rtt|0rtt>.<密钥…>`；
  - ML-KEM-768 + X25519 混合密钥交换、会话密钥派生、AEAD 分帧与随机填充；
  - 0-RTT 票据复用。
- **依赖**：ML-KEM 用 aws-lc-rs，App 已启用该特性。
- **测试先行**：
  - 用 Xray 生成的密钥对和握手记录做已知答案测试；
  - 互通：Xray 服务端，native / xorpub / random × 1rtt / 0rtt；
  - 叠加 Vision 与 REALITY 的组合各一例。
- **完成情况（2026-10-29）**：引擎 `ec8343c`。支持 `mlkem768x25519plus.<native|xorpub|random>.<1rtt|0rtt>.[padding.]<keys...>`（X25519 与 ML-KEM-768 链式认证、1-RTT 混合前向安全握手与分片随机填充、0-RTT 票据缓存与恢复、`XorStream` 记录头掩码、与 `xtls-rprx-vision` 直通拼接及 TLS / REALITY 叠加）；未知或格式错误的 `encryption` 节点在加载时直接拒绝并写明 `encryption`，App 兼容性报告同步识别合法的 `mlkem768x25519plus` 配置。对 Xray 26.3.27 8 例 × 2 轮通过；变异检查：去掉 `random` 模式 5 字节记录头 XOR 得连接重置，去掉 0-RTT `united_key` 中的 `pfs_key` 得第 2 条连接立即失败。

### M2-5 TUIC v4（`version: 4`，token）
- **范围**：
  - v4 的 Authenticate 命令（token 摘要）、Connect / Packet / Dissociate / Heartbeat；
  - `udp-relay-mode`（native / quic）与 `reduce-rtt`；
  - 与现有 TUIC v5 共用 QUIC 层。
- **测试先行**：
  - 帧编解码对照 v4 协议文档；
  - 配置测试：`version: 4` 加 `token` 能加载；缺少 token 时报错并写明字段名。
- **互通服务端**：官方 tuic-server 0.8.x，从固定提交的源码编译（与 WireGuard 服务端相同做法），用例与 v5 一致（TCP、UDP、证书固定）。
- **完成情况（2026-10-29）**：引擎 `b594c64`。在 `aether_tuic` 中与 TUIC v5 共用 QUIC 层实现 TUIC v4（`VER = 0x04`）：`token` 的 32 字节 BLAKE3 摘要单向流认证、`Connect`（`0x01`）双向流首读剥离并校验 3 字节 `[0x04, 0xff, REP]` 响应、`Packet`（`0x02`，32 位 `ASSOC_ID`）与 `Dissociate`（`0x03`）支持 `native`（QUIC datagram）与 `quic`（单向流）双模式、`Heartbeat`（`0x04`）走单向流、`reduce-rtt` 支持 `into_0rtt()` 并在未命中时回退 1-RTT；配置加载兼容 `version: 4` + `token` 与省略 `version` 仅填 `token`（含数字标量 token），对空/缺 `token`、v4/v5 凭证混用及未知 `version` 明确拒绝并点名字段。对官方预编译 `tuic-server 0.8.5`（`tuic-server-0.8.5-aarch64-macos`，SHA-256 `34db3ad8...`）跑通 `native` 与 `quic`（含 `reduce-rtt: true`）TCP 2 MiB + 5s 空闲复用 + 8 包 UDP 回显、证书固定、`ca-str`、错误指纹拒绝及未授信证书拒绝 × 2 轮；变异检查：把 BLAKE3 摘要改为原始 token 字节得服务端 `authentication failed`，跳过剥离 3 字节 `Response` 得 `TCP echo payload changed`。

### M2-6 Snell
- **范围**：与 Mihomo 一致，支持 v1–v3（`psk`、`version`、`obfs-opts` 的 http / tls，v3 支持 UDP）。Surge 的 v4 / v5 与 v3 不兼容，Mihomo 也不支持，导入时报告"暂不支持的 Snell 版本"。
- **测试先行**：AEAD 分帧（chacha20-poly1305 与 aes-128-gcm）、握手头、obfs 头的单测；参考是协议的公开描述和 Mihomo 的行为（不复制代码）。
- **互通服务端**：官方 snell-server 只有 Linux 版，放在腾讯云实验室上测，不进本机回环门禁。本机门禁用 Mihomo 作对端做对照：同一节点两边结果一致。发布说明写明这一例外。

### M2-7 smux / sing-mux 多路复用
- **背景**：现在 `smux: enabled` 被忽略，节点不经复用直连，兼容性提示里写着"未应用"。
- **范围**：
  - sing-mux 协议头，`protocol` 取 smux / yamux / h2mux；
  - `max-connections` / `min-streams` / `max-streams`、`padding`、`only-tcp`；
  - UDP over stream；`brutal-opts` 列为后续。
  - 适用于 SS、VMess、VLESS、Trojan、AnyTLS（与 Mihomo 一致）。
- **测试先行**：
  - 各复用协议的帧单测；
  - 连接池单测：达到 max-streams 时开新连接，空闲回收；
  - 互通：sing-box 入站开 multiplex，3 种协议 × SS 与 VLESS。
- **完成后**：兼容性提示不再出现 smux。

### M2-8 Mieru、AmneziaWG、ECH
- **Mieru**：
  - 范围：mita 服务端，TCP / UDP 传输，用户名 + 密码按时间派生密钥，XChaCha20-Poly1305 分段与填充；`multiplexing` 选项。
  - 测试：密钥派生与分段单测；互通对官方 mita（固定版本，源码编译）。
- **AmneziaWG**：
  - 范围：`amnezia-wg-option`（jc、jmin、jmax、s1、s2、h1–h4）。在现有 WireGuard 握手前发送垃圾包，修改消息头类型与填充。
  - 测试：握手包格式单测；互通对 amneziawg-go。
- **ECH**：
  - 范围：`ech-opts`（`enable`、`config`）。配置可以由订阅给出，也可以从 DNS HTTPS 记录获取，用 rustls 自带的 ECH 客户端。
  - 测试：rustls ECH 配置解析；互通对 sing-box 的 ECH 入站；真实站点 `crypto.cloudflare.com/cdn-cgi/trace` 显示 `sni=encrypted`。
- **后续**：三项中若有一项的服务端无法取得，按 3A 末尾的规则处理。

### M3 规则与 DNS
- **规则**：IP-ASN、SRC-IP-ASN（用 GeoLite2-ASN mmdb，与 GeoIP 同样下载和更新）；DOMAIN-WILDCARD；IP-SUFFIX、SRC-IP-SUFFIX；SRC-GEOIP；PROCESS-NAME-REGEX / -WILDCARD；IN-PORT / IN-TYPE / IN-NAME / IN-USER；UID；DSCP；`sub-rules` 段与 SUB-RULE。
  - 透明代理与 TUN 都能取得的入站信息按实际支持。拿不到的字段（例如透明代理下的 DSCP）照常加载规则，但兼容性提示写明"在此模式下不生效"。
- **DNS**：`direct-nameserver`（含 follow-policy）、`fake-ip-filter-mode`（blacklist / whitelist / rule）、DoQ 与 DoH3（`prefer-h3`）、`sniffer` 段（HTTP / TLS / QUIC 嗅探与 `force-domain` / `skip-domain`）、hosts 通配。
- **测试先行**：
  - 每种规则一个匹配单测和一个不匹配单测；
  - 与 Mihomo 对照：同一组模拟连接两边命中同一出口；
  - 把 `def.rs` 等测试中拿这些规则当"不支持示例"的地方，改成真正不存在的类型（与 SSR 时同样处理）。

### M4 导入格式与 App
- **分享链接解析与导出**：`ssr://`、`hysteria://`、`tuic://`（v4 token）、vless 的 `type=xhttp` 与 `encryption=`、`snell://`（Surge 写法）、`mieru://`、amneziawg 参数，以及 Shadowrocket 特有参数（`obfsParam`、`peer`、`tfo` 等）。
- **其他导入格式**：SIP008 JSON；Surge `[Proxy]` 段中我们支持的协议行（只读导入）。
- **App**：
  - 协议目录与 `ProtocolReleaseMatrix.json` 加入新协议；
  - 手动节点编辑器支持新协议；
  - 节点详情显示协议与传输。
- **测试先行**：
  - 每种链接做解析、导出、再解析的往返测试；
  - 用真实客户端导出的链接样例做夹具；
  - 旧数据解码测试，保证 1.x 保存的节点不需要迁移。

### M5 验证体系
1. **实验室**：`protocol_lab.py` 加入 SSR、Hysteria v1、xhttp、VLESS encryption、TUIC v4、Snell、smux、Mieru、AmneziaWG、ECH 节点。
   - 仍只用 31001–31040，端口不够时复用；
   - 每个节点对 Mihomo 与我们各测一次，结果一致。
2. **订阅语料库**：按 Xboard / V2Board / SSPanel 的模板生成 Clash Meta YAML 与分享链接夹具，覆盖全部协议与常见写法；加入 `test.sh`，检查加载结果与兼容性报告。
3. **App 端到端**：Mac mini 上导入实验室订阅，TUN 与透明代理各逐节点连通，结果写成证据文件。
4. **手工对照**：生成分享链接与二维码页面，维护者在 Shadowrocket、Surge 上导入并记录结果（约 15 分钟），差异写进发布例外说明。

### M6 发布 2.0.0
1. 冻结：`release/2.0` 合入 `main` 的最新热修复，解决冲突后跑 fast lane。
2. 全部必跑测试（第 5.5 节），包括两遍互通门禁、Mihomo 与实验室对照、真实站点指纹、三轨验收、物理机证据、UI 性能预算。
3. CHANGELOG 与 `Docs/ReleaseExceptions/2.0.0.md`，内容包括：
   - 协议对照表；
   - 例外项：faketcp、Snell 只在实验室测、未完成的 UDP 等；
   - 门禁结论与性能数据。
4. 发布：
   - 打包公证 DMG，生成 Appcast（带自定义说明）；
   - 引擎与 App 分别打 tag 并推送，`release/2.0` 合入 `main`；
   - GitHub Release（带 aethernative 元数据块），确认官网与 Appcast 已更新。
5. 收尾：清理旧构建产物与测试临时文件，停止实验室服务，提醒维护者关闭 31001–31040 防火墙规则。

### 2.0 之后（不阻塞发布）
- Firefox / Safari / iOS 指纹（M1b）；`edge`、`360`、`qq` 专属指纹。
- xhttp 走 HTTP/3 与 HTTP/1.1（明文 CDN）、`download-settings`、填充混淆与非 path 位置；smux 的 `brutal-opts`。
- 少见 SS 插件（kcptun、restls、gost-plugin）视用户反馈再评估。

### 5.5 每次发布必跑的核心测试（2.0 起）
1. `./scripts/test_fast_lane.sh`（含引擎单元测试与能力清单一致性检查）；
2. `./scripts/test.sh`（零警告）；
3. 12 协议互通门禁跑两遍：默认与 `AETHER_INTEROP_CLIENT_FINGERPRINT=chrome`；
4. Mihomo 对照端到端 + 实验室真实网络对照（全部节点一致，差异须解释）；
5. Chrome 指纹真实站点测试（`real_site_tests`，需联网）；
6. 三轨并行验收与物理机证据（TUN、透明代理）；
7. UI 性能与内存预算。

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
| M2 | 进行中：Hysteria v1 完成（引擎 `3ee5b23`）；SSR TCP 完成（引擎 `b28f37f`，13 种组合连续 5 轮通过）；xhttp 完成（引擎 `5a9fc33`，对 Xray 8 例 × 2 轮通过，变异检查：去掉填充得 HTTP 400、包序号从 1 起即卡死）；VLESS encryption 完成（引擎 `ec8343c`，对 Xray 8 例 × 2 轮通过，变异检查：去掉 random 记录头 XOR 得连接重置、去掉 0-RTT PFS 密钥得复用失败）。待做：SSR UDP、TUIC v4、Snell、smux、Mieru / AmneziaWG / ECH；App 协议目录与分享链接随 M4 | 互通门禁 `ssr`、`xhttp`、`vless-enc` |
| M3 | 未开始 | |
| M4 | 未开始 | |
| M5 | 未开始 | |
| M6 | 未开始 | |
