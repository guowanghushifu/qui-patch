# qui 自动补丁与构建脚本

这两个脚本用于修改 qui 的一分钟限制，并自动构建最新稳定版本。

⚠️：本项目只提供补丁脚本，不提供构建好的二进制文件，使用本补丁脚本之前，请仔细阅读脚本功能，对使用本项目造成的损失，你需要自行承担责任！

## 环境要求

需要安装：

- Bash
- Git
- curl
- Python 3
- Make
- Go
- Node.js、pnpm
- Docker

## apply-one-minute-limits.sh

对指定的 qui 源码目录应用补丁：

- FREE_SPACE 删除任务最低间隔调整为 1 分钟。
- Cross-seed RSS 最低运行间隔调整为 1 分钟。
- 修复 Docker 前端构建的 Node 和 pnpm workspace 配置。
- 支持重复执行，不会重复修改已完成的内容。
- 如果源码结构与预期不符，会停止执行，避免部分修改。

### 使用方法

在 qui 仓库根目录执行：

./scripts/apply-one-minute-limits.sh

指定其他源码目录：

./scripts/apply-one-minute-limits.sh /path/to/qui

## build-latest-release.sh

自动检查并构建 qui 最新稳定版本。

脚本会依次执行：

1. 更新当前 Git 分支并获取最新标签。
2. 查询 GitHub 最新稳定版本。
3. 为新版本创建独立 Git worktree。
4. 执行 apply-one-minute-limits.sh。
5. 执行 make build/docker。
6. 构建成功后记录版本并清理旧 worktree。

已成功构建的版本不会重复构建；构建失败的版本会在下次执行时重试。

### 使用方法

在 qui 仓库中执行：

./scripts/build-latest-release.sh

指定主仓库路径：

./scripts/build-latest-release.sh /path/to/qui

### 可选环境变量

自定义 release worktree 保存目录：

QUI_RELEASE_WORKTREE_ROOT=/path/to/worktrees \
./scripts/build-latest-release.sh /path/to/qui

使用自定义补丁脚本：

QUI_PATCH_SCRIPT=/path/to/apply-one-minute-limits.sh \
./scripts/build-latest-release.sh /path/to/qui

默认生成的 Docker 镜像为：

ghcr.io/autobrr/qui:dev