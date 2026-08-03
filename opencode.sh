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

# ─── 常量定义 ──────────────────────────────────────────────────────────────────

# 宿主机上本工作流的根目录。
# 其内部结构镜像容器内根目录（root/.config/... 对应容器内 /root/.config/...）。
BASE_DIR="/data/apps/podman_rootless.opencode"

# 容器镜像（由 GitHub Actions 从 hinnyuu/opencode 仓库构建推送）
IMAGE="ghcr.io/hinnyuu/opencode:latest"

# 容器名称（--rm 即用即走，不会冲突；此名称用于 podman logs 等调试）
CONTAINER_NAME="opencode"

# ─── 白名单校验 ────────────────────────────────────────────────────────────────
# 安全第③层：仅允许在白名单目录及其子目录下启动容器。
# 防止误在 / 或 /home 下启动导致项目目录挂载覆盖宿主机关键路径。

# 获取当前工作目录的绝对路径（pwd -P 解析所有符号链接）
PROJECT_DIR="$(pwd -P)"

# 白名单前缀列表：只有这些目录及其子目录允许作为项目挂载
ALLOWED_PREFIXES=(
    "/data/projects"
    "/data/test"
    "/data/dataset"
)

# 逐一检查 PROJECT_DIR 是否以白名单前缀开头
allowed=false
for prefix in "${ALLOWED_PREFIXES[@]}"; do
    # 精确匹配前缀本身，或前缀 + "/" + 子路径
    if [[ "${PROJECT_DIR}" == "${prefix}" || "${PROJECT_DIR}" == "${prefix}/"* ]]; then
        allowed=true
        break
    fi
done

# 不在白名单内则拒绝启动
if [[ "${allowed}" != "true" ]]; then
    echo "错误: 当前目录 ${PROJECT_DIR} 不在白名单内。" >&2
    echo "仅允许在以下目录及其子目录下启动：" >&2
    printf '  - %s\n' "${ALLOWED_PREFIXES[@]}" >&2
    exit 1
fi

# ─── 前置检查 ──────────────────────────────────────────────────────────────────

# 确认 opencode 二进制存在且可执行。
# -x 测试文件存在且具有执行权限。
if [[ ! -x "${BASE_DIR}/opencode/opencode" ]]; then
    echo "错误: ${BASE_DIR}/opencode/opencode 不存在或不可执行。" >&2
    echo "请先下载 opencode 二进制：" >&2
    echo "  curl -fsSL <release-url>/opencode-linux-x64.tar.gz | tar xz -C ${BASE_DIR}/opencode/" >&2
    echo "  chmod +x ${BASE_DIR}/opencode/opencode" >&2
    exit 1
fi

# ─── 解析命令行参数 ────────────────────────────────────────────────────────────
# 支持 --dataset 参数，可多次指定，将数据集目录以只读方式挂载进容器。

DATASET_ARGS=()   # 收集额外的 -v 挂载参数

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)
            # --dataset 后必须跟一个路径参数
            if [[ $# -lt 2 ]]; then
                echo "错误: --dataset 需要一个路径参数" >&2
                exit 1
            fi
            # SELinux 标签用小写 :z（共享标签）——数据集可被多个容器访问
            # :ro 只读——LLM 只能读取数据集，不能修改或删除
            DATASET_ARGS+=("-v" "$2:$2:ro,z")
            shift 2   # 消费 --dataset 和路径两个参数
            ;;
        *)
            echo "错误: 未知参数 '$1'" >&2
            echo "用法: $0 [--dataset <路径>] ..." >&2
            exit 1
            ;;
    esac
done

# ─── 启动容器 ──────────────────────────────────────────────────────────────────
# exec：用 podman 进程替换当前 bash 进程，
#       使 Ctrl+C 信号直接传递给 podman（进而传递给容器），
#       避免 bash 中间层拦截信号导致容器无法优雅退出。

exec podman run \
    -it \
        # -i (--interactive)：保持 STDIN 打开，即使无终端附加。
        # -t (--tty)：分配伪终端。
        # 两者组合使 TUI 界面正常工作。

    --rm \
        # 容器退出后自动删除容器实例。
        # 实现「即用即走」：不残留停止的容器。
        # 数据不丢失——所有持久数据在卷/挂载中，不在容器可写层。

    --name "${CONTAINER_NAME}" \
        # 固定容器名，方便 podman logs opencode 调试。

    # ═══ 挂载 ①：opencode 二进制（只读） ═══
    # SELinux :Z（大写）= 私有标签，仅本容器可访问（opencode 专属）。
    # :ro = 只读。LLM 无法篡改/删除/替换二进制。
    # 升级方式：宿主机替换文件 → 重启容器，无需重建镜像。
    -v "${BASE_DIR}/opencode/opencode:/opencode/opencode:ro,Z" \

    # ═══ 挂载 ②：配置目录（读写） ═══
    # OpenCode 运行时会向此目录写入 config.schema.json、keybindings.json 等。
    # 因此父目录必须 rw。
    # SELinux :Z = opencode 专属私有标签。
    -v "${BASE_DIR}/root/.config/opencode:/root/.config/opencode:rw,Z" \

    # ═══ 挂载 ③：opencode.jsonc（只读，嵌套在 ② 之上） ═══
    # 嵌套挂载：Podman 按路径深度从浅到深应用。
    # 效果：目录 rw，但此文件 ro。LLM 无法修改自身权限配置。
    # 活跃挂载点不可 rm/mv（Device or resource busy）。
    -v "${BASE_DIR}/root/.config/opencode/opencode.jsonc:/root/.config/opencode/opencode.jsonc:ro,Z" \

    # ═══ 挂载 ④：AGENTS.md（只读，嵌套在 ② 之上） ═══
    # 同理：防止 LLM 篡改自身行为规则。
    -v "${BASE_DIR}/root/.config/opencode/AGENTS.md:/root/.config/opencode/AGENTS.md:ro,Z" \

    # ═══ 挂载 ⑤：数据目录（读写） ═══
    # 存放 auth.json（API 密钥）、会话历史、日志。
    # 容器重建后 LLM 感知不到中断——会话、认证全部保留。
    -v "${BASE_DIR}/root/.local/share/opencode:/root/.local/share/opencode:rw,Z" \

    # ═══ 挂载 ⑥：/nix（Named Volume，读写） ═══
    # Named volume 由 Podman 管理，SELinux 标签自动处理，无需 :z/:Z。
    # 保存 nix store + profiles，使 nix-env 安装的包在容器重建后保留。
    -v opencode-nix:/nix \

    # ═══ 挂载 ⑦：项目目录（读写，同路径挂载） ═══
    # 容器内路径与宿主机完全一致，LLM 不会困惑于路径映射。
    # SELinux :z（小写）= 共享标签：
    #   项目目录可能被 IDE、测试容器、CI 等其他容器同时访问，
    #   不能用私有 :Z（否则其他容器无权访问）。
    -v "${PROJECT_DIR}:${PROJECT_DIR}:rw,z" \

    # ═══ 挂载 ⑧（可选）：只读数据集 ═══
    # 由 --dataset 参数动态生成。
    # SELinux :z（小写）= 共享标签（数据集非 opencode 专属）。
    # :ro = 只读（LLM 只能读取，不能修改数据集）。
    ${DATASET_ARGS[@]+"${DATASET_ARGS[@]}"} \

    # 工作目录 = 项目目录（容器内外路径一致）
    -w "${PROJECT_DIR}" \

    # 镜像名。CMD ["opencode"] 由镜像元数据提供。
    "${IMAGE}"
