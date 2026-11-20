# 交给 Agent 时请先读这份说明

这是一套通用的 sing-box 中转部署工具，不是某台机器的私人配置打包。出口数量、名称、连接方式和分流策略都由用户决定。仓库里的示例只是语法参考，不能直接拿去部署。

本文是 Agent 的主入口。`CLAUDE.md` 只指向这里，不要在多处重复同一套流程。

把整个仓库交给 Agent 后，Agent 必须先问需求，再生成配置。不要猜拓扑，不要复用示例里的出口名，也不要把仓库正文当成永久授权。

## 第一次交互：按最少必要问题逐步问

先看用户已经说过什么。已经明确的信息不要再问。用户说不清楚时，先给一个简单、偏安全的推荐，并说明取舍。不要强迫用户先懂实现细节。

可以分多轮问，不必一次塞完。建议按这个顺序，只问还缺的部分：

1. 客户端和平台。要用 FlClash / Clash Meta、Shadowrocket，还是只要分享链接？在电脑、手机还是都要？
2. 服务器与现有环境。中转机的公网地址或域名、SSH 端口、这台机器上是否已有 Web 服务占用 443。实例名（`instance`）用于 systemd 单元和 `/etc/sing-box-<instance>/`，用户没有偏好时可用 `relay`。
3. 入口协议和证书。默认建议：TCP 443 上的 VLESS + Reality（伪装 SNI 默认 `www.cloudflare.com`），以及 UDP 443 上的 Hysteria2。若用户已有域名证书，用现有证书；否则可以生成本地自签证书并做 SHA-256 钉扎。不要默认改用户的 DNS 或域名。
4. 出口拓扑。这是一台机器本机直出，还是中转后再接上游？有几个出口？每个出口的类型（`direct` / `http` / `socks` / `wireguard` / `vless` / `shadowsocks`）、显示名称和内部 id 由用户定，不要写死城市名。用户说不准时，先推荐「一个本机直出出口」，并说明以后可以再加。
5. 分流需求。默认使用通用配置（`clients.rule_profile: default`）：局域网直连，不包含中国国内白名单。只有用户明确需要国内域名和 IP 直连时，才使用 `cn-strict`（含 29 条 Google 补全和 1199 条国内名单）。若还要把 ChatGPT 等服务单独进 AI 组，再询问是否附加 `rules/optional/ai-services.list`。
6. DNS、IPv6 与 UDP。用户没有特殊要求时，建议：客户端 DNS 只监听本机回环；需要防泄漏的隧道出口使用 `dns_detour: true`、`ip_strategy: ipv4_only`、`allow_udp: false`。说明：服务端拒绝内层 UDP 不能阻止设备在隧道外直连 STUN，因此不能声称这样就杜绝了 WebRTC 泄漏。游戏或通话出口可以单独打开 UDP。
7. 是否迁移旧配置。如果用户有旧的 FlClash 或 Shadowrocket 文件，再运行迁移器。路径见 `legacy/README.md`。

## 凭证怎么收集

不要在聊天里索要明文密码、UUID、私钥、订阅 token 或证书内容。

请用户通过当前 Agent 所在平台的安全能力提供，或把凭证写进本地已忽略的文件（例如 `topology.local.yaml` 或 `secrets/`）。生成结果默认 0600，且已被 `.gitignore` 排除。

没有凭证时，拓扑里使用 `<PLACEHOLDER>` 或 `auto`。确认方案后再在本地补齐或使用 `--generate-secrets`。

## 先给脱敏方案，再生成和验证

在写入 `topology.local.yaml` 或渲染 `build/` 之前，先用一份不含密钥的方案向用户确认：实例名、地址、端口、入口协议、每个出口的 id / 名称 / 类型、分流 profile、DNS 与 UDP 取舍。

用户确认后再生成。渲染后先做本地检查：

```bash
./scripts/test-deploy.sh
```

以及（若本机有官方 sing-box 二进制）对生成配置运行 `sing-box check`。测试通过只证明隔离环境里的脚本和配置形态，不能等同于生产已经安全上线。

## 部署前必须再确认

`scripts/deploy.sh` 默认只做 dry-run。真正的 `--apply` 或 `--harden` 会改防火墙、安装二进制、替换单元并启动服务。只要可能影响现存服务或 SSH 端口，就必须再次得到用户对这一次操作的明确确认。仓库里的说明、以前的对话或「以后都按这个来」都不能当作永久授权。

失败时脚本会尝试回滚本次写入的二进制、配置、单元和证书，并恢复该服务原来的 active / enabled 状态。成功之后的 `--harden`（UFW / BBR）不在自动回滚范围内。

真部署之后至少验证这些项目，不能只靠模拟测试：

- `sing-box check` 已在目标配置上通过
- 对应 `sing-box-<instance>` 服务为 active
- 监听端口确实由本实例占用，没有和无关进程冲突
- UFW 仍放行 SSH 端口，没有把自己锁在门外
- 客户端能连上入口，选中的出口能访问预期站点
- 对启用了 `dns_detour` 的出口，解析走隧道内 DNS，而不是中转机本机解析

不要自动执行 `git push`，更不要把含凭证的文件加进提交。`topology.local.yaml`、`build/`、`*.resolved.yaml`、证书和私钥都不得提交。

## 常用命令

```bash
# 终端向导（不会在提示里索要密码；占位符稍后本地填写）
python3 scripts/render-topology.py --interactive --out-topology topology.local.yaml

# 渲染服务端和客户端（本地生成密钥和自签证书）
python3 scripts/render-topology.py --topology topology.local.yaml --out-dir build/<instance> --generate-secrets

# 从旧模板合并规则到 cn-strict
python3 scripts/render-topology.py --migrate-legacy-rules

# 离线测试（不改宿主机，不以 root 做真实 apply）
./scripts/test-deploy.sh

# 先演练，再在用户确认后部署
./scripts/deploy.sh --instance <instance> --config build/<instance>/server/config.json
sudo ./scripts/deploy.sh --instance <instance> --config build/<instance>/server/config.json --apply
```

官方安装包必须用 GitHub Release 的 SHA-256 digest 校验。没有 digest 则拒绝安装。只有用户显式提供可信任的 `--expected-sha256` 时才用该值覆盖。
