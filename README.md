# Codex Credit

Codex Credit 是一个原生 macOS 菜单栏应用，用于查看 Codex CLI 账户的实时额度，并在需要时打开本机已安装的 ChatGPT App。

## 功能

- 在菜单栏显示综合剩余额度百分比。
- 查看主额度、次级额度、重置时间、套餐和额外额度信息。
- 启动时、每 60 秒以及打开菜单时自动刷新。
- 刷新失败时保留最近一次成功数据，并显示错误提示。
- 通过 `codex app-server` 读取 Codex CLI 的登录状态；应用不会复制或保存访问令牌。
- 从菜单直接启动本机的 ChatGPT App（Bundle ID：`com.openai.chat`）。

## 系统要求

- macOS 13 或更高版本
- 已安装并完成登录的 [Codex CLI](https://github.com/openai/codex)
- 可选：已安装 ChatGPT macOS App，以使用“打开 ChatGPT”菜单项

首次使用前，请在终端完成登录：

```sh
codex login
```

## 安装与运行

### 从源码运行

```sh
swift run CodexCredit
```

如果 Codex CLI 不在常见安装路径中，可以通过环境变量指定路径：

```sh
CODEX_BIN=/path/to/codex swift run CodexCredit
```

### 构建 macOS App

```sh
./scripts/build-app.sh
open dist/CodexCredit.app
```

构建脚本会生成经过 ad-hoc 签名的 `dist/CodexCredit.app`。`dist/` 是构建产物，不应提交到仓库。

## 自动构建发布

每次向 GitHub 推送提交后，GitHub Actions 会在 macOS runner 上自动执行构建和测试，生成 `CodexCredit.app`，并更新一个名为 **Latest Build** 的预发布 Release。

Release 使用固定的 `latest` 标签，附件为 `CodexCredit-latest-macOS.zip`。因此不需要手动创建 Release 或上传文件；后续提交会自动替换该附件并将标签指向最新提交。

工作流定义位于 `.github/workflows/release.yml`。

## 使用说明

应用启动后会显示在 macOS 菜单栏。点击菜单栏中的额度数字即可查看详情：

- **立即刷新**：立即请求最新额度。
- **打开 ChatGPT**：启动本机已安装的 ChatGPT App；未安装时不会打开网页。
- **退出 Codex Credit**：退出应用。

应用通过 Codex CLI 的本地 `app-server` 获取数据。若额度读取失败，请确认 `codex login` 已成功完成，并检查 Codex CLI 是否位于 `PATH`、`CODEX_BIN` 或项目支持的常见路径中。

## 开发与验证

项目使用 Swift Package Manager，不依赖第三方库：

```sh
swift build
swift test
```

也可以使用 Make：

```sh
make build
make test
make app
make clean
```

源码位于 `Sources/CodexCredit/`，测试位于 `Tests/CodexCreditTests/`。

## 贡献

欢迎提交修复和改进。提交 Pull Request 前请：

1. 保持改动聚焦，并说明变更原因。
2. 为非平凡逻辑补充或更新测试。
3. 运行 `swift build` 和 `swift test`。
4. 不要提交 `.build/`、`dist/`、`.swiftpm/` 或 `.DS_Store`。

详细说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 问题反馈

提交 Issue 时请包含：

- macOS 版本和 Mac 芯片架构。
- Codex CLI 版本及安装方式。
- 复现步骤、实际结果和预期结果。
- 相关终端输出或应用错误提示；请移除令牌、账号信息等敏感内容。

## 许可证

本项目基于 [MIT License](LICENSE) 发布。
