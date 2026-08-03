# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# hinnyuu/opencode 容器镜像
# 基础：NixOS 官方 nix 镜像
# 职责：提供 nix 包管理 + git + ripgrep
# opencode 二进制、配置、数据均由宿主机挂载提供
# ─────────────────────────────────────────────────────────────────────────────

FROM nixos/nix:2.35.1

# 将 /opencode 加入 PATH。
# 基础镜像 PATH 仅含 nix 路径（/root/.nix-profile/bin 等），
# opencode 二进制通过宿主机 ro 挂载到 /opencode/opencode。
ENV PATH="/opencode:${PATH}"

# 启用 flakes（纯追加，不影响 nix-shell / nix-env 等经典命令）。
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# 核心工具安装。
#
# 注意：nixos/nix 基础镜像的 nix profile 中预装了 git-minimal
#（供其 entrypoint 脚本使用）。git-minimal 与完整版 git 在
# libexec/git-core/ 下存在同名文件，不能共存于同一 profile。
# 因此先 nix-env -e 移除 git-minimal，再安装完整版 git。
#
#   - git：版本控制，opencode 的 diff/undo 依赖
#   - ripgrep (rg)：opencode 的 grep 工具后端
#
# 不预装 python/node/gcc 等语言运行时，
# 需要时由 LLM 通过 nix-shell / nix develop 按需获取。
RUN nix-env -e git-minimal && \
    nix-env -iA nixpkgs.git nixpkgs.ripgrep && \
    git --version && rg --version

# /nix 声明为卷挂载点。
# 运行时由 opencode.sh 通过 named volume 挂载，
# 使已安装的 nix 包在容器重建后保留。
VOLUME ["/nix"]

# 不设置 WORKDIR——项目路径不固定，
# 由 opencode.sh 的 -w 参数在运行时指定。

# 容器入口：启动 opencode TUI。
CMD ["opencode"]