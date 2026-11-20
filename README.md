# 单端口多出口中转代理部署模板

这是一套可复用的 **sing-box 1.14+** 中转部署与客户端分流模板，从一台已硬化的东京中转（单端口 `443` TCP/UDP、多出口身份、WireGuard 落地、HTTP 上游）提炼而来。仓库里只有占位符，不含任何真实 IP、UUID、密码或密钥。

填写后的配置请放在 `server/config.json`、`clients/flclash-strict.yaml`、`clients/shadowrocket.conf`（均已加入 `.gitignore`），不要提交到 git。

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

- **一条 443 端口、两套入站复用**：VLESS + Reality（TCP）与 Hysteria2（UDP）。用 `users[].name` 区分出口身份，客户端选不同节点 = 选不同用户。
- **落地出口只走 IPv4**：WireGuard 不配 IPv6 地址和 `::/0`，对端写死 IPv4，`mtu: 1280`，`persistent_keepalive_interval: 15`。
- **DNS 防泄漏**：落地出口的解析强制走隧道内加密 DNS（Cloudflare DoT `1.1.1.1:853` 主用，Quad9 DoH `9.9.9.9` 备用），失败不回退到中转机本地 DNS。中转直出同样用 DoH 主备。香港 / 阿灵顿是 HTTP 上游，服务端不做本地 `resolve`，域名交给上游在当地解析。
- **路由顺序不能乱**：先拒应用层 UDP → 按用户 resolve（落地加 `ipv4_only`）→ 拒 WG 反向入站 → 拒私网 / 云元数据 → 按 `auth_user` 分流 → **末尾默认拒绝**，防止规则写漏后误走日本直连。
- **客户端配合**：关闭 UDP 转发和 IPv6；Google / Gemini / YouTube 规则置顶，`Google` 组不放 `DIRECT`，并拦截 Google 相关 UDP/QUIC。

> 香港和阿灵顿这两条上游本身是明文 HTTP 代理（你到中转、以及 HTTPS 内容仍然加密）。这是上游供应商协议决定的，不换加密上游改不了。

## 部署步骤（Ubuntu / Debian）

以下以默认路径 `/etc/sing-box-jp`、`/usr/local/bin/sing-box`、systemd 单元 `sing-box-jp` 为例。先不要开防火墙，等 SSH 放行规则写好再 `ufw enable`。

### 1. 安装 sing-box 1.14+

