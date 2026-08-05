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
┌─────────────────────────────────────────────────────────────────────────────────┐
│  宿主机（Fedora · rootless podman · SELinux enforcing）                          │
│                                                                                 │
│  /data/apps/podman_rootless.opencode/                                           │
│  ├── opencode.sh                              ← 唯一入口脚本                     │
│  └── root/.config/opencode/                                                     │
│      ├── opencode.jsonc                       ← 安全文件（ro 嵌套挂入容器）       │
│      └── AGENTS.md                            ← 安全文件（ro 嵌套挂入容器）       │
│                                                                                 │
│  用法：cd /data/projects/<项目> && opencode.sh [--dataset /data/dataset/xxx]     │
│       │                                                                         │
│       ▼                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐     │
│  │  podman run -it --rm --name opencode                                  │     │
│  │                                                                         │     │
│  │  镜像   ghcr.io/hinnyuu/opencode:latest                               │     │
│  │  基础   nixos/nix:2.35.1（无 libc/ld，一切由 nix 提供）                 │     │
│  │  应用   nix flake 源码编译 opencode，按 git tag 锁版本                   │     │
│  │                                                                         │     │
│  │  ┌─ 挂载拓扑（Podman 按路径深度从浅到深应用）─────────────────────┐      │     │
│  │  │  ① opencode-home  → /root                named vol   rw      │      │     │
│  │  │  ② opencode-nix   → /nix                 named vol   rw      │      │     │
│  │  │  ③ opencode.jsonc → /root/.config/…/     bind ro,Z  嵌套于①  │      │     │
│  │  │  ④ AGENTS.md      → /root/.config/…/     bind ro,Z  嵌套于①  │      │     │
│  │  │  ⑤ 项目目录       → 同路径               bind rw,z           │      │     │
│  │  │  ⑥ 数据集 ×N      → 同路径               bind ro,z  可选     │      │     │
│  │  └────────────────────────────────────────────────────────────────┘      │     │
│  │                                                                         │     │
│  │  ENTRYPOINT  /entrypoint.sh（版本对账 → exec "$@"）                     │     │
│  │  CMD         ["opencode"]                                               │     │
│  └─────────────────────────────────────────────────────────────────────────┘     │
│                                                                                 │
│  持久卷（--rm 不删除命名卷，容器销毁后数据完整保留）：                              │
│  • opencode-home — /root 全部运行时数据                                          │
│  • opencode-nix  — /nix store + nix profiles                                    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 安全模型

```
┌─────────────────────────────────────────────────────────────────────┐
│  第①层：白名单                                                       │
│  opencode.sh 仅允许在 /data/projects、/data/test、/data/dataset     │
│  及其子目录下启动。防止误在 / 或 /home 下启动。                       │
├─────────────────────────────────────────────────────────────────────┤
│  第②层：只读安全文件                                                  │
│  opencode.jsonc 和 AGENTS.md 通过 bind mount ro 嵌套在卷之上。       │
│  LLM 无法修改自身权限配置和行为规则。                                 │
│  活跃挂载点不可 rm/mv（Device or resource busy）。                    │
├─────────────────────────────────────────────────────────────────────┤
│  第③层：只读数据集                                                    │
│  --dataset 挂载为 ro,z。LLM 只能读取，不能修改/删除。                 │
├─────────────────────────────────────────────────────────────────────┤
│  第④层：权限隔离                                                      │
│  容器以 rootless podman 运行。容器内 root 映射到宿主机用户命名空间，   │
│  实际权限受限于用户命名空间。安全文件 :Z 标签阻止其他容器访问。        │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 快速开始
⚠️ 本README.md假设你希望安装到`/data/apps/`实际根据需要，把`/data/apps/`替换为你期望的安装目录

### 前置条件

- 宿主机Podman ≥ 5.8.4（rootless 模式）
- SELinux 已启用（推荐）或已禁用（`:z`/`:Z` 标签会被忽略，不影响功能）
- 准备好了放置本项目的目录，如`/data/apps/`

### 部署

首先下载本项目的整个 podman_rootless.opencode 目录，放到你期望的安装目录，如`/data/apps/`。
然后给予 opencode.sh 执行权限：`chmod +x /data/apps/podman_rootless.opencode/opencode.sh`

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

## 挂载顺序与嵌套关系

Podman 按**路径深度从浅到深**应用挂载：

```
深度 0:  opencode-home  →  /root                                    (rw, named vol)
深度 0:  opencode-nix   →  /nix                                     (rw, named vol)
深度 4:  bind mount     →  /root/.config/opencode/opencode.jsonc    (ro, 嵌套于 opencode-home)
深度 4:  bind mount     →  /root/.config/opencode/AGENTS.md         (ro, 嵌套于 opencode-home)
深度 N:  bind mount     →  /data/projects/<项目>                     (rw, 独立)
深度 N:  bind mount     →  /data/dataset/<数据集>                    (ro, 独立, 可选)
```

效果矩阵

| 容器内路径 | 来源 | 读写 | SELinux | 说明 |
|---|---|---|---|---|
| `/root/` 整体 | opencode-home 卷 | rw | 自动 | 全部运行时数据 |
| `/root/.config/opencode/opencode.jsonc` | 宿主机 bind | **ro** | :Z | 覆盖卷中同名文件 |
| `/root/.config/opencode/AGENTS.md` | 宿主机 bind | **ro** | :Z | 覆盖卷中同名文件 |
| `/root/.config/opencode/`（目录本身） | opencode-home 卷 | rw | 自动 | LLM 可写入 schema 等 |
| `/nix/` 整体 | opencode-nix 卷 | rw | 自动 | nix store + profiles |
| `/data/projects/<项目>` | 宿主机 bind | rw | \:z | 同路径挂载 |
| `/data/dataset/<数据集>` | 宿主机 bind | ro | \:z | 只读 |

---

## 项目核心文件说明

```bash
.
├── Containerfile # 镜像构建定义
├── entrypoint.sh # 每次进入容器时检查opencode版本的Shell脚本
├── .github
│   └── workflows
│       └── build-image.yml # CI/CD：分支 → 镜像自动构建推送
└── podman_rootless.opencode
     ├── opencode.sh # 宿主机启动脚本
     └── root
         └── .config
             └── opencode
                 ├── AGENTS.md # LLM 行为规则模板
                 └── opencode.jsonc # OpenCode 权限配置模板
```
