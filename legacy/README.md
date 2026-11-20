# 旧客户端模板（仅供迁移参考）

`flclash-strict.template.yaml` 和 `shadowrocket.template.conf` 是早期套件里的完整客户端模板。它们保留了 29 条 Google 补全域名和 1199 条国内直连白名单，方便对照和迁移。

不要把这两份文件当作当前部署模板。新的配置由 `scripts/render-topology.py` 根据拓扑和 `rules/profiles/` 生成。

如果你在旧模板里加过自定义域名，可以在仓库根目录运行：

```bash
python3 scripts/render-topology.py --migrate-legacy-rules
```

迁移器会读取 Clash 的 inline `payload`（包括 `+.domain`）以及 Shadowrocket 的 `DOMAIN*` / `DIRECT` 行，并合并进 `rules/profiles/cn-strict/`。已有条目不会被删除。
