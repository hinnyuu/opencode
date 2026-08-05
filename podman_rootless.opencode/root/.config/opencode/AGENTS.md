# 全局行为规则（容器内工作流）

你运行在一个容器化隔离环境中，作为 **容器内 root 用户** 运行。
不要使用 `sudo`（未安装且不需要），不要尝试切换用户或提权。

---

## 依赖管理与项目环境（flake.nix 一律化）

所有系统级依赖必须通过 **Nix** 管理，这是本环境唯一的包管理方式。
不要假设系统已预装任何语言运行时（python、node、gcc 等）。

运行时与依赖按作用域分离（重要）：
- **项目级**运行时、编译器、库：一律由项目 `flake.nix` 提供（devShell / packages）。
  **禁止**用 `nix-env` 为项目安装语言运行时或项目依赖——全局安装绕开
  flake.lock 的版本锁定，会造成开发/交付环境漂移。
- **跨项目**通用工具（git、curl、编辑器等）及 bootstrap 工具（git/nix 本身
  必须先于任何项目存在）：`nix-env -iA nixpkgs.<pkg>` 持久安装（容器重建后保留），
  或 `nix-shell -p <pkg>` 临时使用。

**项目环境一律使用 flake.nix**；若项目尚无 flake.nix，先创建再开工。
进入项目环境统一使用 `nix develop`。

flake.nix 的三个输出，职责严格分离：
- **`devShell`**：开发与调试工具（编译器、解释器，以及按需的 sqlite CLI、jq、
  curl、lsof 等调试工具——不同语言/技术栈自行增减）。仅存在于开发 shell，
  **开发工具不得进入生产产物闭包**。
- **`packages.default`**：生产产物，闭包只含运行时依赖。按技术栈选择构建函数：
  - Node.js：`buildNpmPackage`（依据 package-lock.json 锁定）
  - Python：`buildPythonApplication`
  - Rust：`rustPlatform.buildRustPackage`
- **镜像输出（可选）**：`dockerTools` 生成 OCI tarball（见"容器镜像"节）。

其他规则：
- **`flake.lock` 必须提交**进仓库：锁定 nixpkgs commit，是跨机器字节级可复现的前提。
- 交付前必须本地验证生产产物：`nix build` 后直接运行 `./result` 冒烟测试。
- 不确定包名：`nix search nixpkgs <关键词>`。
- **禁止** 使用 apt / yum / apk / pacman 等系统包管理器。
- **禁止** 修改 `/etc/nix/nix.conf`。

---

## 不可变产物与可变状态

`/nix/store` 只读：`nix build` 产物（代码、依赖、静态资源）一经生成不可变。
判据只有一条——**文件是否在运行时被写入**：只读文件进包无碍，可写文件必须留在包外。

- 运行时可写文件（数据库及其 -wal/-shm、生成的配置、上传、缓存）的路径一律采用
  **环境变量覆盖 + 合理默认值**的单一代码路径，例如
  `process.env.DATA_DIR ?? './data'`（其他语言同理）：
  - 开发态：默认值生效，数据跟随项目目录（并加入 .gitignore）
  - 生产态：环境变量指向包外可写路径（裸机）或容器挂载点
- 通用原则（跨技术栈）：
  1. **可写状态集中存放**：数据库、生成配置、上传、缓存统一收进一个状态目录
     （data/ 或 var/）——备份=拷贝该目录，清理=删除该目录，挂载=一个 volume。
  2. **只读默认配置与可写用户配置分离**：默认值随包发布，用户覆盖写入状态目录。
  3. **日志走 stdout**（12-factor），由运行平台（docker/pm2/systemd）收集，
     应用不往包内写日志文件。
  4. **打包排除状态目录**：nix 派生不拷贝状态目录，镜像不烘焙开发数据。

---

## 容器镜像（无嵌套环境）

本容器禁止嵌套：无法运行 docker/podman daemon，无法 `docker build`。

- 构建镜像使用 `dockerTools.buildLayeredImage`（或 `buildImage` + `copyToRoot`）：
  纯文件组装（rsync + tar + manifest），无 daemon、无 namespace，本容器内可用。
- **禁止**使用 `runAsRoot` 参数：其实现依赖 QEMU 虚拟机 + `unshare`，
  会被无嵌套环境阻断。Dockerfile 中 RUN 的等价操作必须写成 Nix 派生的构建阶段。
- 产物为标准 OCI/Docker tarball：`docker load` / `podman load` 导入，
  `skopeo copy` 推送 registry，全程无需 daemon。
- 持久化：镜像内的状态目录通过 volume 挂载，不依赖容器可写层保存数据。

---

## 环境变量纪律

- 应用级变量（PORT、DATA_DIR 等）按进程或按项目设置：命令行前缀
  （`DATA_DIR=... ./app`）、项目内 .env、或 flake devShell 的 shellHook。
- **禁止**把应用级变量写入任何全局或用户级 shell 配置，避免跨项目污染
  （系统级配置文件的禁令见"危险操作禁令"节）。
- 必要时用项目前缀命名（如 `<APP>_DATA_DIR`）进一步避让。

---

## 工作目录

你的当前工作目录即为用户的项目目录，可自由读写。
**重要产出必须写入项目目录。**

---

## Git 与开发流程

- git clone / pull / push / fetch / commit 等操作正常允许
- 提交信息遵循 Conventional Commits（feat/fix/chore/docs/…）
- **多步变更必须走 feature 分支**：建分支 → 分小步实现 → 每步本地验证 →
  通过后才提交 → 全部完成后合并回主分支
- 提交前展示 diff 让用户确认
- **禁止** `git push --force`（除非用户明确要求）

---

## 网络

- 包管理器下载依赖（pip install、npm install、cargo add、nix-env 等）正常允许
- **经用户确认后**可进行git 远程操作
- 与代码仓库关联的镜像仓库（如 GHCR）视同 git 远程
- **禁止** 执行 `curl <url> | bash` 或 `wget <url> | sh`
- **禁止** 将项目代码或用户数据上传到 git 远程仓库以外的外部服务（粘贴板网站、公共 API、云存储等）

---

## 危险操作禁令

- **禁止** `rm -rf /`、`rm -rf /nix`、`rm -rf /opencode`
- **禁止** 修改 `/nix/store/` 内的文件（nix store 内容寻址、不可变，
  改动会破坏哈希与可复现性）
- **禁止** 修改 `/etc/profile`、`/etc/environment` 等全局环境配置
- **禁止** 尝试提权或逃逸容器

---

## 交互风格

- 执行 bash 命令前简要说明意图
- 遇到权限确认提示时，解释为什么需要执行该命令
- 遇到操作被拒绝时，解释原因并建议替代方案
