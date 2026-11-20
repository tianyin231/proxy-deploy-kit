# proxy-deploy-kit

面向 sing-box 1.14+ 的通用中转部署工具。用一份声明式拓扑生成服务端配置、systemd 单元、FlClash / Shadowrocket 客户端和分享链接。出口数量、名称和连接方式由你决定，仓库不绑定某一套私人环境。

## 交给 Agent 时复制这一句

把本仓库发给任意能读取项目文件的 Agent，然后发送：

> 请阅读本仓库的 AGENTS.md，先问我必要的需求，再帮我生成一套通用的 sing-box 中转与出口配置。不要假设出口数量、名称或连接方式，也不要在聊天里向我索要密码或密钥。

Agent 应按 [AGENTS.md](./AGENTS.md) 先询问，再给出脱敏方案，经你确认后才生成文件。真部署如果会改防火墙或现存服务，还需要你对那一次操作单独确认。

## 自己在命令行使用

1. 复制一份示例并改成自己的拓扑。示例里只有文档地址和占位符，没有真实密钥。

```bash
cp topology/topology.minimal.yaml topology.local.yaml
chmod 600 topology.local.yaml
```

或运行交互向导（向导不会要求你在终端粘贴密码）：

```bash
python3 scripts/render-topology.py --interactive --out-topology topology.local.yaml
```

2. 在本地填好占位符，或让渲染器生成入口密钥和自签证书：

```bash
python3 scripts/render-topology.py --topology topology.local.yaml --out-dir build/<instance> --generate-secrets
```

3. 先在隔离环境跑测试，再在服务器上演练：

```bash
./scripts/test-deploy.sh
./scripts/deploy.sh --instance <instance> --config build/<instance>/server/config.json
```

确认 dry-run 输出后，再用 `sudo ./scripts/deploy.sh ... --apply` 安装。默认会校验官方 GitHub Release 的 SHA-256。没有 digest 则拒绝安装。

本地完整测试是 `./scripts/test-deploy.sh`。若要在 GitHub Actions 里跑同一套检查，可以把 `contrib/github-workflows/ci.yml` 复制为 `.github/workflows/ci.yml`。

## 分流方案

- `default`（默认）：通用配置。局域网直连，不含中国国内白名单。
- `cn-strict`：在需要国内域名和 IP 直连时使用。包含旧模板中的 29 条 Google 补全和 1199 条国内名单。不是所有用户的默认项。

在拓扑的 `clients.rule_profile` 里选择。旧的完整客户端模板留在 `legacy/`，可用 `python3 scripts/render-topology.py --migrate-legacy-rules` 合并自定义域名。

## 安全边界

- `topology.local.yaml`、`build/`、证书和私钥已被 `.gitignore` 排除，不要强制加入版本库。
- 不要在公开文档、日志或提交里写入真实 IP、密钥、UUID 或订阅 token。
- 离线测试通过，不等于生产已经验证完毕。真上线后仍需检查服务状态、端口、SSH 和出口连通性。细节见 [AGENTS.md](./AGENTS.md)。

## 仓库结构

```text
AGENTS.md                 Agent 主入口（询问、生成、部署规则）
CLAUDE.md                 指向 AGENTS.md
README.md                 本说明
legacy/                   旧客户端模板，仅供迁移对照
rules/profiles/default/   通用分流
rules/profiles/cn-strict/ 国内直连与 Google 补全
rules/optional/           可选的 AI 服务列表
topology/                 示例与 JSON Schema
server/                   systemd 单元模板和内核参数
scripts/                  渲染、部署、加固、验收和测试
```
