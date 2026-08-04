# hinnyuu/opencode
##### 当前版本：v0.0.1 测试中
容器化 OpenCode 工作流——在便利性轻微下降的前提下，实现比直接使用 OpenCode CLI/TUI 更高级别的安全隔离。

---

## 设计思想

**核心原则：信任但验证（Trust but Verify）**

LLM 是强大的协作者，但它可能犯错、可能被 prompt injection 误导。本工作流不试图阻止 LLM 工作，而是：

1. **缩小爆炸半径**——容器隔离，最坏情况只损失一个容器
2. **关键文件不可篡改**——只读挂载，LLM 无法修改自身权限和行为规则
3. **审批门控**——敏感操作需人工确认
4. **即用即走**——无状态容器 + 持久卷，随时可重建

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│  宿主机（Rootless Podman 5.8+）                                  │
│                                                                  │
│  /data/apps/podman_rootless.opencode/                           │
│  ├── opencode.sh              ← 启动脚本（白名单校验）           │
│  ├── opencode/opencode        ← 二进制 → /opencode/opencode     │
│  ├── root/.config/opencode/   ← 配置目录 → /root/.config/...    │
│  │   ├── opencode.jsonc       ← 权限配置（ro）                  │
│  │   └── AGENTS.md            ← 行为规则（ro）                  │
│  └── root/.local/share/opencode/ ← 数据 → /root/.local/share/.. │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  容器（ghcr.io/hinnyuu/opencode:latest）                   │  │
│  │                                                            │  │
│  │  /opencode/opencode          [ro] 二进制                   │  │
│  │  /root/.config/opencode/     [rw] 目录                     │  │
│  │    ├── opencode.jsonc        [ro] 嵌套只读                 │  │
│  │    └── AGENTS.md             [ro] 嵌套只读                 │  │
│  │  /root/.local/share/opencode [rw] 持久数据                 │  │
│  │  /nix                        [rw] Named Volume             │  │
│  │  ${PROJECT_DIR}              [rw] 工作区（同路径挂载）       │  │
│  │  ${DATASET_PATH}             [ro] 可选只读数据集             │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 五层安全保障

| 层级 | 机制 | 防护目标 |
|------|------|----------|
| ① 镜像层 | 开源 GHCR 镜像，使用Github Workflow自动构建，nix 环境，无预装语言运行时 | 供应链安全，最小攻击面 |
| ② 容器层 | rootless Podman，`--rm` 即用即走 | 宿主机隔离，无残留 |
| ③ 脚本层 | 白名单目录校验 | 防止挂载 / 或 /home |
| ④ 权限层 | opencode.jsonc permission + AGENTS.md | LLM 操作审批与行为约束 |
| ⑤ 文件系统层 | 关键文件 ro 挂载，嵌套挂载 | 防篡改（二进制、配置、规则） |

---

## 快速开始
⚠️ 本README.md假设你希望安装到`/data/apps/`实际根据需要，把`/data/apps/`替换为你期望的安装目录

### 前置条件

- 宿主机Podman ≥ 5.8.4（rootless 模式）
- 宿主机有git
- SELinux 已启用（推荐）或已禁用（`:z`/`:Z` 标签会被忽略，不影响功能）
- 准备好了放置本项目的目录，如`/data/apps/`

### 部署

以下命令在单个bash中从头到尾完成：
```bash
# 1. 先去宿主机上想安装此项目的目录，本README.md假设你希望安装到/data/apps/ 实际根据需要更改
cd /data/apps/

# 2. 在刚刚的目录里，git pull整个仓库，取出核心目录，删掉仓库
git pull https://github.com/hinnyuu/opencode.git && mv /data/apps/opencode/podman_rootless.opencode /data/apps/ && rm -r /data/apps/opencode

# 3. 给予get_opencode_bin.sh运行权限，使用get_opencode_bin.sh下载 opencode 二进制
chmod +x /data/apps/podman_rootless.opencode/opencode/get_opencode_bin.sh
/data/apps/podman_rootless.opencode/opencode/get_opencode_bin.sh

# 4. 拉取镜像
podman pull ghcr.io/hinnyuu/opencode:latest

# 5. 首次运行会拉取镜像并初始化 nix volume
```

