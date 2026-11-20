# 单端口多出口中转代理部署模板

这是一套可复用的 **sing-box 1.14+** 中转部署与客户端分流模板，从一台已硬化的东京中转（单端口 `443` TCP/UDP、多出口身份、WireGuard 落地、HTTP 上游）提炼而来。仓库里只有占位符，不含任何真实 IP、UUID、密码或密钥。

把填写后的配置放在 `server/config.json`、`clients/flclash-strict.yaml`、`clients/shadowrocket.conf`。这些路径已在 `.gitignore` 中，不要提交。

**未填写的模板不能部署。** JSON 能被解析，不等于 `sing-box check` 会通过，也不等于配置在语义上可用。

## 架构概览

```
客户端（FlClash / Shadowrocket）
  VLESS + Reality  TCP/443  ──┐
  Hysteria2         UDP/443  ──┴──►  中转主机（Ubuntu / Debian）
                                       sing-box
                                       │
                                       ├─ 用户 jp-direct  → direct（中转本机直出）
                                       ├─ 用户 starzone   → WireGuard（纯 IPv4 落地）
                                       ├─ 用户 hk-proxy   → HTTP 上游（香港）
                                       └─ 用户 us-proxy   → HTTP 上游（阿灵顿）
```

要点：

- **一条 443 端口、两套入站复用**：VLESS + Reality（TCP）与 Hysteria2（UDP）。用 `users[].name` 区分出口身份，客户端选不同节点就是选不同用户。
- **落地出口只走 IPv4**：WireGuard 不配 IPv6 地址和 `::/0`，对端写死 IPv4，`mtu: 1280`，`persistent_keepalive_interval: 15`。
- **落地 DNS 走隧道内加密解析**：主用 Cloudflare DoT（`1.1.1.1:853`），备用 Quad9 DoH（`9.9.9.9`），失败时不回退到中转机本地 DNS。中转直出同样用 DoH 主备。香港 / 阿灵顿是 HTTP 上游，服务端不做本地 `resolve`，把域名交给上游解析。
- **路由顺序不能乱**：先拒应用层 UDP → 按用户 resolve（落地加 `ipv4_only`）→ 拒 WG 反向入站 → 拒私网 / 云元数据 → 按 `auth_user` 分流 → **末尾默认拒绝**，防止规则写漏后误走日本直连。
- **客户端配合**：节点关闭 UDP 转发和 IPv6；Google / Gemini / YouTube 规则置顶；`Google` 组不放 `DIRECT`；拦截 Google 相关 UDP/QUIC。服务端拒绝 UDP，或客户端关掉某个节点的 UDP 转发，都只作用于已经进入该代理的流量，不能阻止设备在隧道外直连 STUN、QUIC 或其它 UDP。

> 香港和阿灵顿这两条上游本身是明文 HTTP 代理。你到中转的链路，以及目标站的 HTTPS，仍然是加密的。这是上游供应商的协议限制，不换加密上游就改不了。

## 自动部署（Ubuntu / Debian）

默认路径是 `/etc/sing-box-jp`、`/usr/local/bin/sing-box`、systemd 单元 `sing-box-jp`。脚本默认安装官方 **sing-box 1.14.4**（可用 `--version` 覆盖）。模板使用 1.14+ 的 DNS `evaluate` / `respond` 语法和 `endpoints` 里的 WireGuard，更旧的版本不能直接使用。

`scripts/deploy.sh` 默认是 dry-run，只打印计划、不改系统。只有加上 `--apply` 才会下载、写入和启动。它从 GitHub 官方 Release 按架构下载固定版本，核对照官方资产的 SHA-256，不执行 `curl | sh`。配置内容不会被打印到命令行或日志。

### 复制即用的命令

在一台新的 Ubuntu 或 Debian 主机上：

```bash
git clone https://github.com/tianyin231/proxy-deploy-kit.git
cd proxy-deploy-kit

# 1. 从模板生成一份待填写的本地配置（已存在则拒绝覆盖）
./scripts/init-config.sh --out ./server/config.json

# 2. 编辑 ./server/config.json：填完所有 <PLACEHOLDER>
#    端口必须写成 JSON 数字，不能带引号。
#    按配置中的路径放好 /etc/sing-box-jp/tls-cert.pem 与 tls-key.pem
#    （或先在本机生成证书，并在配置里写对应路径）。

# 3. 预览（默认 dry-run，不应改动任何系统文件）
sudo ./scripts/deploy.sh --config ./server/config.json

# 4. 确认计划后再安装并启动
sudo ./scripts/deploy.sh --config ./server/config.json --apply

# 5. 防火墙和 BBR 是可选项，默认不跑。确认 SSH 端口已放行后再执行：
sudo ./scripts/harden-ubuntu.sh
sudo ./scripts/harden-ubuntu.sh --apply
# 也可以在第 4 步加上 --harden。脚本会识别 sshd 的真实监听端口，避免只放行 22 却把你锁在门外。

# 6. 本地验收
sudo ./scripts/verify-proxy.sh --skip-network
```

