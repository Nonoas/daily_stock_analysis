# 云服务器 Web 界面访问指南

如果你已经把项目部署到云服务器，但不知道在浏览器里输入什么地址才能打开 Web 管理界面，这篇教程就是为你准备的。

> 其实就两步：让服务监听外网，再在浏览器里输入地址。

---

## 目录

- [方式一：直接部署（pip + python）](#方式一直接部署pip--python)
- [方式二：Docker Compose](#方式二docker-compose)
- [如何在浏览器里打开界面](#如何在浏览器里打开界面)
- [如何确认 Docker 重建已生效](#如何确认-docker-重建已生效)
- [访问不了？先检查这几项](#访问不了先检查这几项)
- [可选：Nginx 反向代理（绑定域名 / 80 端口）](#可选nginx-反向代理绑定域名--80-端口)
- [安全建议](#安全建议)

---

## 方式一：直接部署（pip + python）

### 第一步：修改 .env 中的监听地址

用编辑器打开 `.env`（在项目根目录，即包含 `main.py` 的目录），找到这一行：

```env
WEBUI_HOST=127.0.0.1
```

把 `127.0.0.1` 改成 `0.0.0.0`：

```env
WEBUI_HOST=0.0.0.0
```

> `127.0.0.1` 表示只有本机能访问，`0.0.0.0` 表示允许任何来源访问。云服务器需要把 `.env` 中的 `WEBUI_HOST` 改成 `0.0.0.0`，或在启动命令里显式传入 `--host 0.0.0.0`，才能从外网打开界面。

### 第二步：启动服务

在项目根目录执行：

```bash
# 只启动 Web 界面（不自动执行分析）
python main.py --webui-only

# 或者：启动 Web 界面（启动时执行一次分析；需每日定时分析请加 --schedule 或设 SCHEDULE_ENABLED=true）
python main.py --webui
```

启动成功后，终端会输出类似：

```
FastAPI 服务已启动: http://0.0.0.0:8000
```

如果你想让服务在退出终端后继续运行，可以用 `nohup`：

```bash
nohup python main.py --webui-only > /dev/null 2>&1 &
```

> 日志文件会由程序自动写入 `logs/` 目录，用 `tail -f logs/stock_analysis_*.log` 查看。

### 修改端口（可选）

默认端口是 8000。如果想改用其他端口，在 `.env` 里设置：

```env
WEBUI_PORT=8888
```

然后重启服务。

---

## 方式二：Docker Compose

### 第一步：确认已有 .env 配置

项目的 `docker/docker-compose.yml` 在容器内部已经自动设置了 `WEBUI_HOST=0.0.0.0`，你不需要在 `.env` 里再改监听地址，Docker 会自动处理。

Docker Compose 中的 `env_file: ../.env` 只会把 `.env` 作为**启动环境变量**注入容器，不会在容器内创建 `/app/.env`，也不会让 WebUI 保存配置时回写宿主机 `.env`。新版 WebUI 会在活跃 `.env` 文件缺少某些键时展示启动注入的同名环境变量作为兜底，因此页面上能看到 Docker 启动时注入的配置；但“导出 `.env`”仍只导出当前活跃配置文件内容。

如果希望 WebUI 中保存的配置在容器删除、重建或升级后继续保留，请把活跃配置文件放到已挂载的数据卷中，例如在 Compose 的 `environment` 中增加：

```yaml
- ENV_FILE=/app/data/runtime.env
```

同时保留 `../data:/app/data` 挂载。注意：如果启动时的 `../.env`、`docker run -e` 或 Compose `environment:` 里还保留同名旧值，容器重启后这些启动环境变量仍可能覆盖运行时文件中的保存值；要让 WebUI 保存值接管，请同步更新或移除启动环境中的同名配置。

### 第二步：启动服务

在项目根目录执行：

```bash
# 同时启动定时分析 + Web 界面（推荐）
docker-compose -f ./docker/docker-compose.yml up -d

# 或者只启动 Web 界面服务
docker-compose -f ./docker/docker-compose.yml up -d server
```

启动后查看状态：

```bash
docker-compose -f ./docker/docker-compose.yml ps
```

看到 `server` 服务状态为 `running` 就说明 Web 界面已经在运行了。

### 修改端口（可选）

默认端口是 8000。如果想改用其他端口，在 `.env` 里设置：

```env
API_PORT=8888
```

然后重新启动容器：

```bash
docker-compose -f ./docker/docker-compose.yml down
docker-compose -f ./docker/docker-compose.yml up -d
```

---

## 如何在浏览器里打开界面

服务启动后，在浏览器地址栏输入：

```
http://你的服务器公网IP:8000
```

例如，如果你的服务器 IP 是 `1.2.3.4`，就输入：

```
http://1.2.3.4:8000
```

如果你的域名已经解析到这台服务器，也可以直接用域名访问：

```
http://your-domain.com:8000
```

> **在哪里查公网 IP？** 登录你的云服务器控制台（阿里云/腾讯云/AWS 等），在实例列表里可以看到「公网 IP」或「弹性 IP」。

---

## 如何确认 Docker 重建已生效

### 使用上传包一键升级

源码构建部署可使用独立的 `scripts/upgrade-docker.sh`。把脚本复制到服务器部署目录，与现有的 `compose.yaml`、`deployment.env` 放在一起。适用于 **Linux、本机 Docker、单个运行中的 `server` 服务及本地 `build:`**；需要 Python 3 和支持 `up --wait-timeout`、`config --no-env-resolution` 的 Docker Compose v2。执行用户须有操作 Docker、写部署目录父目录及保留文件属主的权限。

本地 Windows 双击 `scripts/package-deploy.bat` 即可，无需参数，也可在项目根目录执行：

```bat
scripts\package-deploy.bat
```

脚本需要 Git 和 Python 3.8+，优先使用仓库 `.venv` 或 `venv` 中的 Windows Python，其次使用系统 `py -3` 或 `python`，不依赖 PowerShell 脚本执行策略或外部 tar。按 Git `origin` 仓库名生成 `dist/daily_stock_analysis.tar.gz`（tar + gzip），包含当前已修改但未提交的文件和未被 Git 忽略的新文件；排除环境配置、数据库、日志、授权缓存、开发缓存和本地依赖。包内布局为 `daily_stock_analysis/source/`，另附根目录的升级脚本，不包含服务器专属的 `compose.yaml`、`deployment.env`。这些文件由已有部署恢复，因此该包用于升级，不用于首次部署。

每次上传新版本完整部署包，与脚本放在同一目录，**不要先覆盖解压旧部署目录**。请将服务器升级脚本同步为支持项目名包的当前版本。该目录只保留一个待升级 `.tar.gz` 包（也兼容旧的 `upgrade.zip`）；多包时会拒绝选择，避免误升级。然后只需执行：

```bash
bash upgrade-docker.sh
```

脚本以自身所在目录定位部署，不要求命令行参数；从其他目录调用它的绝对路径也可。示例布局：

```text
部署目录/
├── upgrade-docker.sh
├── daily_stock_analysis.tar.gz
├── compose.yaml
├── deployment.env
└── source/                 # 与原 Compose build.context 相同的源码层级
    ├── main.py
    ├── requirements.txt
    └── docker/Dockerfile
```

新包须保持原有构建目录层级，可以直接包含部署内容，也可以外包一层目录；脚本通过构建上下文内的 `main.py`、`requirements.txt` 校验结构。压缩包中的路径穿越、链接、特殊文件及重复条目会被拒绝。纯官方源码 ZIP 与外层还有 `source/` 的自定义部署包不是同一种布局，不能直接互换。

执行流程：

1. 锁定本次升级，解析当前 Compose、容器、镜像和挂载。项目名及镜像引用不匹配、数据库目录没有持久化挂载、构建或挂载路径使用不支持的符号链接时，先报错，不替换目录。
2. 在部署目录旁的私有备份目录中解压、校验新包，并单独备份 `compose.yaml`、`deployment.env`、当前脚本和实际使用的 Dockerfile；恢复这些文件到待安装目录，使用独立镜像标签构建新源码。构建失败时旧服务继续运行。
3. 构建成功后停止 `server`，复制部署目录内的 bind mount 数据及引用的环境文件、secrets/configs 文件，保留 `.env` 和目录内的 `nbkj-nginx/`。对目录外的 bind mounts 和 Docker volumes 从停止的容器创建快照；容器内部未挂载的活跃运行时 `.env` 也会单独备份。
4. 将旧部署目录整体移入备份，再把待安装目录切换到原部署路径。**运行目录不保留旧代码残留，完整旧目录仅保留在备份中**。原配置和挂载数据已经恢复，不删除 Docker volumes，不执行镜像清理。
5. 创建新容器但暂不启动，恢复容器内未挂载的运行时环境文件，再启动并等待容器状态检查。成功后上传包已随旧目录移入备份，下次重新上传同名新包即可。

保留原 Dockerfile 可保住 apt/pip 镜像源等服务器修改，但新版新增的构建步骤不会自动合并；如新版依赖这些步骤，须先更新本地构建配方再升级。脚本保留已有 Compose 与环境配置，不会用新包模板覆盖生产设置。默认等待时间为 180 秒；不支持远程 Docker、额外构建上下文、可写临时挂载及配置多服务的整体替换。未挂载的运行时环境文件只支持容器工作目录或根目录，其他位置应先通过 `ENV_FILE` 放入数据卷。

备份位于部署目录父目录下的 `.<部署目录名>-upgrades/<UTC时间戳>-<随机标识>/`，权限限制为执行用户可访问。`previous/` 是原目录，`configuration/` 是单独配置备份，`external-mounts/` 是外部挂载快照；`manifest.json` 记录路径、旧镜像 ID、包校验值和阶段。旧数据目录、复制到新目录的数据、外部挂载快照及压缩包会同时占用磁盘，需要预留空间；脚本不会自动删除备份。

**失败与恢复**：新应用尚未启动时出现安装失败，脚本尝试恢复原目录、旧镜像引用和服务；进程强杀、断电或恢复步骤失败时，应根据终端输出和清单人工处理。新应用已经尝试启动后检查失败，数据库可能已被迁移，因此不会自动降级。恢复时先停止新服务并另存新数据，再恢复 `previous/`、清单里的旧镜像 ID 和所需外部挂载快照；容器内环境文件快照应在旧容器启动前恢复。不能仅换回源码就断言数据库兼容。快照一致性以单个 `server` 停止后没有其他写入者为前提。

`--wait` 只检查运行状态和镜像定义的健康检查。当前默认镜像的健康检查带宽松兜底，升级后仍须验证实际 Web/API、历史数据和 nginx 路由。

### 核对页面和镜像版本

先区分两件事：

1. **Docker 镜像发布版本**：看你部署时使用的镜像 tag，例如 `ghcr.io/zhulinsen/daily_stock_analysis:v3.12.0`。仓库的 Docker 发布由 `.github/workflows/docker-publish.yml` 按 `v*.*.*` Git tag 触发，所以 Docker 版本应以镜像 tag / GitHub Releases 为准。
2. **当前页面加载的前端构建**：看 WebUI “系统设置”页里的版本信息卡片，用来确认浏览器拿到的静态资源是否已经更新。

也就是说，**“系统设置”里的版本信息更适合判断前端是否重建成功，不等同于 Docker 镜像发布版本**。

WebUI 现在会在“系统设置”页展示只读的“版本信息”卡片，包含：

- `WebUI 版本`
- `代码版本`
- `构建时间`

正式 Docker / Desktop 发布会把 release tag 注入为 `WebUI 版本`，并把对应 commit
显示为 `代码版本`。直接从 Git clone 构建时，WebUI 会使用 `git describe` 和当前
commit；如果构建环境既没有发布信息也没有 Git 元数据，版本会明确显示为
`development`，不会再用构建时间冒充发布版本。

当你重新执行 `docker-compose -f ./docker/docker-compose.yml up -d --build`，或者单独重新执行前端 `npm run build` 后，可以刷新浏览器并进入“系统设置”，确认“代码版本”和“构建时间”是否已经变化；两者能共同确认浏览器当前加载的静态资源来自哪次代码和构建。

如果你想确认“我现在到底部署的是哪个正式版本”，优先用下面这些方式：

```yaml
# 方式 1：看 docker-compose / 部署脚本里的 image tag
image: ghcr.io/zhulinsen/daily_stock_analysis:v3.12.0
```

```bash
# 方式 2：回看你的拉取命令
docker pull ghcr.io/zhulinsen/daily_stock_analysis:v3.12.0
```

如果你一直使用 `latest`，建议改成显式版本 tag；否则很难仅凭容器内页面信息判断自己是否已经重复更新到同一版本。

在确认本地前端打包链路时，建议执行以下命令作为最小验证闭环：

```bash
cd apps/dsa-web
npm ci
npm run lint
npm run build
```

其中 `build` 成功后，`static` 下生成的 `index.html`/JS/CSS 资源会包含本次版本、
commit、构建时间，并生成 `build-info.json`。启动时会比较该文件中的源码摘要，
因此即使 `rsync -a` 保留了旧时间戳，也能识别源码与静态产物不一致并重新构建。
刷新后在“版本信息”卡片中应能见到变化。

---

## 访问不了？先检查这几项

### 1. 安全组 / 防火墙没有放行端口

这是最常见的原因。云服务器默认只开放 22（SSH）端口，需要手动放行 8000（或你改的端口）。

**操作方法**（以阿里云为例）：
1. 登录阿里云控制台 → 云服务器 ECS → 找到你的实例
2. 点击「安全组」→「配置规则」→「添加安全组规则」
3. 方向选「入方向」，端口范围填 `8000/8000`，授权对象填 `0.0.0.0/0`，点击「确定」

腾讯云、AWS 等云厂商操作类似，找到「安全组」或「防火墙规则」，新增一条允许 TCP 8000 端口的入站规则即可。

### 2. 服务器系统防火墙拦截了

如果你的系统开启了 `ufw` 或 `firewalld`，也需要放行端口：

```bash
# Ubuntu / Debian（ufw）
sudo ufw allow 8000

# CentOS / RHEL（firewalld）
sudo firewall-cmd --permanent --add-port=8000/tcp
sudo firewall-cmd --reload
```

### 3. 直接部署时 .env 里的 WEBUI_HOST 没改

这是第二常见原因。`.env` 里默认是 `WEBUI_HOST=127.0.0.1`，这样服务只监听本机，外网根本连不上。

改法：打开 `.env`，把 `WEBUI_HOST=127.0.0.1` 改成 `WEBUI_HOST=0.0.0.0`，然后重启服务；也可以在启动命令里显式添加 `--host 0.0.0.0`。

> Docker 方式不需要改这个，可以跳过。

### 4. 端口号对不上

检查访问地址里的端口是否和 `.env` / 启动命令里设置的端口一致。

- 直接部署：默认 8000，可通过 `WEBUI_PORT=xxxx` 修改
- Docker：默认 8000，可通过 `API_PORT=xxxx` 修改

### 5. 页面能打开，但 UI 元素异常变大 / 布局错乱

**症状**：浏览器能访问到 8000 端口，页面有内容，但文字、按钮、卡片尺寸异常大，没有正常布局与配色。

**根因**：`static/index.html` 存在但 CSS/JS 资源缺失（`static/assets/` 为空或不存在），浏览器加载了 HTML 框架但无法拿到样式与脚本，退化为裸 HTML 渲染。

可先用浏览器开发者工具（F12 → Network 标签页）检查是否有 `/assets/index-*.js`、`/assets/index-*.css` 的 **404** 错误。若有，按以下方式修复：

**Docker 用户**：

```bash
docker-compose -f ./docker/docker-compose.yml down
docker-compose -f ./docker/docker-compose.yml build --no-cache
docker-compose -f ./docker/docker-compose.yml up -d
```

重建完成后，用 `Ctrl+Shift+R` 强制刷新浏览器缓存，再访问页面。

**直接部署用户**：先确保已安装 Node.js 18+（推荐 20+），然后手动构建前端：

```bash
cd apps/dsa-web
npm ci
npm run build
cd ../..
python main.py --webui-only
```

---

## 可选：Nginx 反向代理（绑定域名 / 80 端口）

离线部署统一使用项目 `docker/docker-compose.yml`，流程见[完整指南：手动构建镜像](full-guide.md#手动构建镜像)：将 `scripts/package-image.cmd` 生成的 `image.tar`、`image.json`、`compose.template.yml`、`update-image.sh` 四个文件上传部署目录，保留 `deployment.env` 与 `state/`，执行 `bash update-image.sh`。首次迁移须保留旧 Compose 以识别实例设置；成功确认 HTTP、Nginx 与登录后可归档旧根目录 Compose。`deployment.env` 会明确注入容器，新流程不启动 Caddy、不改动既有 Nginx，失败时保留完整旧配置回滚路径。

如果你有域名，或者不想在地址里带 `:8000`，可以用 Nginx 做反向代理，把 80/443 端口流量转发给后端服务。

### 安装 Nginx

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y nginx

# CentOS
sudo yum install -y nginx
```

### 配置文件示例

新建文件 `/etc/nginx/conf.d/stock-analyzer.conf`，内容如下（把 `your-domain.com` 改成你的域名或 IP）：

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 支持 WebSocket（Agent 对话页面需要）
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### 启用配置并重启 Nginx

```bash
sudo nginx -t            # 检查配置有没有语法错误
sudo systemctl reload nginx
```

配置成功后，直接用 `http://your-domain.com` 访问即可，不需要带端口号。

> **使用 Nginx 后的注意事项**：
> - 如果你开启了 Web 登录认证（`ADMIN_AUTH_ENABLED=true`），建议在 `.env` 中把 `TRUST_X_FORWARDED_FOR=true` 一并打开，否则系统可能无法正确识别真实 IP。该选项适用于**单层可信反向代理**（Nginx → App）部署；如果使用多级代理或 CDN（CDN → Nginx → App），登录限流的 key 可能退化为边缘代理 IP 而非真实客户端 IP，需根据实际拓扑评估。
> - 如需 HTTPS，可以用 [Certbot](https://certbot.eff.org/) 自动申请免费的 Let's Encrypt 证书。

---

## 安全建议

### GitHub 登录与白名单

默认支持公网 HTTP 和 HTTPS 回调。`GITHUB_OAUTH_ALLOW_HTTP` 默认 `true`；在服务器设为 `false` 后，包含本机回环地址在内的 HTTP 回调均被拒绝，HTTPS 不受影响。未配置或空值允许 HTTP，非法布尔值拒绝 HTTP。该开关由服务器管理，Web/API 和配置导入不能修改；仅设置开关不会开启登录保护。它只控制回调地址校验，不关闭 HTTP 监听或自动跳转 HTTPS。HTTP 会话不加密；Cookie 仍保留 HttpOnly、SameSite=Lax，HTTPS Cookie 保留 Secure。修改启动环境后重建容器；配置文件修改后重启服务。此策略对本地、Docker、API/Web、主动启用认证的 Desktop 浏览器登录一致，CLI 分析和 GitHub Actions 分析任务不受影响。

登录返回 `oauthError=unavailable` 时，查看后端警告中的 `stage`（`token_exchange` 换取令牌、`profile` 获取用户、`emails` 获取邮箱；无请求信息时为 `unknown`）、`error`（异常类型）、`status`（HTTP 状态码，无响应时为 `None`）和 `rate_limited`（429 或 403 且剩余额度为零时为 `True`）。日志不包含凭据、授权码、完整 URL、异常消息或响应正文。超时应排查后端网络与代理；未认证探测请求额度耗尽，不能证明 OAuth 认证请求也被限流。

Web 登录使用 GitHub OAuth，仅白名单中的用户可以取得会话。上线前先在 GitHub 的 **Settings → Developer settings → OAuth Apps** 创建应用，把 **Authorization callback URL** 设置为：

```text
http://dsa.example.com/api/v1/auth/github/callback
```

将域名替换成实际网站域名，且与服务器配置完全一致；使用非默认端口时也须包含端口。默认允许 HTTP 回调，设置 `GITHUB_OAUTH_ALLOW_HTTP=false` 后要求 HTTPS（包括本机回环地址）。申请的权限为 `read:user`、`user:email`，用于读取个人资料、头像和邮箱，不申请仓库权限。邮箱必须已验证，可以是私有邮箱。

在服务器启动环境、活跃 `.env` 或自定义部署包使用的 `deployment.env` 中配置：

```env
ADMIN_AUTH_ENABLED=true
GITHUB_OAUTH_CLIENT_ID=your-client-id
GITHUB_OAUTH_CLIENT_SECRET=your-client-secret
GITHUB_OAUTH_CALLBACK_URL=http://dsa.example.com/api/v1/auth/github/callback
GITHUB_OAUTH_ALLOW_HTTP=true
GITHUB_ALLOWED_USERS=your-github-login
```

白名单按 **GitHub 用户名** 匹配，英文逗号分隔、忽略大小写，不接受邮箱、组织名或通配符。真实 Secret 只放服务器，不要提交到 Git 或填到前端构建变量。OAuth 配置和白名单由服务器管理，网页认证卡片、通用配置 API 和 `.env` 导入不能改写这些项；导入相同值不受影响。

**Client ID、Secret、回调地址或白名单任一非空，或 `ADMIN_AUTH_ENABLED=true`，都会启用访问保护。** 配置缺失、白名单为空或格式错误时拒绝登录，不退回密码登录或匿名访问。只有全部 GitHub 项为空且显式保护开关关闭时，才保留原本的本地免登录模式。部署公网服务务必启用保护。

修改启动环境后重启进程；Docker 使用 `env_file` 注入时须重建容器，单纯 `docker compose restart` 不会重新注入环境。自定义打包不会携带本地 `.env`，所以升级前应先在服务器补齐上述配置；后续升级脚本会保留服务器配置。不要把示例占位值作为实际凭据。

登录回调会校验浏览器 state、PKCE，并通过 GitHub 查询当前用户及已验证邮箱。用户名不在白名单时拒绝发放会话；每个受保护 API 请求再次检查当前白名单。名单变更经过配置刷新或进程重启后，已移除用户的旧会话同样不能访问。页面设置卡片显示登录用户的头像、用户名和邮箱；GitHub access token 不返回浏览器、不写入会话 Cookie、不保存到数据库。

**兼容与恢复**：原密码登录、首次设置密码、修改密码和网页开关认证入口已停用；旧接口 `POST /api/v1/auth/login`、`/settings`、`/change-password` 返回 410（未登录访问受保护接口仍可能先返回 401）。旧密码会话无效，`python -m src.auth reset_password` 不再用于登录。旧密码哈希文件没有删除，回退旧版本时仍可使用；无需数据库迁移。签名密钥继续保存在 `DATABASE_PATH` 所在目录的 `.session_secret`，应持久化整个数据目录。退出登录沿用原有“撤销全部会话”行为，多进程通过重新读取签名密钥立即失效。

本地与 Docker Web 服务共用这套流程；反向代理需正确转发回调路径，HTTPS 回调会令 Cookie 使用 Secure。GitHub Actions 的纯 CLI 分析、通知和报告链路不需要 OAuth 配置。桌面端默认本地免登录不变；如主动启用 GitHub 保护，登录按钮会打开系统浏览器，并在该浏览器使用工作台，浏览器会话不会复制回 Electron 内置窗口。桌面端本地回调须与当前监听地址、端口一致。

若设置页显示 `Failed to load system configuration`，这是后端系统配置接口的错误信息，应查看容器日志中的同名错误和异常堆栈。旧版本的 GitHub Client ID 和回调地址元数据使用了 API 不支持的 `input` 控件类型，会使配置响应校验失败；需更新包含 `text` 类型修复的后端镜像，仅刷新浏览器或修改 OAuth 凭据不能修复此问题。

---

遇到其他问题？欢迎 [提交 Issue](https://github.com/ZhuLinsen/daily_stock_analysis/issues)。
