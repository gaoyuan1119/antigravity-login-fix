# Antigravity 登录卡住排查手册（macOS / Clash Rule + TUN）

> 一个真实案例的脱敏复盘：浏览器里 Google 验证通过，Antigravity 却一直停在登录页。
> 结论是：问题通常不止一层，按 **网络 → OAuth 回调/Token → 账号资格** 三层排查，比盲目改 Clash 规则有效得多。
>
> 本文附一个 **只读诊断脚本**：`antigravity-login-doctor.sh`。它不会修改任何配置。

> **English TL;DR:** If Google login succeeds in the browser but Antigravity stays on the login/onboarding screen, debug three layers in order: (1) whether TUN/system proxy is *actually* active, (2) whether the local OAuth callback and `oauth2.googleapis.com/token` exchange work, and (3) whether Google considers the account eligible (`ineligible` / `not eligible`). A proxy IP does not change account eligibility. After account verification, fully quit and reopen Antigravity.

---

## TL;DR

- **不要切 Clash Global**。Rule 模式足够，Global 只会让国内流量也绕路。
- **先确认 TUN / 系统代理真的生效**，不要只看 Clash Verge 界面的开关。
- Antigravity 的 OAuth 回调是 `http://localhost:<随机端口>/auth/callback`，**不是** `antigravity://`。后者只是深链。
- 浏览器显示 “Auth Success” 不等于客户端登录成功。继续看 `language_server.log` 里有没有 `Auth succeeded`、`oauth2.googleapis.com/token` 报错。
- 如果出现 `not eligible` / `ineligible`，这是 **Google 账号资格**问题，代理、TUN、DNS 都救不了。完成 Google 验证，或换一个符合条件的个人账号。
- 账号验证完成后，**完全退出 Antigravity 再打开**；只关窗口或只刷新页面往往不够。

---

## 适用场景

> 测试环境：macOS 26.5.2（arm64）、Antigravity 2.26.0、Clash Verge Rev + mihomo、混合端口 `7897`。不同版本/客户端思路相同，命令按实际端口调整。

- macOS 上使用 Antigravity Desktop。
- 使用 Clash / Clash Verge Rev 的 **Rule 模式**，可能同时开了 TUN 或系统代理。
- 浏览器可以正常打开 Google、完成 Google 账号验证。
- 登录后浏览器跳回 `localhost` 回调页，但 Antigravity 仍停在：
  - “Welcome to Antigravity / Continue with Google”
  - 一直转圈
  - 空白页
  - 或反复回到登录页

---

## 症状

典型表现：

1. 在 Antigravity 点击登录。
2. 系统浏览器打开 Google OAuth 页面。
3. Google 账号验证通过，浏览器地址栏出现类似：
   ```text
   http://localhost:<port>/auth/callback?state=...&code=...
   ```
   随后跳到：
   ```text
   https://antigravity.google/auth-success?app=antigravity
   ```
4. 回到 Antigravity，仍然停在登录页，或界面空白。

这个时候不要立刻断定“回调没回来”。回调可能已经完成，失败发生在后面的 **code 换 token**，或者 **账号 eligibility** 检查。

---

## 三层模型

### 第 1 层：网络层

Antigravity 不只有 Chromium 界面，还有一个 Go 写的 `language_server` 子进程。两者可能走不同的网络路径：

- Chromium 可能使用 `--proxy-server` 参数或系统代理。
- `language_server` 是 Go 程序，可能读取 `HTTPS_PROXY` 环境变量，也可能完全依赖 TUN。
- macOS 图形应用默认 **不继承终端里的代理环境变量**，所以“终端能 curl 通”不代表 App 能通。

本案例里最开始的坑：

- Clash Verge 界面看起来开了 TUN，但实际 API 返回 `tun.enable=false`。
- macOS `scutil --proxy` 显示系统代理也是关闭的。
- 直连 `https://www.google.com` 超时；只有显式 `curl -x http://127.0.0.1:7897` 能通。

