# Codex Credit Bar

[![Autobuild](https://github.com/notCorwin/Codex-Credit-Bar/actions/workflows/release.yml/badge.svg)](https://github.com/notCorwin/Codex-Credit-Bar/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Codex Credit Bar 是一个原生 macOS 菜单栏 App，用于快速查看 Codex CLI 账户的使用限额、Credits 和重置权益。它不会打开聊天窗口，启动后直接驻留在菜单栏。

![Codex Credit Bar 菜单栏预览](Assets/CodexMenuBarCreditPreview.jpeg)

## 功能

- 菜单栏优先显示 5 小时限额；账号没有该窗口时显示每周限额。额度耗尽后，按可用 Credits 或重置倒计时显示状态。
- 下拉菜单显示套餐、可用限额、Credits、限额重置权益和连接错误。
- 账户情况启动时及每 15 秒更新一次；每次打开菜单都会立即更新账户情况。
- 菜单栏 UI 每秒刷新一次，因此重置倒计时会持续更新；所有时间使用本机时区和易读的双单位格式。
- 支持简体中文和 English，按 macOS 当前语言选择界面语言。
- 通过本机 `codex app-server` 读取状态，不直接复制或保存 Codex 访问令牌。
- 启动 Codex CLI 时会保留 `CODEX_HOME`；没有显式代理环境变量时，应用也会尝试沿用 macOS 系统 HTTP、HTTPS、SOCKS 或 PAC 代理。
- 可从菜单打开已安装的 ChatGPT macOS App、打开项目 GitHub 页面，或执行 `pmset displaysleepnow` 熄屏。
- 每 3 分钟静默检查 GitHub `autobuild` Release；可用更新显示最新提交的 7 位哈希。点击更新菜单项后才会执行手动检查并询问是否下载、安装。

## 系统要求

- macOS 13 或更高版本；
- 已安装并完成登录的 [Codex CLI](https://github.com/openai/codex)；
- 可选：已安装 ChatGPT macOS App，以使用“打开 ChatGPT”。

从源码构建还需要 Swift 5.9 或更高版本及 macOS 开发者工具；下载已构建版本不需要本地 Swift 工具链。

首次使用 Codex CLI：

```sh
codex login
```

应用默认从 `PATH` 和常见安装路径查找 `codex`。如果需要指定可执行文件，可以设置 `CODEX_BIN`：

```sh
CODEX_BIN=/path/to/codex swift run
```

如果 Codex 使用非默认目录，也可以按 Codex CLI 的配置设置 `CODEX_HOME`。

## 菜单栏显示逻辑

状态栏会按以下优先级选择内容：

| 账户状态 | 状态栏显示 |
| --- | --- |
| 有 5 小时限额且尚未耗尽 | 5 小时限额剩余百分比 |
| 5 小时限额耗尽、每周限额未耗尽 | Credits 余额；没有可用 Credits 时显示 5 小时限额重置倒计时 |
| 每周限额耗尽 | Credits 余额；没有可用 Credits 时显示每周限额重置倒计时 |
| 没有 5 小时限额 | 每周限额剩余百分比；每周限额耗尽时使用上一行的 Credits/倒计时逻辑 |

额度耗尽时，菜单栏的 Credits 状态使用 macOS SF Symbol；时间始终最多显示两个单位，例如 `3 小时 29 分钟` 或 `18 秒`。

## 安装与运行

### 下载已构建版本

从 [autobuild Release](https://github.com/notCorwin/Codex-Credit-Bar/releases/tag/autobuild) 下载 `Codex.Credit.Bar.app.tar`，解压后启动 App：

```sh
tar -xf Codex.Credit.Bar.app.tar
open "Codex Credit Bar.app"
```

从 GitHub Release 启动的已打包 App 支持菜单内更新。`swift run` 适合开发和调试，不提供 App 自更新。

### 从源码运行

项目使用 Swift Package Manager，只有系统框架依赖：

```sh
git clone https://github.com/notCorwin/Codex-Credit-Bar.git
cd Codex-Credit-Bar
codex login
swift run
```

### 构建 macOS App

要生成可双击启动的 App：

```sh
./scripts/build-app.sh
open "dist/Codex Credit Bar.app"
```

也可以使用 Make：

```sh
make app
```

脚本会在 `dist/` 生成经过 ad-hoc 签名的 App。`.build/`、`.swiftpm/` 和 `dist/` 都是本地构建产物，不应提交到 Git。

## 使用说明

启动后点击菜单栏中的 Codex Credit Bar，即可查看当前账户信息。更新行为如下：

- 账户数据自动每 15 秒刷新；打开菜单时会立即刷新账户数据，但不会触发软件版本检查。
- 菜单内容每秒重绘，以更新重置倒计时和“多久之前发布”等相对时间。
- 软件版本每 3 分钟静默检查一次；发现更新时只更新菜单项，不自动弹窗或安装。
- 点击“检查更新”或显示可用版本的菜单项，会立即检查版本；发现更新后可确认下载并安装。
- “打开 ChatGPT”只会打开本机已安装的 ChatGPT App，不会改为打开网页。
- “熄屏”调用 macOS 的 `/usr/bin/pmset displaysleepnow`。

## 开发与验证

```sh
swift build
swift test
```

等价的 Make 目标：

```sh
make build
make test
make app
make clean
```

主要目录：

- [`Sources/CodexMenuBarCredit`](Sources/CodexMenuBarCredit)：App 启动、菜单栏 UI、Codex app-server 通信、额度格式化、本地化和更新器；
- [`Tests/CodexMenuBarCreditTests`](Tests/CodexMenuBarCreditTests)：额度模型、格式化、本地化、通信和更新流程测试；
- [`scripts/build-app.sh`](scripts/build-app.sh)：构建、打包和签名 macOS App；
- [`.github/workflows/release.yml`](.github/workflows/release.yml)：构建测试并发布 `autobuild` Release。

## 获取帮助

请通过 [GitHub Issues](https://github.com/notCorwin/Codex-Credit-Bar/issues) 报告问题，并附上：

- macOS 版本和芯片架构；
- Codex CLI 版本和安装方式；
- 使用 `swift run`、源码构建 App 还是 Release App；
- 复现步骤和完整错误提示。

提交日志、截图或环境信息前，请删除访问令牌、账号标识和其他敏感内容。额度读取问题通常还需要确认 `codex login` 已完成、App 与 CLI 使用同一 macOS 用户，以及 `CODEX_BIN`、`CODEX_HOME` 和代理配置是否正确。

## 贡献与维护

欢迎提交聚焦的 Pull Request。请先阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)，并在行为变更时补充测试、更新受影响的文档，避免提交构建产物和敏感信息。

项目由 [notCorwin](https://github.com/notCorwin) 维护。许可证见 [`LICENSE`](LICENSE)。
