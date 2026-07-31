# Codex Credit

一个原生 macOS 菜单栏小工具，读取本机 Codex CLI 的额度并实时显示剩余百分比。

## 特性

- 菜单栏直接显示 `Codex 10%` 形式的综合剩余额度。
- 点击后查看主额度、次级额度、重置时间、套餐和可用重置权益。
- 启动时和每 60 秒自动刷新；打开菜单也会立即刷新。
- 通过 `codex app-server` 读取 Codex CLI 已保存的登录状态，不复制或保存访问令牌。
- 读取失败时保留上次成功数据，并在菜单中显示连接提示。

## 运行

需要 macOS 13+、已安装 Codex CLI，并先完成 `codex login`：

```sh
swift run CodexCredit
```

构建可双击的菜单栏 App：

```sh
./scripts/build-app.sh
open dist/CodexCredit.app
```

Codex CLI 通常安装在 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`。如果使用自定义路径，运行源码版本时可设置：

```sh
CODEX_BIN=/path/to/codex swift run CodexCredit
```

打包 App 使用常见安装路径；也可以先将自定义 CLI 放入 `PATH`，再从终端启动 App。

## 验证

```sh
swift test
swift build
```