也就是说：**代理客户端在运行，但全局接管没有真正生效。**

### 第 2 层：OAuth 回调与 Token

Antigravity 2.24 的登录流程大致是：

1. `language_server` 生成 Google OAuth URL，并打印 `ANTIGRAVITY_OPEN_URL: ...`。
2. Electron 主进程用系统浏览器打开这个 URL。
3. `language_server` 在本地监听一个随机端口，回调地址是：
   ```text
   http://localhost:<port>/auth/callback
   ```
4. 浏览器带上 `code` 和 `state` 访问本地回调。
5. `language_server` 用 code 去 `https://oauth2.googleapis.com/token` 换 token。
6. 换到 token 后，再请求用户信息、项目、模型列表等。

常见失败点：

- 本地回调端口被代理/防火墙拦截。
- 浏览器无法访问 `localhost`（代理 bypass 配错）。
- 使用了 `<-loopback>` 启动参数，强制把回环也送进代理。
- `language_server` 进程太旧，连接池里是失效的代理连接，POST 换 token 时 `EOF`。
- 代理节点对长连接/HTTP2 不友好，偶尔 `EOF`、TLS timeout。

日志里的典型关键字：

```text
Failed to get OAuth token: failed to compute token:
Post "https://oauth2.googleapis.com/token": EOF

Post "https://oauth2.googleapis.com/token": net/http: TLS handshake timeout
```

### 第 3 层：账号资格（Eligibility）

这是最容易被忽略的一层。

OAuth 全部成功、token 也保存了，但 App 仍然停在 onboarding，原因是 Google 返回：

```text
Your current account is not eligible for Antigravity.
Verify your account to continue.

Alternatively, try signing in with another personal Google account.
```

这时 `HasAuthToken` 可能是 `true`，`GetUserStatus` 甚至能返回用户名和订阅信息，但 `GetAuthStatus` 返回 `ineligible`。App 的行为是合理的：**它不让你进入，是因为账号不符合资格，而不是网络错误。**

常见原因：

- 账号年龄/身份未完成 Google 验证。
- 账号所在国家/地区不在 Antigravity 支持范围。
- 账号状态异常（例如关联订阅欠费、被风控）。
- 使用了不符合要求的账号类型（例如某些 Workspace/企业账号）。

> 代理 IP 不会改变 Google 账号的注册国家/地区，也不会绕过 eligibility。

---

## 快速判断表

| 现象 | 更可能的原因 | 下一步 |
|---|---|---|
| 浏览器地址栏停在 `localhost:<port>/auth/callback`，页面报 `ERR_CONNECTION_REFUSED` | 本地回调监听失败 / 端口被代理 | 检查 `language_server` 监听端口；确认 `localhost` 直连 bypass |
| 浏览器显示 Auth Success，App 仍登录页 | token 交换失败，或账号 ineligible | 看 LS 日志的 `oauth2...token`；再看是否有 `not eligible` |
| LS 日志反复 `oauth2.googleapis.com/token: EOF` | 旧 LS 连接池 / 节点不稳定 | 完全退出 App，重启 LS；换节点；测试 POST |
| `GetAuthStatus` 返回 `ineligible` | Google 账号资格 | 完成 Google 验证；换个人账号；人工复核 |
| 只有显式 `curl -x 127.0.0.1:7897` 能通，直连超时 | TUN/系统代理没生效 | 修 TUN 或系统代理，不要继续改 Antigravity |
| App 双击没反应/一闪退 | 继承了 `ELECTRON_RUN_AS_NODE=1` | 用 `env -u ELECTRON_RUN_AS_NODE open -a ...` 启动 |

---

## 排查步骤

### 0. 先记录现状，不要急着改

```bash
sw_vers
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /Applications/Antigravity.app/Contents/Info.plist

ps -ww -o pid,command -p "$(pgrep -f '/Applications/Antigravity.app/Contents/MacOS/Antigravity' | head -1)"
```

