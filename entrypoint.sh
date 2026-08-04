#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# entrypoint.sh — 版本对账后 exec CMD
#
# 为什么需要：
#   /nix 和 /root 都是 named volume。镜像升级后（烤入了新版 opencode），
#   旧卷会遮蔽镜像中的新内容。此脚本在启动时比对版本：
#   - 一致 → 零开销直接启动（99% 的情况）
#   - 不一致 → nix profile add 补装新版（仅升级后首次，一次性）
# ─────────────────────────────────────────────────────────────────────────────
set -eu

expected="${OPENCODE_VERSION:-}"
installed="$(opencode --version 2>/dev/null || echo none)"

# 版本格式：1.18.11+012c2f5（nix derivation 追加 git 短哈希）
# 匹配策略：精确等于 expected，或以 "expected+" 开头
case "${installed}" in
    "${expected}"|"${expected}+"*)
        # 版本一致，直接启动
        ;;
    *)
        echo "[entrypoint] opencode 版本不匹配（期望 v${expected}，当前 ${installed}）" >&2
        echo "[entrypoint] 正在安装 v${expected}，源码编译可能需要数分钟 ..." >&2
        nix profile remove opencode 2>/dev/null || true
        nix profile add "github:anomalyco/opencode/v${expected}"
        echo "[entrypoint] 安装完成。" >&2
        ;;
esac

exec "$@"