生成密钥和 HY2 证书（在填写配置之前）：

```bash
sing-box generate reality-keypair
sing-box generate rand --hex 8          # short id，16 个十六进制字符
sing-box generate uuid                  # 每个出口用户各生成一次
sing-box generate rand --hex 16         # 可用作 HY2 密码

sudo mkdir -p /etc/sing-box-jp
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /etc/sing-box-jp/tls-key.pem \
  -out    /etc/sing-box-jp/tls-cert.pem \
  -days 3650 -nodes \
  -subj "/CN=<TRANSIT_SERVER_IP>" \
  -addext "subjectAltName=IP:<TRANSIT_SERVER_IP>"
sudo chmod 600 /etc/sing-box-jp/tls-key.pem

# 客户端 pinSHA256（去掉冒号，64 位十六进制）
sudo openssl x509 -noout -fingerprint -sha256 -in /etc/sing-box-jp/tls-cert.pem
```

如果沿用旧证书，客户端 HY2 的 `sni` 和 `pinSHA256` 必须与证书 SAN、指纹一致，即使中转 IP 已经换过。模板把这两项拆成 `<HY2_CERT_SAN>` 和 `<HY2_CERT_PIN_SHA256>`。

升级同一台机器时，再次运行带 `--apply` 的 `deploy.sh` 即可。脚本会先备份同名配置、单元和二进制，用新二进制做 `sing-box check`，通过后才原子替换，然后重启服务。

也可以只跑自动化测试（不在真实机器上执行 `--apply`）：

```bash
./scripts/test-deploy.sh
```

### 部署、升级和回滚边界

`deploy.sh` **会管理**：

- 官方 sing-box 二进制（默认 `/usr/local/bin/sing-box`）
- `/etc/sing-box-jp/config.json`（`0600`，目录 `0700`）
- `/etc/systemd/system/sing-box-jp.service`

`deploy.sh` **不会做**：

- 填写占位符、签发证书，或改客户端配置
- 覆盖名字不是 `sing-box-jp` 的 systemd 单元（例如发行版自带的 `sing-box.service`）
- 抢占已被无关进程占用的端口
- 默认开启 UFW 或写入 BBR（必须显式 `--harden`，或另外运行 `harden-ubuntu.sh`）

回滚范围：

- **一次失败的 `--apply`**：脚本会把本轮改过的配置、单元、二进制和本轮开始前的服务状态恢复回去，并逐项报告实际恢复结果。
- **一次成功的部署**：备份留在 `/var/backups/proxy/sing-box-jp-<时间戳>/`。若要手动退回，把备份拷回去，然后 `systemctl daemon-reload && systemctl restart sing-box-jp`。
- **`--harden` 成功之后**：UFW / sysctl 的改动不会被后续失败的 `deploy.sh` 自动撤销。`--harden` 若在服务已经启动之后失败，脚本会报错退出，但**不会**为了 UFW 失败而回滚已经可用的代理。先确认 SSH 端口，再开墙。

`harden-ubuntu.sh` 默认也是 dry-run。它会放行 SSH（读取 `sshd_config` 和当前 sshd 监听端口，至少 `22/tcp`）、`443/tcp` 和 `443/udp`，再启用 UFW，并安装 `server/90-proxy-bbr.conf`。不要先 `ufw enable` 再补 SSH 规则。若 SSH 不在 22 端口，确认脚本检测到了该端口，或传入 `--ssh-port`。

## 占位符填写表

填写时：所有 `<NAME>` 都是字符串，**端口类占位符在 JSON 里必须改成不带引号的数字**（例如 `"<HK_UPSTREAM_PORT>"` → `7367`）。客户端 YAML / 小火箭配置里的占位符按原样替换即可。

### 中转与入站