如果是旧版本，先升级。Antigravity 的自动更新会在退出后安装已下载的版本；更新后再复现，避免把旧版本 bug 和新问题混在一起。

### 1. 确认 TUN / 系统代理真的生效

```bash
# 系统代理
scutil --proxy

# TUN 路由（Clash 常用 198.18.0.0/15）
netstat -rn -f inet | grep -E '198\.18|utun'
ifconfig | grep -E '^utun|inet 198\.18'
```

判断标准：

- 系统代理生效：`HTTPEnable : 1`、`HTTPSEnable : 1`，端口指向混合端口。
- TUN 生效：存在 `utun` 接口，路由表里有 `198.18.0.0/15` 或至少 `198.18.0.1`。
- 如果 Clash 界面显示开启，但这里没有，**以命令输出为准**。

然后做端到端测试：

```bash
# 直连（走 TUN/系统路由）
curl --noproxy '*' -sS -o /dev/null -m 10 \
  -w 'google=%{http_code} time=%{time_total}\n' https://www.google.com

curl --noproxy '*' -sS -o /dev/null -m 10 \
  -w 'oauth=%{http_code} time=%{time_total}\n' https://oauth2.googleapis.com/token

# 显式走 Clash 混合端口
curl -sS -o /dev/null -m 10 -x http://127.0.0.1:7897 \
  -w 'clash=%{http_code} time=%{time_total}\n' https://oauth2.googleapis.com/token
```

说明：

- `oauth` 返回 `404` 是正常的（GET 没带参数）。
- 如果 `clash` 通、直连不通，就是 TUN/系统代理没有接管；先修这一层。
- 再测 POST，确认 token 端点不是只允许 GET：

```bash
curl -sS -o /dev/null -m 10 -x http://127.0.0.1:7897 \
  -X POST \
  -d 'grant_type=refresh_token&refresh_token=x&client_id=x' \
  -w 'post=%{http_code}\n' \
  https://oauth2.googleapis.com/token
```

期望 `400/401`，不要是 `000`。

### 2. 只保留一个代理栈

如果同时运行 Clash、其他 VPN、零信任客户端（例如公司 VPN），它们会争抢：

- TUN 接口
- 默认路由
- DNS
- 系统代理

测试时只保留 Clash，退出其他会改网络的客户端。否则你无法判断是谁在接管流量。

### 3. 检查 Antigravity 的启动参数

```bash
ps -ww -o command= -p "$(pgrep -f '/Applications/Antigravity.app/Contents/MacOS/Antigravity' | head -1)"
```

重点看两个东西：

1. 是否带 `<-loopback>`：
   ```text
   --proxy-bypass-list=<-loopback>;localhost;127.0.0.1;::1;*.local
   ```
   `<-loopback>` 会取消 Chromium 对回环地址的隐式直连，容易和 OAuth 回调冲突。建议去掉，只保留：
   ```text
   --proxy-bypass-list=localhost;127.0.0.1;::1;*.local
   ```
   如果使用 TUN，更简单：启动时不要传 `--proxy-server`，让流量走 TUN。

2. 是否继承了 `ELECTRON_RUN_AS_NODE=1`：
   ```bash
   echo "${ELECTRON_RUN_AS_NODE:-unset}"
   ```
   这个变量会让 Electron 以 Node 模式运行，表现是“双击/启动后立即退出，没有窗口”。从某些终端、IDE 或自动化环境启动时可能遇到。

### 4. 完全重启 App 和 language_server

不要只关窗口。Electron 主进程和 LS 可能还在后台跑。

```bash
osascript -e 'quit app "Antigravity"'
sleep 2

# 确保 LS 也退出
pkill -f '/Applications/Antigravity.app/Contents/Resources/bin/language_server' 2>/dev/null

# 用干净环境重新打开（避免 ELECTRON_RUN_AS_NODE）
env -u ELECTRON_RUN_AS_NODE open -a /Applications/Antigravity.app
```

