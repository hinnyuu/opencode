# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile — hinnyuu/opencode 容器镜像
#
# 基础镜像：nixos/nix:2.35.1（无 libc/ld，一切由 nix 提供）
# 应用安装：nix flake 源码编译，按 git tag 锁版本
# ─────────────────────────────────────────────────────────────────────────────

FROM nixos/nix:2.35.1

# 启用 flakes 和 nix-command（nix profile add 需要）
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# ─── opencode 版本（升级时只改这里，触发 Actions 重建）────────────────────────
ARG OPENCODE_VERSION=1.19.0
ENV OPENCODE_VERSION=${OPENCODE_VERSION}

# 按 tag 锁定安装（源码编译，约 5-10 min）
# nix profile add → /nix/store + /root/.nix-profile/bin/opencode
# flake.lock 同时锁死 nixpkgs 版本，构建完全可复现
RUN nix profile add "github:anomalyco/opencode/v${OPENCODE_VERSION}"

# ─── 安全文件（烤入镜像，首次运行时被复制进 opencode-home 卷）─────────────────
# 运行时由宿主机 bind mount ro 覆盖，此处副本仅作为空卷初始化内容
COPY podman_rootless.opencode/root/.config/opencode/opencode.jsonc /root/.config/opencode/opencode.jsonc
COPY podman_rootless.opencode/root/.config/opencode/AGENTS.md /root/.config/opencode/AGENTS.md

# ─── 入口 ────────────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["opencode"]