| 占位符 | 出现位置 | 如何填写 |
| --- | --- | --- |
| `<TRANSIT_SERVER_IP>` | 客户端 YAML 的 `server`、规则里的 `IP-CIDR`；小火箭 `[Rule]` 第一条 | 中转主机公网 IPv4 |
| `<VLESS_UUID_JP_DIRECT>` | 服务端 VLESS 用户 `jp-direct`；客户端「东京｜VLESS」 | `sing-box generate uuid` |
| `<VLESS_UUID_HK_PROXY>` | 用户 `hk-proxy`；「香港｜VLESS」 | 同上，另生成一个 |
| `<VLESS_UUID_US_PROXY>` | 用户 `us-proxy`；「阿灵顿｜VLESS」 | 同上 |
| `<VLESS_UUID_STARZONE>` | 用户 `starzone`；「洛杉矶｜VLESS」 | 同上 |
| `<HY2_PASSWORD_JP_DIRECT>` 等四个 | 服务端 HY2 `users[].password`；对应「东京/香港/阿灵顿/洛杉矶｜HY2」 | 每个出口一组强随机密码 |
| `<REALITY_PRIVATE_KEY>` | 服务端 `inbounds[vless].tls.reality.private_key` | `sing-box generate reality-keypair` 的私钥 |
| `<REALITY_PUBLIC_KEY>` | 客户端所有 VLESS 的 `reality-opts.public-key` | 同一对密钥的公钥 |
| `<REALITY_SHORT_ID>` | 服务端 `short_id` 数组；客户端 `reality-opts.short-id` | `sing-box generate rand --hex 8` |
| `<HY2_CERT_SAN>` | 客户端所有 HY2 的 `sni` | 证书 SAN（通常等于中转 IP；若沿用旧证则填证书里的旧 IP 或域名） |
| `<HY2_CERT_PIN_SHA256>` | 客户端所有 HY2 的 `fingerprint` | 证书 SHA-256 指纹，64 位十六进制、无冒号 |

Reality 伪装站默认是 `www.cloudflare.com`。服务端 `server_name` / `handshake.server` 与客户端 `servername` 必须一致。VLESS 用户一律使用 `flow: xtls-rprx-vision`。客户端漏填会在日志里刷 `flow mismatch`。

### WireGuard 落地

| 占位符 | 出现位置 | 如何填写 |
| --- | --- | --- |
| `<WG_IPV4>` | `endpoints[0].address`（写成 `<WG_IPV4>/32`） | 隧道内本端 IPv4，不要再加 IPv6 |
| `<WG_PRIVATE_KEY>` | 本端私钥 | WireGuard 私钥 |
| `<WG_PEER_IPV4>` | `peers[0].address` | 对端**固定 IPv4**，不要填域名 |
| `<WG_PEER_PORT>` | `peers[0].port` | 对端 UDP 端口（JSON 里改成数字） |
| `<WG_PEER_PUBLIC_KEY>` | `peers[0].public_key` | 对端公钥 |

`allowed_ips` 保持 `0.0.0.0/0`，不要加 `::/0`。

### HTTP 上游（香港 / 阿灵顿）

| 占位符 | 出现位置 | 如何填写 |
| --- | --- | --- |
| `<HK_UPSTREAM_HOST>` / `<HK_UPSTREAM_PORT>` | `outbounds` 里 `tag: exit-b` | 香港上游主机与端口（端口改成数字） |
| `<HK_UPSTREAM_USERNAME>` / `<HK_UPSTREAM_PASSWORD>` | 同上 | 上游认证 |
| `<US_UPSTREAM_HOST>` / `<US_UPSTREAM_PORT>` | `tag: exit-a` | 阿灵顿上游主机与端口 |
| `<US_UPSTREAM_USERNAME>` / `<US_UPSTREAM_PASSWORD>` | 同上 | 上游认证 |

`exit-b` 对应 `hk-proxy`，`exit-a` 对应 `us-proxy`，与路由规则一致。改标签时两边一起改。

## 客户端设置

两份模板完整保留了原来的域名白名单、Google / Gemini 补全列表、规则顺序和 DNS 策略，只去掉了服务器地址和凭证。

### 共同要点

