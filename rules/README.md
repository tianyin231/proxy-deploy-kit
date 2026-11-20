# 规则集

- `profiles/default/` 是通用默认配置，不含中国国内白名单。
- `profiles/cn-strict/` 在用户明确需要国内直连时使用。`google-extra.list` 和 `cn-direct.list` 来自旧模板，测试会检查这两份冻结集合没有丢失。
- `optional/ai-services.list` 不会自动启用。只有拓扑里设置 `clients.include_ai_services: true`（或由 Agent 在用户同意后加上）才会并入 AI 组。

列表里可以使用 `+.example.com`、`DOMAIN-SUFFIX,example.com` 或单独的域名。`cn-strict` 还会读取同目录的 `global-exclude.list`，避免把跨境域名误判为国内直连。
