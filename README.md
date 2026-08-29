# 洛克王国世界 · 远行商人提醒

自动查询「远行商人」本轮商品，命中关注商品就推送到手机；也支持随时手动查询。

## 方案总览

```
洛克魔法书 API  ──►  roco.ps1(拉取+匹配)  ──►  虾推啥(微信/Bark)  ──►  手机提醒
   (数据源)                (本地 PowerShell)            (推送)
```

- 数据源：熵增团队维护的接口 `https://wegame.shallow.ink/api/v1/games/rocom/merchant/info`，需要 `X-API-Key` 鉴权。
- 推送：虾推啥 `https://wx.xtuis.cn/<token>.send`（微信）或 `https://bark.xtuis.cn/<token>.send`（Bark）。
- 刷新规律：每天 `08:00 / 12:00 / 16:00 / 20:00` 四个固定时段刷新，每轮 4 小时，08:00-24:00 营业。

## 前置准备（两个都要填）

### 1. 虾推啥 token（通知到手机）

1. 微信扫二维码关注「虾推啥」公众号，关注后会自动收到一个 token。
2. 把这个 token 填到 `config.json` 的 `notify.token`。

> 微信与 Bark 二选一：`notify.provider` 填 `wx`（默认，微信）或 `bark`（需要 iPhone 装 Bark）。

### 2. 洛克魔法书 API Key（拿商品数据）

1. 打开 [洛克魔法书](https://rocom.shallow.ink/) → 登录页 `/auth/login`（扫码绑定 WeGame/微信账号，这一步需要你本人扫码）。
2. 登录后进入 开发者 → API 密钥（`/developer/api-keys`），创建一个 API Key。
3. 把这个 key 填到 `config.json` 的 `api.apiKey`。

> key 属于凭证，不要提交到公开仓库或发到公开群聊。项目里的 `config.json` 是空占位。

## 手动查询

```powershell
.\roco.ps1 query
```

会显示当前北京时间、轮次（第几轮）、剩余商品及价格/限购。营业时间内运行才会列出商品。

## 定时提醒

商品命中 `config.json` 的 `watchlist`（默认 `国王球`、`棱镜球`、`炫彩精灵蛋`）时推送，且同一轮次只推一次（状态记录在 `.rocom_state.json`）。

### 方式 A（推荐）：常驻循环

每 5 分钟检查一次，能自动处理「08:00 刚刷新、数据源还没更新」的延迟，等数据到了再推。

```powershell
.\roco.ps1 daemon
```

让它开机自启：把上面命令放进「启动」文件夹，或注册一个开机任务。间隔可用 `-IntervalMinutes 10` 调大。

### 方式 B：Windows 任务计划程序

每天在四个刷新点各跑一次 `check`。注意：刷新点数据源可能延迟，若想更稳，可把触发时间设成 `08:03` 等，或额外再挂一个稍晚的触发。

```powershell
schtasks /Create /TN "RocoMerchant-1" /SC DAILY /ST 08:03 `
  /TR "pwsh -NoProfile -ExecutionPolicy Bypass -File D:\codex\project\rocoremind\roco.ps1 check" /F
```

其余三个触发点（12:03、16:03、20:03）照此再建。

## 云端推送（可选）

本地的「常驻循环 / 任务计划」都要求电脑在四个刷新点开机在线。如果想省掉一台常开电脑，可以把「定时检查」搬到 GitHub Actions，由云端替你跑，命中照样推到手机。

### 需要做的

1. 在 GitHub 建一个仓库（公开/私有均可），把代码推上去。
2. 在仓库 Settings → Secrets and variables → Actions 里加两个 Secret：
   - `ROCO_API_KEY`：洛克魔法书 API Key。
   - `ROCO_PUSH_TOKEN`：虾推啥 token。
3. 提交已自带的 `.github/workflows/roco-merchant.yml`，之后每天会在北京时间 `08:05 / 12:05 / 16:05 / 20:05` 各检查一次，命中关注商品就推送。需要手动触发时，到仓库 Actions 页跑 `workflow_dispatch`。

### 说明

- `config.json` 已加入 `.gitignore`，即使本地填了密钥也不会跟代码一起上传；密钥只存在 GitHub Secret 里，不会进仓库。
- 关注商品默认是 `国王球、棱镜球、炫彩精灵蛋`；想改可在仓库 Settings → Variables 里加一个 `WATCHLIST`（逗号分隔）覆盖，例如 `国王球,棱镜球`。
- 云端每次运行都在全新环境里，`.rocom_state.json` 不会跨运行保留，所以「同一轮只推一次」只对单次计划触发生效；**别在同一轮里重复手动触发**，否则会重复推送。
- 私有仓库每月约 2000 分钟免费额度，本方案一天 4 次、每次约 1 分钟，远在限额内。

## 其它命令

```powershell
.\roco.ps1 test    # 发一条测试推送，确认手机能收到
.\roco.ps1 check   # 立即检查一次并推送（供任务计划/手动触发）
```

## 注意事项

- 虾推啥免费额度：每天最多 300 条、每分钟 30 条；本方案一天最多 4 条，远在限额内。
- 虾推啥返回 `200` 只是「已入队」，真实是否送达可用返回的 `msg_id` 查询：`https://msgstatus.xtuis.cn/status/<msg_id>`。
- 若推送日每天都要开机，建议首选方式 A 的 daemon；只在特定时段开机则用方式 B。
- 如果不想自己维护，也可直接用社区现成的 Koishi 插件 `koishi-plugin-rocom`，它内置了「远行商人订阅提醒」，但需要先把消息再转发到虾推啥。

## 现有文件

- `config.json`：配置 API Key、虾推啥 token、关注商品、刷新时间。
- `roco.ps1`：主脚本（query / check / daemon / test）。
- `.rocom_state.json`：运行后自动生成，记录每轮是否已提醒。
- `.github/workflows/roco-merchant.yml`：云端定时检查（GitHub Actions）。
- `.gitignore`：排除含密钥的 `config.json` 与状态文件。