- 所有节点 **关闭 UDP 转发**（YAML 里已是 `udp: false`；小火箭节点详情里也要关掉），以便和服务端「对已入站流量拒绝应用层 UDP」对齐。HY2 自身仍然走 UDP/443 传输。这两项都不能阻止手机或电脑在代理之外直连 STUN、QUIC 或其它 UDP。若要减少这类泄漏，需要系统级 TUN / 全局代理和主机防火墙，而不是只靠服务端的 UDP reject。
- **关闭 IPv6**（YAML `ipv6: false`，小火箭 `ipv6 = false` / `prefer-ipv6 = false`）。这只影响该客户端配置里的解析和出站偏好，不能单独证明整台设备不会经物理网卡使用 IPv6。
- **Google 组不要放 `DIRECT`**。节点故障就断开，不要回落到直连。
- Google / Gemini / YouTube 规则置顶，并且拦截这些规则集上的 UDP/QUIC（FlClash 用 `AND` + `NETWORK,UDP,REJECT`；小火箭依赖规则集与系统 UDP 设置）。
- 主 DNS 走海外 DoH（`1.1.1.1` / `9.9.9.9`）。小火箭保持 `dns-fallback-system = false`、`dns-direct-system = false`。若还想收紧防泄漏，可以把小火箭里的 `fallback-dns-server`（当前是国内 DoH）改成海外 DoH 或删掉。

### FlClash / Mihomo

1. 复制 `clients/flclash-strict.template.yaml`，填好占位符。
2. 确认 8 个节点的 `server` 都是中转 IPv4，四个出口的 UUID / HY2 密码分别对应服务端四个用户。
3. 导入后：`正常代理` 平时选海外节点；公司场景把 `正常代理` 切到末尾 `DIRECT`，只有 `Google` 组继续走代理。
4. `rule-providers` 里的 `google-extra`（29 条补全，含 AI Studio / Gemini / NotebookLM 等）和 `cn-allowlist`（1,199 条精洗国内白名单）是 inline 列表，无需额外下载；其余规则集来自 MetaCubeX / Loyalsoldier 的公开仓库，通过 `Google` 组拉取，避免下载规则时走被污染的 DNS。

### Shadowrocket

小火箭的 `.conf` **不含节点凭证**。节点在 App 首页手动添加，**备注名必须与分组里的名称完全一致**（`东京｜VLESS`、`东京｜HY2`、`香港｜VLESS`、`香港｜HY2`、`洛杉矶｜VLESS`、`洛杉矶｜HY2`、`阿灵顿｜VLESS`、`阿灵顿｜HY2`）。

添加节点时：

- VLESS：`flow = xtls-rprx-vision`，Reality 公钥 / short id 与服务端一致，SNI / 伪装站为 `www.cloudflare.com`，关闭 UDP。
- HY2：密码、SNI=`<HY2_CERT_SAN>`、证书指纹=`<HY2_CERT_PIN_SHA256>`，关闭 UDP。
- 把 `clients/shadowrocket.template.conf` 里的 `<TRANSIT_SERVER_IP>` 换成中转 IPv4 后导入（或粘贴）规则。该文件保留完整的 `[General]`、`[Proxy Group]`、`[Rule]`：Google 补全域名置顶，国内白名单直连，`GEOIP,CN,DIRECT,no-resolve`，其余进 `正常代理`。

## 上线后的验收（6 项）

在中转主机上，或经客户端混合端口，运行：

```bash
# 只做本地检查（配置 / UFW / BBR / 日志）
sudo scripts/verify-proxy.sh --skip-network

# 经客户端混合端口检查某个出口时，先切到该节点再跑：
sudo scripts/verify-proxy.sh \
  --proxy http://127.0.0.1:7890 \
  --expect-exit-ip <该出口应看到的公网 IPv4> \
  --expect-no-ipv6          # 落地（洛杉矶）出口建议加上
```

对照清单：

1. **`sing-box check -c /etc/sing-box-jp/config.json` 无报错。** 静态审计确认落地 DNS 是 tls/https 且带 `detour`，路由含 UDP 拒绝、私网拒绝、末尾默认拒绝。
2. **各出口访问 `https://api.ipify.org`，** 核对出口 IP 归属（东京=中转本机，洛杉矶=WG 落地，香港/阿灵顿=各自上游）。
3. **DNS 配置，而不是 anycast 地理。** 先看配置：落地 DNS 必须是 tls/https，且 `detour` 指向 WG 出口，并且不会回退到中转机解析器。脚本给出的 Cloudflare `colo` / `loc` 和 `edns.ip-api.com` 只是提示。`1.1.1.1` 与 `9.9.9.9` 是 anycast，GeoIP 或 PoP 位置不能证明 DNS 是在落地国家解析的。
4. **`https://ipv6.icanhazip.com` 这条探测为空或超时。** `--expect-no-ipv6` 会把「这条探测拿到 IPv6」判失败。域名没有 A 记录、或出口策略是 `ipv4_only`，都只说明这次探测本身。它不能证明客户端操作系统、其它应用或 WebRTC 不会经物理网卡使用 IPv6。
5. **不带 Cookie 访问 `https://gemini.google.com/app`，看第一跳。** 直接 `200` 最好。若 `302` 到 `google.com/sorry/index`，说明该**出口 IP** 被挂了临时人机验证页，不是配置写错。这页本身不是封号证明，也不是该 IP 被永久拉黑的证明（见下文）。
6. **`journalctl -u sing-box-jp --since "20 min ago"`。** 不应再出现业务向的 `EOF`、`connection reset`、`timeout`、`flow mismatch`。来自陌生 IP 的 `TLS handshake: REALITY: processed invalid connection` 是公网扫描，可忽略。

