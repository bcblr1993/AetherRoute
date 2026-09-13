# Cloudflare Pages 静态独立站全球加速部署指南

本指南说明如何将 AetherRoute 的纯静态分发站 (`Services/WebDistribution/public`) 一键部署到 **Cloudflare Pages**，实现全球 CDN 加速、自动化 SSL/TLS 证书分发和无服务器运维。

---

## 方案优势
1. **全球边缘网络 (Anycast CDN)**：全球 300+ 城市边缘节点直连，海外及国内访问延迟低至 10-30ms。
2. **零服务器维护**：纯静态资源托管，防 DDoS 攻击，无需 Docker Swarm 或 Nginx 维护。
3. **无限免费带宽**：Cloudflare Pages 对静态资源请求与流量完全免费。
4. **自动化 Git 联动**：GitHub 提交代码即自动构建并原子切换生效。

---

## 部署步骤

### 方法一：通过 Cloudflare Dashboard (推荐，可视化与持续部署)

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 导航至左侧菜单 **Compute (Workers) → Pages**。
3. 点击 **Create application** → 选择 **Pages** → **Connect to Git**。
4. 授权并关联当前 AetherRoute 的 GitHub 仓库。
5. 配置构建与部署参数：
   - **Project name**: `aetherroute`
   - **Production branch**: `main`
   - **Framework preset**: `None` (纯静态 HTML/CSS/JS)
   - **Build command**: *(留空)*
   - **Build output directory**: `Services/WebDistribution/public`
6. 点击 **Save and Deploy**。
   - 10 秒内即可完成全球部署，获得默认分配域名（例如 `aetherroute.pages.dev`）。
7. **配置自定义独立域名 (Custom Domains)**：
   - 在项目页面点击 **Custom domains** → **Set up a custom domain**。
   - 输入您希望使用的自定义域名（例如 `aetherroute.com` 或直接使用默认的 `aetherroute.pages.dev`）。
   - Cloudflare 会自动配置 DNS CNAME 记录并秒级签发 Universal SSL/TLS 证书。

---

### 方法二：通过 Wrangler 命令行直接发布 (CLI 一键部署)

如果您需要在本地或 CI/CD 流水线中即时秒发：

```bash
# 1. 全局安装 Cloudflare Wrangler 工具（如未安装）
npm install -g wrangler

# 2. 登录 Cloudflare 账号
wrangler login

# 3. 进入工作区根目录并直接发布 public 静态目录
cd /Users/chenxu/IdeaProjects/AetherRoute
wrangler pages deploy Services/WebDistribution/public --project-name=aetherroute
```

---

## 路由重定向与缓存规则（已预置）
- `Services/WebDistribution/public` 内部已经包含标准的 `_headers` 和 `_redirects` 兼容文件。
- HTML 文件设置为实时协商校验 (`Cache-Control: public, max-age=0, must-revalidate`)。
- 图片与 SVG 资产具备长效强缓存，保障极速首屏体验。
