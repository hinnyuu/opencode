#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# opencode.sh — hinnyuu/opencode 容器化工作流启动脚本
#
# 功能：在宿主机上以 rootless podman 启动 opencode 容器，
#       提供多层安全保障（白名单、只读挂载、权限隔离）。
#
# 用法：
#   cd /data/projects/my-project && /data/apps/podman_rootless.opencode/opencode.sh
#   /data/apps/podman_rootless.opencode/opencode.sh --dataset /data/dataset/imagenet
# ─────────────────────────────────────────────────────────────────────────────

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ set -euo pipefail — Bash 严格模式，逐项解释：                               │
# │                                                                             │
# │ set：Bash 内建命令，用于修改 shell 的运行选项（行为开关）。                    │
# │                                                                             │
# │ -e (errexit)：任何命令返回非零退出码时，脚本立即终止。                        │
# │    防止「某步失败但脚本继续执行后续危险操作」的情况。                          │
# │                                                                             │
# │ -u (nounset)：引用未定义变量时立即报错退出，而非将其当作空字符串。             │
# │    防止拼写错误导致的静默逻辑错误（如 ${BASE_DIR} 拼成 ${BSE_DIR}）。         │
# │                                                                             │
# │ -o pipefail：管道命令的退出码取最后一个失败命令的退出码，而非最后一条命令。    │
# │    默认 Bash 只看管道最右端命令的退出码；加 pipefail 后                       │
# │    `curl ... | tar xz` 中 curl 失败也会被 -e 捕获。                          │
# └─────────────────────────────────────────────────────────────────────────────┘
set -euo pipefail

# ─── 常量 ────────────────────────────────────────────────────────────────────

BASE_DIR="/data/apps/podman_rootless.opencode"
# IMAGE="ghcr.io/hinnyuu/opencode:latest"
# 目前方便开发调试，直接使用 dev 镜像。正式发布后记得改回 latest。
IMAGE="hinnyuu/opencode:dev"
CONTAINER_NAME="opencode"

# ─── 白名单校验 ──────────────────────────────────────────────────────────────

PROJECT_DIR="$(pwd -P)"

ALLOWED_PREFIXES=(
    "/data/projects"
    "/data/test"
    "/data/dataset"
)

allowed=false
for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "${PROJECT_DIR}" == "${prefix}" || "${PROJECT_DIR}" == "${prefix}/"* ]]; then
        allowed=true
        break
    fi
done

if [[ "${allowed}" != "true" ]]; then
    echo "错误: 当前目录 ${PROJECT_DIR} 不在白名单内。" >&2
    echo "仅允许在以下目录及其子目录下启动：" >&2
    printf '  - %s\n' "${ALLOWED_PREFIXES[@]}" >&2
    exit 1
fi

# ─── 解析命令行参数 ──────────────────────────────────────────────────────────

DATASET_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)
            if [[ $# -lt 2 ]]; then
                echo "错误: --dataset 需要一个路径参数" >&2
                exit 1
            fi
            DATASET_ARGS+=("-v" "$2:$2:ro,z")
            shift 2
            ;;
        *)
            echo "错误: 未知参数 '$1'" >&2
            echo "用法: $0 [--dataset <路径>] ..." >&2
            exit 1
            ;;
    esac
done

# ─── 构建 podman run 参数 ────────────────────────────────────────────────────
# 使用数组：( ) 内部天然允许换行与注释，
# 彻底避免反斜杠续行中 # 注释吞掉后续参数的陷阱。

PODMAN_RUN_ARGS=(
    -it
    --rm
    --name "${CONTAINER_NAME}"

    # ═══ ① /root（Named Volume，读写）═══
    # 持久化 opencode 的全部运行时数据：
    #   .config/opencode/   — 配置（schema、keybindings 等运行时写入）
    #   .local/share/…      — 会话、auth.json（API 密钥）
    #   .local/state/…      — 日志、历史
    #   .cache/opencode/    — 缓存
    #   .cache/nix/         — nix 构建缓存
    #   .nix-profile/       — nix profile 符号链接（→ /nix/store/…）
    #   .nix-channels/      — nix channel 元数据
    #   .nix-defexpr/       — nix 默认表达式
    #   .npm/               — npm 缓存
    # 首次运行（空卷）：镜像中 /root 内容自动复制进卷。
    -v opencode-home:/root

    # ═══ ② /nix（Named Volume，读写）═══
    # nix store + profiles。与 ① 中 .nix-profile 的符号链接配合。
    # Named volume 由 Podman 管理 SELinux 标签，无需 :z/:Z。
    -v opencode-nix:/nix

    # ═══ ③ opencode.jsonc（只读，嵌套在 ① 之上）═══
    # Podman 按路径深度从浅到深应用挂载。
    # 效果：/root 整体 rw，但此文件 ro。
    # 安全：LLM 无法修改自身权限配置。
    # :Z = 私有 SELinux 标签（仅本容器可访问）。
    -v "${BASE_DIR}/root/.config/opencode/opencode.jsonc:/root/.config/opencode/opencode.jsonc:ro,Z"

    # ═══ ④ AGENTS.md（只读，嵌套在 ① 之上）═══
    # 同理：防止 LLM 篡改自身行为规则。
    -v "${BASE_DIR}/root/.config/opencode/AGENTS.md:/root/.config/opencode/AGENTS.md:ro,Z"

    # ═══ ⑤ 项目目录（读写，同路径挂载）═══
    # 容器内外路径完全一致，LLM 不会困惑于路径映射。
    # :z（小写）= 共享 SELinux 标签：
    #   项目目录可能被 IDE、测试容器、CI 等同时访问。
    -v "${PROJECT_DIR}:${PROJECT_DIR}:rw,z"

    # ═══ ⑥ 只读数据集（可选，由 --dataset 参数动态生成）═══
    # :ro = 只读，:z = 共享标签。
    # DATASET_ARGS 为空时 guarded 展开为空，set -u 下安全。
    ${DATASET_ARGS[@]+"${DATASET_ARGS[@]}"}

    # 工作目录 = 项目目录
    -w "${PROJECT_DIR}"
)

# ─── 启动容器 ────────────────────────────────────────────────────────────────
# exec：用 podman 进程替换当前 bash 进程，
#       使 Ctrl+C 信号直接传递给 podman（进而传递给容器），
#       避免 bash 中间层拦截信号导致容器无法优雅退出。
exec podman run "${PODMAN_RUN_ARGS[@]}" "${IMAGE}"