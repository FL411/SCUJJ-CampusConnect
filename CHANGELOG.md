# Changelog

## v1.0.2 — 2026-11-02

- WiFi 切换后立即尝试登录，不再先等旧 token 的 keepalive 超时。
- 门户 `InterFace.do` 请求改用 `HttpWebRequest`：8 秒连接/读写超时、绕过系统代理，避免切换瞬间卡住。
- 在线探测超时从 6 秒降到 4 秒，失败更快进入重试。
- 修复“切换 WiFi 后需要手动登录”的主要路径。

## v1.0.1 — 2026-11-02

- 过滤 `正在识别...` / `正在识别` / `Identifying...` / `Unknown` 等瞬态 SSID，不再写入 `wifi-cache.json`。
- GUI 状态栏同样忽略瞬态 SSID，显示为未连接。
- 清理已有的 `正在识别...` 无效缓存项。

## v1.0.0 — 2026-10-30

- 首个公开版本。
- WinForms GUI、高 DPI、无控制台启动。
- 按 SSID 缓存、断线保活、DPAPI 保存密码。