## 排障

### Gemini / 解锁检测超时，但浏览器还能打开

先做第 5 项检查。若第一跳是 `302 Location: .../sorry/index`，这是 Google 对该**出口 IP** 的临时质询页，不是分流或 DNS 配错的充分证据。

- 检测工具（小火箭、FlClash 解锁检测）不保存 Cookie，会被 `sorry/index` 反复踢回直到超时。
- 真实浏览器往往跳 2 到 3 次、带上豁免 Cookie 后就能打开。
- 这一页本身不能证明账号已被封，也不能证明该 IP 被永久标记。走 WireGuard 或 HTTP 上游时，Google 看到的是最终出口 IP，看不到中转主机，这次质询也不会自动套到其它出口上。
- 把 `Google` 组切到没有出现 `sorry/index` 的出口，通常就能让检测通过。这类质询往往是临时的，过一段时间可能会消失，但不保证。

### `flow mismatch`

VLESS 客户端没有填 `xtls-rprx-vision`，或填了与服务端不同的 flow。所有 VLESS 用户和客户端都必须一致。

### 日志里刷 `REALITY: processed invalid connection`

公网扫描器在打 TCP 443，Reality 正常丢弃无效握手。只要源 IP 不是你自己的宽带或蜂窝 IP，就可以忽略。

### WireGuard 明文 UDP DNS 泄漏

不要在落地隧道里使用明文 UDP DNS（例如直接把 `1.1.1.1:53` 当 nameserver）。这类查询可能漏到中转机本地解析器。落地 DNS 必须是 **tls/https，并且 `detour` 指向 WG 出口**；超时只许落到另一条同样走隧道的加密 DNS，不许回退到中转 `direct-doh`。`scripts/verify-proxy.sh` 的静态审计会检查配置是否如此，这比看 anycast 地理位置更可靠。

### 其它常见问题

- **`ip_is_private` 误伤**：规则会拒绝 RFC1918、链路本地和云元数据地址（含 `169.254.169.254`）。不要把私网服务暴露给入站用户。
- **规则写漏走到日本**：末尾那条对 `jp-vless` / `jp-hy2` 的 `reject` 就是兜底。新增用户或出口时，补上 `auth_user` 分流，不要删掉最后一条。
- **HY2 证书校验失败**：客户端 `sni` 与证书 SAN 不一致，或 `fingerprint` 不是当前证书的 SHA-256。换证书后两处都要更新。
- **SSH 被墙**：只在确认 `22/tcp`（或实际 SSH 端口）已放行后才启用 UFW。被锁在门外只能走云厂商的 VNC 或串口控制台补规则。

## 仓库内容

```
proxy-deploy-kit/
├── README.md
├── .gitignore
├── server/
│   ├── config.template.json          # 脱敏后的 sing-box 1.14+ 配置
│   ├── sing-box-jp.service.template  # systemd 单元
│   └── 90-proxy-bbr.conf             # BBR + fq
├── scripts/
│   ├── init-config.sh                # 复制模板到本地待填路径，不覆盖已有文件
│   ├── deploy.sh                     # 官方发行版安装与配置发布，默认 dry-run
│   ├── harden-ubuntu.sh              # 可选：UFW / BBR / 0600，默认 dry-run
│   ├── verify-proxy.sh               # 上线验收
│   └── test-deploy.sh                # deploy.sh 的本地冒烟测试（不在真实主机 --apply）
└── clients/
    ├── flclash-strict.template.yaml  # FlClash / Mihomo 严格分流
    └── shadowrocket.template.conf    # Shadowrocket 严格分流
```

本仓库只适合作为你自己的部署起点。推送到公开 Git 托管之前，再扫一遍是否误放入已填写的 `config.json` 或密钥文件。
