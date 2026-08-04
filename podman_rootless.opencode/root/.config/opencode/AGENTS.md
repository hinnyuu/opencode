# 全局行为规则（容器内工作流）

你运行在一个容器化隔离环境中，作为 **容器内 root 用户** 运行。
不要使用 `sudo`（未安装且不需要），不要尝试切换用户或提权。

---

## 依赖管理

所有系统级依赖必须通过 **Nix** 管理，这是本环境唯一的包管理方式。
不要假设系统已预装任何语言运行时（python、node、gcc 等）——缺少什么就用 nix 获取。

- 临时环境：`nix-shell -p <pkg1> <pkg2> ...`
- 持久安装：`nix-env -iA nixpkgs.<pkg>`
- 项目有 `flake.nix`：优先 `nix develop`
- 项目有 `shell.nix`：使用 `nix-shell`
- 不确定包名：`nix search nixpkgs <关键词>`
- 通过 `nix-env` 安装的工具在容器重建后保留，无需重复安装
- **禁止** 使用 apt / yum / apk / pacman 等系统包管理器
- **禁止** 修改 `/etc/nix/nix.conf`

---

## 工作目录

你的当前工作目录即为用户的项目目录，可自由读写。
**重要产出必须写入项目目录。**

---

## Git

- git clone / pull / push / fetch / commit 等操作正常允许
- 提交前展示 diff 让用户确认
- **禁止** `git push --force`（除非用户明确要求）

---

## 网络

- 包管理器下载依赖（pip install、npm install、cargo add、nix-env 等）正常允许
- git 远程操作正常允许
- **禁止** 执行 `curl <url> | bash` 或 `wget <url> | sh`
- **禁止** 将项目代码或用户数据上传到 git 远程仓库以外的外部服务（粘贴板网站、公共 API、云存储等）

---

## 危险操作禁令

- **禁止** `rm -rf /`、`rm -rf /nix`、`rm -rf /opencode`
- **禁止** 修改 `/nix/store/` 内的文件（nix store 是不可变的，直接编辑会失败）
- **禁止** 修改 `/etc/profile`、`/etc/environment` 等全局环境配置
- **禁止** 尝试提权或逃逸容器

---

## 交互风格

- 执行 bash 命令前简要说明意图
- 遇到权限确认提示时，解释为什么需要执行该命令
- 遇到操作被拒绝时，解释原因并建议替代方案