如果你需要显式代理启动，并且不想依赖 TUN：

```bash
env -u ELECTRON_RUN_AS_NODE open -a /Applications/Antigravity.app --args \
  --proxy-server=http://127.0.0.1:7897 \
  --proxy-bypass-list='localhost;127.0.0.1;::1;*.local'
```

> 注意：`open --args` 会替换本次启动参数；如果参数是第三方工具注入的，先关掉工具的“代理注入/自定义启动参数”，否则重启后又被加回来。

### 5. 看日志，区分“回调失败”和“换 token 失败”

```bash
tail -f ~/Library/Logs/Antigravity/language_server.log
```

在新终端里点一次登录，重点看：

```text
ANTIGRAVITY_OPEN_URL: ...
listening on ... port ...
Auth succeeded
Failed to get OAuth token
oauth2.googleapis.com/token
OAuth2 flow failed
state mismatch
no authorization code received
```

判断：

- 浏览器地址栏出现 `localhost:<port>/auth/callback`，但 App 没反应：
  - 看这个端口是否在监听：
    ```bash
    lsof -nP -iTCP -sTCP:LISTEN | grep language_server
    ```
  - 正常会有两个基础端口；登录过程中会多一个临时端口，那就是回调监听。
  - 如果没有多出来的端口，说明 LS 没有成功启动回调监听。
- 浏览器显示 Auth Success，但日志里有 `oauth2.googleapis.com/token` 的 `EOF` / TLS timeout：
  - 这是 token 交换失败，不是回调没到。
  - 先完全重启 LS；仍反复出现再换节点/检查代理。
- 日志里有 `state mismatch`：
  - 常见于登录 URL 是旧 LS 生成的，回调却打到了新 LS；重新从 App 发起登录，不要复用旧浏览器标签页。
- 日志里有 `not eligible` / `ineligible`：
  - 这是账号资格问题，转到下一节。

### 6. 账号资格验证

如果 App 一直停在 onboarding，但日志显示 `Auth succeeded`、token 也有效，重点检查账号资格。

在 App 登录页可以点：

- **Having trouble signing in?**
- 或直接完成 Google 返回的验证链接。

本案例中，Google 返回的是一个 **QR/IAP 身份验证页**，需要本人用手机扫码完成。完成后：

1. 完全退出 Antigravity。
2. 重新打开。
3. 让它重新请求一次 `GetAuthStatus`。
4. 如果通过，界面会直接进入主界面，不再停在 onboarding。

如果验证完成后仍然是 `not eligible`：

- 换一个**个人 Gmail 账号**试。
- 检查账号的年龄、国家/地区、订阅/风控状态。
- 到 Google AI Developers Forum 申请人工复核。
- 不要用来路不明的“账号修复工具”自动登录 Google 账号。

参考：