### 使用

```bash
# 授予启动脚本最基本的运行权限。
chmod +x /data/apps/podman_rootless.opencode/opencode.sh

# 进入项目目录，启动 opencode
cd /data/projects/my-project
/data/apps/podman_rootless.opencode/opencode.sh

# 带只读数据集
cd /data/projects/ml-experiment
/data/apps/podman_rootless.opencode/opencode.sh \
  --dataset /data/dataset/imagenet \
  --dataset /data/dataset/coco
```
Tips: 可以使用alias简化命令。

### 升级 opencode

```bash
# 保险起见，先退出容器再更换新的opencode官方二进制文件。
rm /data/apps/podman_rootless.opencode/opencode/opencode && /data/apps/podman_rootless.opencode/opencode/get_opencode_bin.sh
# 下次启动容器自动使用新版
```

---

## 依赖管理

本工作流采用 **nix 按需获取** 模式：

- 镜像仅包含 nix + git + ripgrep，极度精简
- 需要 python/node/gcc 等工具时，LLM 通过 `nix-shell -p <pkg>` 即时获取
- 项目有 `flake.nix` 时，`nix develop` 一键进入完整开发环境
- 无需为不同技术栈构建不同镜像，nix 在运行时解决一切依赖

---

## SELinux 标签规则

| 标签 | 含义 | 使用场景 |
|------|------|----------|
| `:Z`（大写） | 私有标签，仅当前容器可访问 | opencode 专属：二进制、配置、数据 |
| `:z`（小写） | 共享标签，多个容器可共同访问 | 项目目录、数据集 |
| 无标签 | Podman 自动管理 | Named Volume（如 opencode-nix） |

---

## 持久化与无感重建

容器 `--rm` 后重建，以下数据完整保留：

| 数据 | 存储位置 | 挂载方式 |
|------|----------|----------|
| 会话历史 | `/root/.local/share/opencode/` | bind mount rw |
| API 密钥 | `/root/.local/share/opencode/auth.json` | bind mount rw |
| nix 已安装包 | `/nix` | named volume |
| 项目文件 | `${PROJECT_DIR}`（同路径） | bind mount rw |
| 权限配置 | `/root/.config/opencode/opencode.jsonc` | bind mount ro |
| 行为规则 | `/root/.config/opencode/AGENTS.md` | bind mount ro |

**丢失的仅有**：容器可写层中的临时文件（/tmp 等）——这是预期行为。

---

## 维护

```bash
# 查看 nix volume 大小
podman volume inspect opencode-nix

# 重建 nix 环境（最坏情况恢复）
podman volume rm opencode-nix
# 下次启动自动重建，nix-env 安装的包需重新安装

# 清理无用镜像
podman image prune -f

# 查看容器日志（如果启动失败）
podman logs opencode
```

---

## 项目文件说明

| 文件 | 用途 |
|------|------|
| `.github/workflows/build-image.yml` | CI/CD：分支 → 镜像自动构建推送 |
| `podman_rootless.opencode/opencode/get_opencode_bin.sh` | 下载/更新opencode官方二进制的Shell脚本 |
| `Apodman_rootless.opencode/root/.config/opencode/AGENTS.md` | LLM 行为规则模板（复制到宿主机配置目录） |
| `podman_rootless.opencode/root/.config/opencode/opencode.jsonc` | OpenCode 权限配置模板（复制到宿主机配置目录） |
| `podman_rootless.opencode/opencode.sh` | 宿主机启动脚本 |
| `Containerfile` | 镜像构建定义 |
| `LICENSE` | 本项目采用AGPLv3 |
| `README.md` | 本文档 |