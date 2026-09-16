# AetherRoute 正式版本发布规范与防错指南

本文档定义 AetherRoute 客户端版本发布的标准化工作流程、质量门禁及关键安全规范，用于指导日常发布，防止操作遗漏与低级错误。

---

## 一、版本与构建号规范

1. **版本号遵循语义化版本（Semantic Versioning）**：
   - 格式：`vMAJOR.MINOR.PATCH`（例如 `v1.0.10`）。
   - 修复 Bug 或小功能优化递增 `PATCH`；重大功能演进递增 `MINOR`；破坏性架构变更递增 `MAJOR`。
2. **构建号（Build Number）**：
   - 格式：`YYYYMMDDNN`（例如 `2026091604`，表示 2026年9月16日第 4 次正式构建）。
   - 必须全局单调递增，供 Sparkle 框架与 macOS 系统识别更新顺序。
3. **版本号文件对齐**：
   - `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`
   - `CHANGELOG.md` 顶端更新日志
   - `Docs/ReleaseExceptions/<version>.md` 验收说明（若有豁免项）

---

## 二、代码准入与分支规范

1. **分支基线**：
   - 功能开发在 feature 分支（如 `codex/*`）进行，通过本地与虚拟机测试后，必须合并到 `main` 主干；
   - 严禁从脏工作区（dirty working tree）或非 `main` 分支执行正式构建与发布。
2. **提交与标签**：
   - 提交信息遵循 Conventional Commits（如 `chore(release): 发布 v1.0.10 正式版`）；
   - 使用带注释的 Git Tag：`git tag -a v1.0.10 -m "Release v1.0.10"`，并推送至远程仓库。

---

## 三、构建、Apple 签名与公证标准

1. **标准生产核心（Normal Core Variant）**：
   - 正式发布包必须使用生产核心，彻底剥离 QA 自动化连接测试后门（`connectForQAAutomationIfRequested` 在 Release 中编译排除）；
   - 严禁将调试标记或诊断探针遗留在生产 Mach-O 中。
2. **Developer ID 签名与 Hardened Runtime**：
   - 主程序（`com.aetherroute.desktop`）及两个网络扩展（`com.aetherroute.desktop.tunnel`、`com.aetherroute.desktop.transparent-proxy`）必须启用 Hardened Runtime，沙箱与系统扩展权限必须通过 Plist 门禁校验。
3. **Apple Notarization 官方公证与装订**：
   - App 与 DMG 安装包均需提交 Apple 公证并取得 `Accepted` 状态；
   - 使用 `xcrun stapler staple` 完成票据装订；
   - 使用 `spctl --assess --type open --context context:primary-signature` 校验必须返回 `accepted, source=Notarized Developer ID`。

---

## 四、Sparkle 自动更新签名规范（核心防错红线）

> [!CAUTION]
> **历史教训与避坑指南**：
> 若更新签名不匹配，用户客户端在下载完更新包后将弹出致命拦截：
> **「更新错误！此更新未正确签名，无法验证其真实性。请稍后再试或联系 App 开发者。」**
> 导致用户无法自动更新！

### 1. 密钥与配置基准
- **应用内置公钥**：`Config/sparkle_ed25519_pub.key`，内容必须与 `Config/App-Info.plist` 中的 `SUPublicEDKey` 严格一致（当前值为 `hVgNMayXzdIN2G5V0aeepQYjD2moJQ/ANUy14lqMtEM=`）。
- **更新签名私钥**：`Config/sparkle_ed25519_priv.key`（受版本库安全保护，仅用于项目官方签名）。
- **更新源清单地址**：`https://raw.githubusercontent.com/bcblr1993/AetherRoute/main/appcast.xml`。

### 2. 严禁事项（Forbidden Actions）
- **严禁直接运行 `sign_update` 从系统钥匙串（Keychain）读取私钥**：
  开发者机器的钥匙串中经常包含其他软件项目（如 `NotchQuota`）的同名 Sparkle 密钥，直接使用 `--account` 或钥匙串默认密钥会导致使用错误项目的密钥签名！