- [Google Antigravity FAQ](https://antigravity.google/docs/faq)
- [gemini-cli issue: Account not eligible for Antigravity](https://github.com/google-gemini/gemini-cli/issues/14858)
- [Eligibility check failed 的人工复核讨论](https://discuss.ai.google.dev/t/eligibility-check-failed-personal-gmail-age-verified-requesting-manual-review/191552)

### 7. 钥匙串与自动更新

如果日志出现：

```text
Failed to save token to keyring, falling back to file: exit status 45
```

说明 token 写入钥匙串失败，退回到文件存储。它不一定是致命的，但会导致登录状态不稳定。

可以检查：

```bash
security show-keychain-info ~/Library/Keychains/login.keychain-db
```

如果是 locked，先在“钥匙串访问”里解锁 login 钥匙串，再重启 App。不要为了“清空状态”盲目删除钥匙串条目或整个 token 文件。

另外，确认 App 已经是最新版本。旧版本的 OAuth/连接池 bug 可能已经在新版本修复。

---

## 本案例时间线（脱敏）

1. Antigravity 2.24 + 一个已经运行 6 天的 `language_server`。
2. Clash 界面显示 TUN，但实际 `tun.enable=false`，系统代理也是关闭的；直连 Google 超时。
3. 打开 TUN 后，重启 LS；`Auth succeeded` 出现，但旧 LS 仍有 `oauth2...token: EOF`。
4. 退出 App，自动升级到 2.26；用干净参数启动（无 `--proxy-server`、无 `<-loopback>`、无 `ELECTRON_RUN_AS_NODE`）。
5. 浏览器完成 Google 登录，回调 `localhost:<port>/auth/callback` 成功。
6. `HasAuthToken=true`，但 `GetAuthStatus` 返回 `ineligible`：“Your current account is not eligible for Antigravity.”
7. 完成 Google 的 QR/IAP 身份验证。
8. 完全退出并重新打开 Antigravity；`GetAuthStatus` 返回 `hasValidAuth=true`，进入主界面。

---

## 常见误区

- **“浏览器 Google 通过了，所以客户端一定登录成功。”**  
  不一定。回调成功只说明 code 到了本地；后面还有 token 交换和 eligibility 检查。

- **“回调是 `antigravity://`，所以是 URL scheme 没注册。”**  
  Antigravity 的主 OAuth 回调是 `http://localhost:<port>/auth/callback`，由 LS 监听；`antigravity://` 是另一条深链通道。

- **“TUN 开了，所以所有进程都走代理。”**  
  以 `scutil`、路由表和实际 `curl` 为准。Clash 界面状态可能和实际不一致。

- **“进程名没写进规则，所以漏网了。”**  
  如果规则里有 `DOMAIN-KEYWORD,google,Google`，Google 域名通常已经命中；`MATCH` 也往往会兜底到代理组。先看实际连接和日志，不要先加一堆 PROCESS-NAME。

- **“加 `<-loopback>` 能让所有流量都走代理。”**  
  这会把回环也送进代理，正好容易破坏 OAuth 回调。不要加。

- **“账号 not eligible 是代理 IP 问题。”**  
  代理 IP 不会改变 Google 账号的国家/地区或资格状态。换节点通常没用。

---

## 诊断脚本

`antigravity-login-doctor.sh` 是一个 **只读** 诊断脚本，不会修改配置、不会杀进程、不会读写 token。

```bash
chmod +x antigravity-login-doctor.sh
./antigravity-login-doctor.sh
```

它会检查：

- macOS / Antigravity 版本
- App 与 `language_server` 是否在运行
- 启动参数中的 `<-loopback>`、`--proxy-server`、`ELECTRON_RUN_AS_NODE`
- 系统代理、TUN 路由
- Google / OAuth 端点的直连与显式代理连通性
- `language_server.log` 里的关键错误
- 本地回调监听端口
- 其他可能冲突的 VPN 客户端
- 钥匙串状态

可选环境变量：

```bash
MIXED_PORT=7897 ./antigravity-login-doctor.sh
```

脚本退出码：`0` 表示没有发现关键问题，`1` 表示至少有一个关键项失败。它只用于排查，不负责自动修复。

---

## 隐私与安全

- 本文和脚本不包含任何账号、token、订阅链接、节点密码。
- 分享日志前，先删除：
  - `--csrf_token`
  - `--host_bridge_token`
  - OAuth `code` / `state`
  - 邮箱、用户名
  - 代理订阅链接和节点信息
- 不要把自己 App 的 `DevToolsActivePort`、CDP WebSocket URL、完整进程参数直接发到公开 issue。
- 不要使用要求你输入 Google 密码的第三方“修复工具”。

---

## Repository layout

```text
antigravity-login-fix/
├── README.md
└── antigravity-login-doctor.sh
```

---

## License

发布到 GitHub 前，建议补一个许可证文件。常见选择：

- MIT：最宽松，适合小工具。
- Apache-2.0：带专利授权条款，适合更正式的项目。

本仓库当前未附带许可证，请按你的发布意图选择。
