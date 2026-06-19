# nezhafix

哪吒监控面板/探针漏洞自查与升级脚本。

## 一键运行

只自查，不升级：

```bash
curl -fsSL https://raw.githubusercontent.com/njzhx/nezhafix/main/nezha_audit_fix.sh | sudo bash
```

自查后升级面板和探针：

```bash
curl -fsSL https://raw.githubusercontent.com/njzhx/nezhafix/main/nezha_audit_fix.sh | sudo bash -s -- --upgrade-all
```

国内机器可加 `--cn` 优先使用官方国内镜像：

```bash
curl -fsSL https://raw.githubusercontent.com/njzhx/nezhafix/main/nezha_audit_fix.sh | sudo bash -s -- --upgrade-all --cn
```

如果旧版 `0.x` 探针升级时报缺少连接参数，请先到新版面板的“服务器”页面复制探针安装命令，或显式提供新版连接参数：

```bash
curl -fsSL https://raw.githubusercontent.com/njzhx/nezhafix/main/nezha_audit_fix.sh | \
sudo env NZ_SERVER=你的面板通信地址:端口 NZ_CLIENT_SECRET=连接密钥 NZ_TLS=false bash -s -- --upgrade-agent
```

说明：旧版 `0.x` 探针常用 `-s/-p` 参数式 systemd 服务，新版 `2.x` 探针使用 `config.yml` 和用户连接密钥。脚本不会在缺少新版连接密钥时强行迁移，以免探针重复注册或断连。

## 功能

- 检查 Dashboard 是否低于已知安全修复版本 `2.0.13`。
- 通过本机回环地址验证 `CVE-2026-53519 / GHSA-5c25-7vpj-9mqh` 路径穿越漏洞是否仍可读取 `data/config.yaml` 或 `data/sqlite.db`。
- 扫描常见 Web 日志中是否出现 `dashboard../data/config.yaml`、`dashboard%2e%2e` 等攻击痕迹。
- 检查可疑进程、可疑定时任务、systemd 服务、Dashboard 数据库中可能的异常命令。
- 检查 Agent 配置中是否允许远程命令执行，并提示被接管后的风险。
- 可选择调用官方脚本升级 Dashboard 和 Agent 到最新版本。

## 参数

```text
--check-only           仅自查，默认行为
--upgrade-dashboard    自查后升级 Dashboard
--upgrade-agent        自查后升级 Agent
--upgrade-all          自查后升级 Dashboard 和 Agent
--cn                   使用官方国内镜像/源
--no-poc               跳过本机漏洞 PoC 请求
--help                 显示帮助
```

## 重要提示

如果脚本报告曾经或当前可能暴露过 `config.yaml` 或 `sqlite.db`，升级后仍建议立即处理：

1. 修改 Dashboard 管理员密码。
2. 轮换 `jwt_secret_key`、OAuth、通知、DDNS、API Token 等所有可能泄漏的密钥。
3. 重新生成 Agent 连接密钥，并逐台更新探针配置。
4. 检查面板里的任务、通知、服务器、用户、API Token 是否被新增或篡改。

脚本只能做高置信排查和辅助升级，不能证明机器一定没有被入侵。发现高危告警时，建议先备份证据，再考虑重装系统或从可信快照恢复。