从 [sing-box Releases](https://github.com/SagerNet/sing-box/releases) 下载官方二进制，校验校验和后安装到 `/usr/local/bin/sing-box`。模板使用 1.14+ 的新版 DNS `evaluate` / `respond` 语法，以及 `endpoints` 里的 WireGuard，旧版本无法直接使用。

```bash
sing-box version
```

### 2. 目录、备份与密钥

```bash
sudo mkdir -p /etc/sing-box-jp /var/backups/proxy
```

生成 Reality 密钥对、short id、各出口 UUID：

```bash
sing-box generate reality-keypair
sing-box generate rand --hex 8          # short id，16 个十六进制字符
sing-box generate uuid                  # 每个出口用户各生成一次
sing-box generate rand --hex 16         # 可用作 HY2 密码
```

为 Hysteria2 签发自签证书。SAN 建议写成**当前中转 IPv4**（或你要在客户端填的域名）：

```bash
sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /etc/sing-box-jp/tls-key.pem \
  -out    /etc/sing-box-jp/tls-cert.pem \
  -days 3650 -nodes \
  -subj "/CN=<TRANSIT_SERVER_IP>" \
  -addext "subjectAltName=IP:<TRANSIT_SERVER_IP>"

# 客户端 pinSHA256（去掉冒号，大小写均可，模板里按 64 位十六进制填写）
sudo openssl x509 -noout -fingerprint -sha256 -in /etc/sing-box-jp/tls-cert.pem
```

如果沿用一张旧证书，客户端 HY2 的 `sni` / `pinSHA256` 必须与证书 SAN 和指纹一致，即便中转 IP 已经换过（模板里把这两项拆成 `<HY2_CERT_SAN>` 和 `<HY2_CERT_PIN_SHA256>`）。

把 `server/config.template.json` 复制为 `/etc/sing-box-jp/config.json`，按下面的占位符表填好，再校验：

```bash
sudo cp server/config.template.json /etc/sing-box-jp/config.json
sudo chmod 600 /etc/sing-box-jp/config.json /etc/sing-box-jp/tls-key.pem
sudo chmod 644 /etc/sing-box-jp/tls-cert.pem
sudo sing-box check -c /etc/sing-box-jp/config.json
```

每次改配置前先打包备份：

```bash
sudo tar -czf /var/backups/proxy/sing-box-jp-$(date +%Y%m%d-%H%M%S).tar.gz \
  -C /etc sing-box-jp
```

### 3. systemd

```bash
sudo cp server/sing-box-jp.service.template /etc/systemd/system/sing-box-jp.service
sudo systemctl daemon-reload
sudo systemctl enable --now sing-box-jp
sudo systemctl status sing-box-jp --no-pager
```

### 4. BBR、UFW、权限

脚本默认是 **dry-run**，只打印将要执行的命令；确认无误后再加 `--apply`（需要 root）：

```bash
sudo scripts/harden-ubuntu.sh            # 预览
sudo scripts/harden-ubuntu.sh --apply    # 真正写入
```

它会：

- 把 `server/90-proxy-bbr.conf` 安装到 `/etc/sysctl.d/90-proxy-bbr.conf` 并 `sysctl --system`（`fq` + `bbr`）
- UFW：默认拒绝入站、允许出站；放行 SSH（自动读取 `sshd_config` / 当前 sshd 监听端口，至少 `22/tcp`）、`443/tcp`、`443/udp`，然后启用防火墙
- 将配置和密钥 `chmod 600`，并在 `/var/backups/proxy` 留一份拷贝

不要先 `ufw enable` 再放行 SSH。若 SSH 不在 22 端口，确认脚本检测到了该端口，或显式传入 `--ssh-port`。

## 占位符填写表

填写时：所有 `<NAME>` 都是字符串，**端口类占位符在 JSON 里必须改成不带引号的数字**（例如 `"<HK_UPSTREAM_PORT>"` → `7367`）。客户端 YAML / 小火箭配置里的占位符保持原样替换即可。

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
| `<HY2_CERT_SAN>` | 客户端所有 HY2 的 `sni` | 证书 SAN（通常等于中转 IP；若沿用旧证则填证书里的旧 IP/域名） |
| `<HY2_CERT_PIN_SHA256>` | 客户端所有 HY2 的 `fingerprint` | 证书 SHA-256 指纹，64 位十六进制、无冒号 |

Reality 伪装站默认是 `www.cloudflare.com`，服务端 `server_name` / `handshake.server` 与客户端 `servername` 必须一致。VLESS 用户一律 `flow: xtls-rprx-vision`，客户端漏填会在日志里刷 `flow mismatch`。

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

`exit-b` 对应 `hk-proxy`，`exit-a` 对应 `us-proxy`，与路由规则一致，改标签时两边一起改。

## 客户端设置

两份模板完整保留了原来的域名白名单、Google / Gemini 补全列表、规则顺序和 DNS 策略，只去掉了服务器地址和凭证。

### 共同要点

- 所有节点 **关闭 UDP 转发**（YAML 里已是 `udp: false`；小火箭节点详情里也要关掉），与服务端「应用层 UDP 直接 reject」对齐。HY2 自身走 UDP/443 传输，不受这条影响。
- **关闭 IPv6**（YAML `ipv6: false`，小火箭 `ipv6 = false` / `prefer-ipv6 = false`）。
- **Google 组不要放 `DIRECT`**，节点故障就断开，不要回落到直连。
- Google / Gemini / YouTube 规则置顶，并且拦截这些规则集上的 UDP/QUIC（FlClash 用 `AND` + `NETWORK,UDP,REJECT`；小火箭依赖规则集与系统 UDP 设置）。
- 主 DNS 走海外 DoH（`1.1.1.1` / `9.9.9.9`）。小火箭保持 `dns-fallback-system = false`、`dns-direct-system = false`。若追求更极端的防泄漏，可以把小火箭里的 `fallback-dns-server`（当前是国内 DoH）改成海外 DoH 或删掉。

### FlClash / Mihomo

1. 复制 `clients/flclash-strict.template.yaml`，填好占位符。
2. 确认 8 个节点的 `server` 都是 `<TRANSIT_SERVER_IP>`，四个出口的 UUID / HY2 密码分别对应服务端四个用户。
3. 导入后：`正常代理` 平时选海外节点；公司场景把 `正常代理` 切到末尾 `DIRECT`，只有 `Google` 组继续走代理。
4. `rule-providers` 里的 `google-extra`（29 条补全，含 AI Studio / Gemini / NotebookLM 等）和 `cn-allowlist`（1,199 条精洗国内白名单）是 inline 列表，无需额外下载；其余规则集来自 MetaCubeX / Loyalsoldier 的公开仓库，通过 `Google` 组拉取，避免下载规则时走被污染的 DNS。

### Shadowrocket

小火箭的 `.conf` **不含节点凭证**：节点在 App 首页手动添加，**备注名必须与分组里的名称完全一致**（`东京｜VLESS`、`东京｜HY2`、`香港｜VLESS`、`香港｜HY2`、`洛杉矶｜VLESS`、`洛杉矶｜HY2`、`阿灵顿｜VLESS`、`阿灵顿｜HY2`）。

添加节点时：

- VLESS：`flow = xtls-rprx-vision`，Reality 公钥 / short id 与服务端一致，SNI / 伪装站为 `www.cloudflare.com`，关闭 UDP。
- HY2：密码、SNI=`<HY2_CERT_SAN>`、证书指纹=`<HY2_CERT_PIN_SHA256>`，关闭 UDP。
- 把 `clients/shadowrocket.template.conf` 里的 `<TRANSIT_SERVER_IP>` 换成中转 IPv4 后导入（或粘贴）规则。该文件保留完整的 `[General]`、`[Proxy Group]`、`[Rule]`：Google 补全域名置顶，国内白名单直连，`GEOIP,CN,DIRECT,no-resolve`，其余进 `正常代理`。

## 上线后 5 分钟验收（6 项）

在中转主机上（或本机经客户端混合端口）运行：

```bash
# 只做本地检查（配置 / UFW / BBR / 日志）
sudo scripts/verify-proxy.sh --skip-network

# 经客户端混合端口检查四个出口时，分别切换节点后再跑：
sudo scripts/verify-proxy.sh \
  --proxy http://127.0.0.1:7890 \
  --expect-exit-ip <该出口应看到的公网 IPv4> \
  --expect-no-ipv6          # 落地（洛杉矶）出口建议加上
```

对照清单：

1. **`sing-box check -c /etc/sing-box-jp/config.json`** 无报错；静态审计确认落地 DNS 是 tls/https 且带 `detour`，路由含 UDP 拒绝、私网拒绝、末尾默认拒绝。
2. **各出口访问 `https://api.ipify.org`**，核对出口 IP 归属（东京=中转本机，洛杉矶=WG 落地，香港/阿灵顿=各自上游）。
3. **DNS 归属**：落地出口的解析器地理位置应是落地侧，而不是中转机所在地区。脚本会给出 Cloudflare trace 与 `edns.ip-api.com` 提示，请人工确认。
4. **`https://ipv6.icanhazip.com`**：落地出口应为空或超时（`--expect-no-ipv6` 会把「拿到 IPv6」判失败）。
5. **不带 Cookie 访问 `https://gemini.google.com/app`**：看**第一跳**。直接 `200` 最好；若 `302` 到 `google.com/sorry/index`，说明该出口 IP 被 Google 挂了临时风控，不是配置错误（见下文）。
6. **`journalctl -u sing-box-jp --since "20 min ago"`**：不应再出现业务向的 `EOF`、`connection reset`、`timeout`、`flow mismatch`。来自陌生 IP 的 `TLS handshake: REALITY: processed invalid connection` 是公网扫描，可忽略。

## 排障

### Gemini / 解锁检测超时，但浏览器还能打开

先做第 5 项检查。若第一跳是 `302 Location: .../sorry/index`，这是 **Google 对该出口 IP 的临时质询**，不是分流或 DNS 配错。

- 检测工具（小火箭、FlClash 解锁检测）不存 Cookie，会被 `sorry/index` 反复踢回直到超时。
- 真实浏览器往往跳 2–3 次、带上 `GOOGLE_ABUSE_EXEMPTION` 就能 `200`。
- Google 只能看到最终出口 IP，**不会标记中转主机，也不会连累其它出口**。把 `Google` 组切到未触发风控的出口（例如阿灵顿或东京）即可秒过检测；落地 IP 过几天风控降了通常会自己恢复。

### `flow mismatch`

VLESS 客户端没有填 `xtls-rprx-vision`，或填了与服务端不同的 flow。所有 VLESS 用户和客户端都必须一致。

### 日志里刷 `REALITY: processed invalid connection`

公网扫描器在打 TCP 443，Reality 正常丢弃无效握手。只要源 IP 不是你自己的宽带/蜂窝 IP，就可以忽略。

### WireGuard 明文 UDP DNS 泄漏

不要在落地隧道里使用明文 UDP DNS（例如直接把 `1.1.1.1:53` 当 nameserver）。实测这类查询会漏到中转机本地解析器。落地 DNS 必须是 **tls/https，并且 `detour` 指向 WG 出口**；超时只许落到另一条同样走隧道的加密 DNS，不许回退到中转 `direct-doh`。`scripts/verify-proxy.sh` 的静态审计会检查这一点。

### 其它常见问题

- **`ip_is_private` 误伤**：规则会拒绝 RFC1918、链路本地和云元数据地址（含 `169.254.169.254`）。不要把私网服务暴露给入站用户。
- **规则写漏走到日本**：末尾那条对 `jp-vless` / `jp-hy2` 的 `reject` 就是兜底。新增用户或出口时，记得补 `auth_user` 分流，不要删掉最后一条。
- **HY2 证书校验失败**：客户端 `sni` 与证书 SAN 不一致，或 `fingerprint` 不是当前证书的 SHA-256。换证书后两处都要更新。
- **SSH 被墙**：只在确认 `22/tcp`（或实际 SSH 端口）已放行后才启用 UFW。被锁在门外只能走云厂商 VNC / 串口控制台补规则。

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
│   ├── harden-ubuntu.sh              # UFW / BBR / 0600，默认 dry-run
│   └── verify-proxy.sh               # 上线 6 项验收
└── clients/
    ├── flclash-strict.template.yaml  # FlClash / Mihomo 严格分流
    └── shadowrocket.template.conf    # Shadowrocket 严格分流
```

本仓库只适合作为你自己的部署起点。推送到公开 Git 托管之前，请再扫一遍是否误放入已填写的 `config.json` 或密钥文件。