### 3. 正确签名流程（Mandatory Procedure）
必须统一使用项目内置的专用脚本生成更新清单：
```bash
sh scripts/generate_sparkle_appcast.sh \
  /path/to/dist/AetherRoute-<version>-build-<build>-arm64.dmg \
  "https://github.com/bcblr1993/AetherRoute/releases/download/v<version>/AetherRoute-<version>-build-<build>-arm64.dmg" \
  "<h2>AetherRoute <version></h2><p>更新说明摘要...</p><p><a href=\"https://aetherroute.pages.dev/releases/<version>/\">完整更新日志</a></p>"
```
**该脚本的安全保证**：
1. 自动读取 `Config/sparkle_ed25519_priv.key` 进行 Ed25519 签名；
2. 签名完成后，立即使用 `Config/sparkle_ed25519_pub.key` 自动执行反向验签断言（`publicKey.isValidSignature`）；若验签失败立即中断退出，彻底防止签名错误！

### 4. 清单同步与推送
生成成功后，必须将根目录 `appcast.xml` 同步至分发服务目录并推送至 GitHub 主干：
```bash
cp appcast.xml Services/WebDistribution/public/appcast.xml
git add appcast.xml Services/WebDistribution/public/appcast.xml
git commit -m "fix(sparkle): 更新 v<version> 的 appcast 签名"
git push origin main
```

---

## 五、虚拟机（Tart VM）实机全量回归矩阵

正式包在发布前，必须部署到 Tart 虚拟机（macOS 15, Apple silicon arm64）上完成实机功能验证：

| 测试场景 | 执行命令 / 探针 | 验收标准 |
| :--- | :--- | :--- |
| **实机安装与激活** | 解包安装至 `/Applications/AetherRoute.app`，启动并点击“连接” | `utun` 接口成功接管默认路由，HTTP 204 通畅 |
| **锁屏与解锁连续性** | `python3 scripts/lock_continuity_probe.py` 发送 20s keep-alive，中途模拟锁屏与解锁 | 请求连续无错误，连接重连次数为 0，App 与 Extension 进程零重启 |
| **物理链路断开自愈** | `sh scripts/test_vm_network_recovery.sh <vm-name>`（`en0 down` 8 秒后恢复） | 网络恢复引擎有序退避（attempt 0~3），网卡恢复后自动完成 coreReset 并恢复 HTTP 204 通畅，双进程零重启 |
| **网卡出口动态切换** | `sh scripts/test_vm_network_switch.sh <vm-name>`（添加/删除 IP 别名） | 上行变更自动检测并平滑重置核心，数据流零中断，双进程零重启 |
| **真实代理路由验证** | 测试 OpenAI, ChatGPT, Claude, Google AI 端点 | FakeIP（`198.18.0.x`）分配正常，返回正确 HTTP 状态码，公网出口 IP 路由正确 |

---

## 六、全量自动化测试与安全门禁

在提交发布前，必须在本地完整运行并全项通过：
```bash
sh scripts/test.sh
```
必须验证以下全部通过（0 failures）：
1. **单元与集成测试**：透明代理支持测试、FlowCoreBridge 底层测试、连接质量、配置选择、状态栏与窗口可见性测试；
2. **多协议核心覆盖**：12 种主流代理协议（VMess, VLESS, Trojan, Shadowsocks, TUIC, Hysteria 2, ShadowQUIC, WireGuard 等）与 24 处核心表面全部校验通过；
3. **安全与权限校验**：沙箱与系统扩展权限 Entitlements 规则检查，临时文件清理保护规则（`EXIT/HUP/INT/TERM`）。

---

## 七、全渠道分发与发布清单

每次发布必须按顺序执行以下分发动作：
1. **创建 GitHub Release**：
   - 关联 Git Tag `v<version>`；
   - 上传 DMG、JSON Manifest、SHA256SUMS、README.txt 及发布说明。
2. **更新官网版本页面**：
   - 生成 `Services/WebDistribution/public/releases/<version>/index.html`；
   - 更新 `releases/index.html`、`index.html`、`assets/site.js` 与 `sitemap.xml`；
   - 运行 `sh scripts/test_distribution_web.sh` 确保静态合规通过。
3. **推送主干并触发部署**：
   - 推送 `main` 分支到 GitHub，Cloudflare Pages 自动部署生效。
