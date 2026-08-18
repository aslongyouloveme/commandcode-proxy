#!/usr/bin/env bash
# ==============================================================================
# Command Code Proxy — 本地构建 + 发布到服务器 一键脚本（Key 隔离版）
#
# Key 隔离设计:
#   本地  : config.json + keys.json，允许无 key 启动（请求头透传），不会被打包进镜像
#   服务器: 镜像内含 config.server.json（默认空 key），运行时必须注入 CC_SERVER_KEY 环境变量
#           proxy.mjs 在 CC_SERVER_MODE=1 时强制校验 CC_SERVER_KEY=user_xxx，否则容器启动即退出 1
#           可选多 Key: 本地准备 keys.server.json → 部署时一并同步到服务器
#
# 功能: 1)本地构建 2)传输镜像到服务器 3)远程拉起容器（注入服务器 Key）4)健康检查
#
# 使用:
#   cp deploy.env.example deploy.env  # 填 SERVER_HOST + CC_SERVER_KEY
#   ./deploy.sh                       # 一键构建+发布
#   ./deploy.sh --build-only / --deploy-only / --dry-run
#   ./deploy.sh --host 1.2.3.4 --server-key user_xxx
# ==============================================================================
set -euo pipefail

# ---------- 默认配置 ----------
IMAGE_NAME="${IMAGE_NAME:-commandcode-proxy}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-cc-proxy}"
CONTAINER_PORT="${CONTAINER_PORT:-3050}"
HOST_PORT="${HOST_PORT:-3050}"
PLATFORM="${PLATFORM:-linux/amd64}"

SERVER_HOST="${SERVER_HOST:-}"
SERVER_USER="${SERVER_USER:-root}"
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
SERVER_SSH_KEY="${SERVER_SSH_KEY:-}"
REMOTE_DIR="${REMOTE_DIR:-~/commandcode-proxy}"

# 服务器 Key 隔离（必填）
CC_SERVER_KEY="${CC_SERVER_KEY:-}"
CC_SERVER_KEYS_FILE="${CC_SERVER_KEYS_FILE:-}"  # 可选：本地 keys.server.json 路径
SERVER_KEYS_FILENAME="keys.server.json"         # 远程文件名（固定，与 config.server.json 一致）

TRANSFER_MODE="${TRANSFER_MODE:-direct}"
REGISTRY="${REGISTRY:-}"
REMOTE_MODE="${REMOTE_MODE:-run}"

HEALTH_PATH="${HEALTH_PATH:-/health}"

NO_CACHE="${NO_CACHE:-0}"
DRY_RUN=0
BUILD_ONLY=0
DEPLOY_ONLY=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/deploy.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

usage() {
  cat <<EOF
用法: ./deploy.sh [选项]

Key 隔离:
  服务器 CC_SERVER_KEY 必须以 user_ 开头，仅通过环境变量注入，不落镜像/不写文件。
  本地可无 key 运行；服务器无合法 CC_SERVER_KEY 时容器启动即失败（exit 1）。

选项:
  --host HOST            服务器 IP/域名
  --user USER            SSH 用户名 (默认 root)
  --port PORT            SSH 端口 (默认 22)
  --key PATH             SSH 私钥路径
  --server-key KEY       服务器 CC_SERVER_KEY (user_xxx)，也可写入 deploy.env
  --server-keys-file F   服务器多 Key 文件（本地路径，默认 keys.server.json 如存在则自动同步）
  --tag TAG              镜像 tag (默认 latest)
  --registry URL         镜像仓库地址，设置后自动切换为 registry 模式
  --platform PLATFORM    构建平台 (默认 linux/amd64)
  --remote-dir DIR       服务器部署目录 (默认 ~/commandcode-proxy)
  --compose              远程使用 docker compose 启动
  --no-cache             构建时不使用缓存
  --build-only           仅本地构建
  --deploy-only          仅远程部署（跳过构建）
  --dry-run              只打印将要执行的命令，不实际执行
  -h, --help             显示帮助
EOF
}

# ---------- 加载 deploy.env ----------
if [[ -f "$ENV_FILE" ]]; then
  log "加载配置: $ENV_FILE"
  set -a; source "$ENV_FILE"; set +a
fi

# ---------- 解析参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)             SERVER_HOST="$2"; shift 2;;
    --user)             SERVER_USER="$2"; shift 2;;
    --port)             SERVER_SSH_PORT="$2"; shift 2;;
    --key)              SERVER_SSH_KEY="$2"; shift 2;;
    --server-key)       CC_SERVER_KEY="$2"; shift 2;;
    --server-keys-file) CC_SERVER_KEYS_FILE="$2"; shift 2;;
    --tag)              IMAGE_TAG="$2"; shift 2;;
    --registry)         REGISTRY="$2"; TRANSFER_MODE="registry"; shift 2;;
    --platform)         PLATFORM="$2"; shift 2;;
    --remote-dir)       REMOTE_DIR="$2"; shift 2;;
    --compose)          REMOTE_MODE="compose"; shift;;
    --no-cache)         NO_CACHE=1; shift;;
    --build-only)       BUILD_ONLY=1; shift;;
    --deploy-only)      DEPLOY_ONLY=1; shift;;
    --dry-run)          DRY_RUN=1; shift;;
    -h|--help)          usage; exit 0;;
    *) err "未知参数: $1"; usage; exit 1;;
  esac
done

if [[ -n "$REGISTRY" && "$TRANSFER_MODE" == "direct" ]]; then
  TRANSFER_MODE="registry"
fi

FULL_IMAGE="$IMAGE_NAME:$IMAGE_TAG"
if [[ -n "$REGISTRY" ]]; then
  FULL_IMAGE="$REGISTRY/$IMAGE_NAME:$IMAGE_TAG"
fi

# 若未显式指定 CC_SERVER_KEYS_FILE，且本地存在 keys.server.json 则自动同步
if [[ -z "$CC_SERVER_KEYS_FILE" && -f "$SCRIPT_DIR/keys.server.json" ]]; then
  CC_SERVER_KEYS_FILE="$SCRIPT_DIR/keys.server.json"
fi
# 兼容：keys.server.json 不存在但配置了自定义路径则检查
if [[ -n "$CC_SERVER_KEYS_FILE" && ! -f "$CC_SERVER_KEYS_FILE" && "$BUILD_ONLY" != "1" ]]; then
  warn "CC_SERVER_KEYS_FILE=$CC_SERVER_KEYS_FILE 不存在，将仅使用 CC_SERVER_KEY 单 key 模式"
  CC_SERVER_KEYS_FILE=""
fi

SSH_BASE="ssh -p $SERVER_SSH_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
if [[ -n "$SERVER_SSH_KEY" ]]; then
  SSH_BASE="$SSH_BASE -i $SERVER_SSH_KEY"
fi
SCP_BASE="scp -P $SERVER_SSH_PORT -o StrictHostKeyChecking=accept-new"
if [[ -n "$SERVER_SSH_KEY" ]]; then
  SCP_BASE="$SCP_BASE -i $SERVER_SSH_KEY"
fi

run_or_echo() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} $*"
  else
    eval "$@"
  fi
}

prompt_if_empty() {
  local var_name="$1" prompt="$2" val
  val="$(eval echo \$$var_name)"
  if [[ -z "$val" && "$BUILD_ONLY" != "1" ]]; then
    read -rp "$(echo -e ${YELLOW}$prompt${NC}: )" val
    eval "$var_name=\"\$val\""
  fi
}

# ---------- 校验 CC_SERVER_KEY 格式 ----------
is_valid_server_key() {
  [[ "$1" =~ ^user_[a-zA-Z0-9_-]+$ ]]
}
# 支持 "Bearer user_xxx" 输入，提取出 user_ 部分
normalize_server_key() {
  local raw="$1"
  local m
  m=$(echo "$raw" | grep -oE 'user_[a-zA-Z0-9_-]+' | head -n1 || true)
  echo "$m"
}

if [[ "$BUILD_ONLY" != "1" ]]; then
  prompt_if_empty SERVER_HOST "请输入服务器 IP/域名 (SERVER_HOST)"
  prompt_if_empty SERVER_USER "请输入 SSH 用户名 (默认 root)"
  SERVER_USER="${SERVER_USER:-root}"

  # CC_SERVER_KEY 交互式补全 + 格式校验
  if [[ -z "$CC_SERVER_KEY" ]]; then
    printf "${YELLOW}请输入服务器 CC_SERVER_KEY (user_xxx): ${NC}"
    read -r _raw || true
    CC_SERVER_KEY="$(normalize_server_key "$_raw")"
    if [[ -z "$CC_SERVER_KEY" && -n "$_raw" ]]; then
      CC_SERVER_KEY="$(echo "$_raw" | xargs)"
    fi
  else
    CC_SERVER_KEY="$(normalize_server_key "$CC_SERVER_KEY")"
  fi
fi

if [[ -z "$SERVER_HOST" && "$BUILD_ONLY" != "1" ]]; then
  err "SERVER_HOST 未设置，请通过 --host 或 deploy.env 配置"; exit 1
fi

# 非 build-only 时强制校验服务器 key
if [[ "$BUILD_ONLY" != "1" ]]; then
  CC_SERVER_KEY="$(normalize_server_key "$CC_SERVER_KEY")"
  if ! is_valid_server_key "$CC_SERVER_KEY"; then
    err "CC_SERVER_KEY 非法或为空，必须为 user_xxx 格式（字母/数字/_/-）"
    if [[ -n "$CC_SERVER_KEY" ]]; then
      err "当前值: ${CC_SERVER_KEY:0:16}..."
    else
      err "当前为空。请在 deploy.env 中设置 CC_SERVER_KEY=user_xxx 或通过 --server-key 传入"
    fi
    err "本地可无 key 运行；服务器必须通过环境变量 CC_SERVER_KEY 注入，仅走此脚本或 compose 的 CC_SERVER_KEY"
    exit 1
  fi
  # 回写规范化后的值，供后续 docker run / compose 使用
  export CC_SERVER_KEY
fi

# ---------- 依赖检查 ----------
check_deps() {
  step "环境检查"
  command -v docker >/dev/null 2>&1 || { err "未找到 docker，请先安装 Docker"; exit 1; }
  if [[ "$BUILD_ONLY" != "1" ]]; then
    command -v ssh >/dev/null 2>&1 || { err "未找到 ssh"; exit 1; }
  fi
  docker info >/dev/null 2>&1 || warn "docker daemon 可能未启动，请检查 docker 是否运行中"

  info "镜像: $FULL_IMAGE"
  info "平台: $PLATFORM"
  info "传输模式: $TRANSFER_MODE"
  info "远程模式: $REMOTE_MODE"
  if [[ "$BUILD_ONLY" != "1" ]]; then
    info "服务器: $SERVER_USER@$SERVER_HOST:$SERVER_SSH_PORT"
    info "远程目录: $REMOTE_DIR"
    info "服务器 Key: ${CC_SERVER_KEY:0:12}... (环境变量注入，不落盘)"
    if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
      info "服务器多 Key 池: $CC_SERVER_KEYS_FILE → 远程 $SERVER_KEYS_FILENAME"
    else
      info "服务器多 Key 池: 未配置（单 key 模式）"
    fi
    info "本地 Key 隔离: 镜像已排除 keys.json / keys.server.json / deploy.env"
  fi
  if [[ "$NO_CACHE" == "1" ]]; then info "构建: --no-cache"; fi
  if [[ "$DRY_RUN" == "1" ]]; then warn "DRY-RUN 模式，不会实际执行"; fi
}

# ---------- 本地构建 ----------
build_image() {
  step "步骤 1/3 — 本地构建镜像"
  local build_args=()
  if [[ "$NO_CACHE" == "1" ]]; then build_args+=(--no-cache); fi

  if [[ "$PLATFORM" == *","* ]]; then
    info "多架构构建: $PLATFORM"
    if ! docker buildx version >/dev/null 2>&1; then
      err "多架构构建需要 docker buildx，请先安装或改用单架构 PLATFORM=linux/amd64"; exit 1
    fi
    if [[ "$TRANSFER_MODE" == "direct" ]]; then
      err "多架构 (amd64,arm64) 无法使用 direct 直传模式，请配置 REGISTRY 后使用 registry 模式"
      echo "  例: ./deploy.sh --platform linux/amd64,linux/arm64 --registry ghcr.io/yourname"
      exit 1
    fi
    run_or_echo "docker buildx build --platform $PLATFORM -t $FULL_IMAGE --push ${build_args[*]:-} \"$SCRIPT_DIR\""
    BUILDX_PUSHED=1
  else
    run_or_echo "docker build --platform $PLATFORM -t $FULL_IMAGE ${build_args[*]:-} \"$SCRIPT_DIR\""
    BUILDX_PUSHED=0
  fi
  log "构建完成: $FULL_IMAGE"
  if [[ "$DRY_RUN" != "1" ]]; then
    docker images "$FULL_IMAGE" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null | head -n 5 || true
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    info "镜像内已包含 config.server.json（空 key）；本地 keys 已排除，不会泄露到服务器"
  fi
}

# ---------- 传输镜像 ----------
transfer_image() {
  if [[ "${BUILDX_PUSHED:-0}" == "1" ]]; then
    log "多架构镜像已通过 buildx 直接推送到 $REGISTRY，跳过传输步骤"
    return
  fi

  step "步骤 2/3 — 传输镜像到服务器"

  if [[ "$TRANSFER_MODE" == "registry" ]]; then
    if [[ -z "$REGISTRY" ]]; then
      err "registry 模式需要设置 REGISTRY (如 ghcr.io/yourname)"; exit 1
    fi
    log "推送到仓库: $FULL_IMAGE"
    run_or_echo "docker push $FULL_IMAGE"
    log "推送完成，服务器将执行 docker pull"
  else
    log "直传模式: 压缩并流式传输（无需镜像仓库）"
    log "正在传输 $FULL_IMAGE → $SERVER_USER@$SERVER_HOST ..."
    if [[ "$DRY_RUN" == "1" ]]; then
      echo -e "${YELLOW}[dry-run]${NC} docker save $FULL_IMAGE | gzip | $SSH_BASE $SERVER_USER@$SERVER_HOST 'gunzip | docker load'"
    else
      local size
      size=$(docker images "$FULL_IMAGE" --format "{{.Size}}" 2>/dev/null | head -n1 || echo "未知")
      info "镜像大小: $size，传输中请稍候..."
      docker save "$FULL_IMAGE" | gzip | $SSH_BASE "$SERVER_USER@$SERVER_HOST" 'gunzip | docker load'
      log "传输完成"
    fi
  fi
}

# 同步服务器配置到远程（compose 模式必需，run 模式可选）
sync_server_configs() {
  local need_sync=0
  if [[ "$REMOTE_MODE" == "compose" ]]; then need_sync=1; fi
  if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then need_sync=1; fi
  if [[ "$need_sync" == "0" ]]; then return 0; fi

  log "同步服务器配置到 $SERVER_USER@$SERVER_HOST:$REMOTE_DIR ..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} $SSH_BASE $SERVER_USER@$SERVER_HOST 'mkdir -p $REMOTE_DIR'"
    echo -e "${YELLOW}[dry-run]${NC} $SCP_BASE docker-compose.yml config.server.json → $REMOTE_DIR/"
    if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
      echo -e "${YELLOW}[dry-run]${NC} $SCP_BASE $CC_SERVER_KEYS_FILE → $REMOTE_DIR/$SERVER_KEYS_FILENAME"
    fi
    return 0
  fi
  $SSH_BASE "$SERVER_USER@$SERVER_HOST" "mkdir -p $REMOTE_DIR"
  local ok=1
  $SCP_BASE "$SCRIPT_DIR/docker-compose.yml" "$SERVER_USER@$SERVER_HOST:$REMOTE_DIR/" || { warn "docker-compose.yml 同步失败"; ok=0; }
  if [[ -f "$SCRIPT_DIR/config.server.json" ]]; then
    $SCP_BASE "$SCRIPT_DIR/config.server.json" "$SERVER_USER@$SERVER_HOST:$REMOTE_DIR/" || warn "config.server.json 同步失败"
  fi
  if [[ -n "$CC_SERVER_KEYS_FILE" && -f "$CC_SERVER_KEYS_FILE" ]]; then
    $SCP_BASE "$CC_SERVER_KEYS_FILE" "$SERVER_USER@$SERVER_HOST:$REMOTE_DIR/$SERVER_KEYS_FILENAME" || warn "keys.server.json 同步失败"
    $SSH_BASE "$SERVER_USER@$SERVER_HOST" "chmod 600 $REMOTE_DIR/$SERVER_KEYS_FILENAME 2>/dev/null || true"
  fi
  # 远程生成 .env 供 compose 读取（避免把 key 写进 compose 文件）
  if [[ "$REMOTE_MODE" == "compose" ]]; then
    $SSH_BASE "$SERVER_USER@$SERVER_HOST" "cat > $REMOTE_DIR/.env <<'ENVEOF'
CC_SERVER_MODE=1
CC_SERVER_KEY=$CC_SERVER_KEY
ENVEOF
chmod 600 $REMOTE_DIR/.env 2>/dev/null || true
cat $REMOTE_DIR/.env | sed 's/CC_SERVER_KEY=.*/CC_SERVER_KEY=user_****/' || true
"
  fi
}

# ---------- 远程部署 ----------
remote_deploy() {
  step "步骤 3/3 — 远程部署"

  # 先同步配置（compose 必需）
  if [[ "$REMOTE_MODE" == "compose" || -n "$CC_SERVER_KEYS_FILE" ]]; then
    sync_server_configs
  fi

  if [[ "$REMOTE_MODE" == "compose" ]]; then
    log "使用 docker compose 模式部署（CC_SERVER_MODE=1 + CC_SERVER_KEY 环境变量注入）"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo -e "${YELLOW}[dry-run]${NC} $SSH_BASE $SERVER_USER@$SERVER_HOST 'cd $REMOTE_DIR && docker compose up -d --pull always  (env: CC_SERVER_MODE=1 CC_SERVER_KEY=user_****)'"
      if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
        echo -e "${YELLOW}[dry-run]${NC} 挂载: ./$SERVER_KEYS_FILENAME → /app/$SERVER_KEYS_FILENAME (多 Key 池)"
      fi
    else
      if [[ "$TRANSFER_MODE" == "registry" ]]; then
        $SSH_BASE "$SERVER_USER@$SERVER_HOST" "cd $REMOTE_DIR && docker pull $FULL_IMAGE || true; docker compose up -d"
      else
        $SSH_BASE "$SERVER_USER@$SERVER_HOST" "cd $REMOTE_DIR && docker compose up -d"
      fi
      # 若是 run 模式之前遗留的容器，同名则 compose 会重建
    fi
  else
    log "使用 docker run 模式部署（-e CC_SERVER_MODE=1 -e CC_SERVER_KEY 注入）"
    local remote_cmd
    remote_cmd=$(cat <<EOSSH
set -e
echo "[remote] 停止旧容器(如存在)..."
docker rm -f $CONTAINER_NAME 2>/dev/null || true
EOSSH
)
    if [[ "$TRANSFER_MODE" == "registry" && "${BUILDX_PUSHED:-0}" != "1" ]]; then
      remote_cmd+="
echo '[remote] 拉取镜像: $FULL_IMAGE'
docker pull $FULL_IMAGE
"
    elif [[ "$TRANSFER_MODE" == "registry" && "${BUILDX_PUSHED:-0}" == "1" ]]; then
      remote_cmd+="
echo '[remote] 拉取多架构镜像: $FULL_IMAGE'
docker pull $FULL_IMAGE
"
    fi

    # 构造 docker run：注入服务器 key + 可选多 key 文件挂载
    local run_extra=""
    if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
      # direct 模式下镜像已传输，keys 文件需提前同步到 REMOTE_DIR
      if [[ "$DRY_RUN" != "1" ]]; then
        # 同步已在 sync_server_configs 中完成（run 模式也走一遍以确保文件存在）
        :
      fi
      run_extra=" -v $REMOTE_DIR/$SERVER_KEYS_FILENAME:/app/$SERVER_KEYS_FILENAME:ro"
      # 同时告知容器内 keysFile 路径（config.server.json 已默认为 keys.server.json，此处双保险）
      run_extra="$run_extra -e CC_KEYS_FILE=$SERVER_KEYS_FILENAME"
    fi

    # 为避免 key 出现在 ps 输出中，远程用 env-file 方式注入（临时文件阅后即焚）
    remote_cmd+="
echo '[remote] 启动新容器（服务器模式，Key 环境变量隔离）...'
# 写入临时 env 文件避免 key 出现在 docker ps / history
cat > /tmp/cc-proxy.env.$$ <<'ENVEOF'
CC_SERVER_MODE=1
CC_SERVER_KEY=$CC_SERVER_KEY
ENVEOF
chmod 600 /tmp/cc-proxy.env.$$ 2>/dev/null || true
docker run -d --restart unless-stopped --name $CONTAINER_NAME -p $HOST_PORT:$CONTAINER_PORT --env-file /tmp/cc-proxy.env.$$ $run_extra $FULL_IMAGE
shred -u /tmp/cc-proxy.env.$$ 2>/dev/null || rm -f /tmp/cc-proxy.env.$$
echo '[remote] 容器状态:'
docker ps --filter name=$CONTAINER_NAME --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
# 若未同步 keys 文件但容器内需要多 Key，提示
if [ -n \"$CC_SERVER_KEYS_FILE\" ]; then echo \"[remote] 已挂载多 Key 池: $REMOTE_DIR/$SERVER_KEYS_FILENAME\"; fi
"

    if [[ "$DRY_RUN" == "1" ]]; then
      # 脱敏展示
      local masked
      masked=$(echo "$remote_cmd" | sed "s/CC_SERVER_KEY=.*/CC_SERVER_KEY=user_****/")
      # 补充说明 dry-run 时文件同步步骤
      if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
        echo -e "${YELLOW}[dry-run] 同步:${NC} $SCP_BASE $CC_SERVER_KEYS_FILE → $REMOTE_DIR/$SERVER_KEYS_FILENAME"
      fi
      echo -e "${YELLOW}[dry-run] 远程命令:${NC}"
      echo "$masked"
    else
      # run 模式也需要远程目录 + 可选 keys 文件
      if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
        $SSH_BASE "$SERVER_USER@$SERVER_HOST" "mkdir -p $REMOTE_DIR"
        $SCP_BASE "$CC_SERVER_KEYS_FILE" "$SERVER_USER@$SERVER_HOST:$REMOTE_DIR/$SERVER_KEYS_FILENAME" || warn "keys.server.json 同步失败，服务器将以单 key 运行"
        $SSH_BASE "$SERVER_USER@$SERVER_HOST" "chmod 600 $REMOTE_DIR/$SERVER_KEYS_FILENAME 2>/dev/null || true"
      fi
      $SSH_BASE "$SERVER_USER@$SERVER_HOST" "$remote_cmd"
    fi
  fi
  log "远程部署完成（服务器已注入 CC_SERVER_KEY，本地 key 隔离）"
}

# ---------- 健康检查 ----------
health_check() {
  step "健康检查"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[dry-run]${NC} curl http://127.0.0.1:$HOST_PORT$HEALTH_PATH (远程)"
    echo -e "${YELLOW}[dry-run]${NC} curl http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH (本地)"
    return
  fi

  log "等待容器启动..."
  sleep 4

  local remote_health="curl -fsS --max-time 5 http://127.0.0.1:$HOST_PORT$HEALTH_PATH || wget -qO- http://127.0.0.1:$HOST_PORT$HEALTH_PATH"
  if $SSH_BASE "$SERVER_USER@$SERVER_HOST" "$remote_health" 2>/dev/null | grep -q "OK"; then
    log "远程健康检查通过 ✓ (http://127.0.0.1:$HOST_PORT$HEALTH_PATH → OK)"
  else
    local ok=0
    for i in 1 2 3; do
      sleep 2
      if $SSH_BASE "$SERVER_USER@$SERVER_HOST" "$remote_health" 2>/dev/null | grep -q "OK"; then ok=1; break; fi
    done
    if [[ "$ok" == "1" ]]; then
      log "远程健康检查通过 ✓ (重试后成功)"
    else
      warn "远程健康检查未通过，可能是 CC_SERVER_KEY 校验失败导致容器启动即退出"
      warn "排查: $SSH_BASE $SERVER_USER@$SERVER_HOST 'docker logs $CONTAINER_NAME --tail 80; echo ---; docker ps -a --filter name=$CONTAINER_NAME'"
      $SSH_BASE "$SERVER_USER@$SERVER_HOST" "docker logs $CONTAINER_NAME --tail 50 2>&1; echo '---'; docker ps -a --filter name=$CONTAINER_NAME --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>&1 | sed 's/^/[remote] /' || true
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH" 2>/dev/null | grep -q "OK"; then
      log "公网健康检查通过 ✓ (http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH)"
    else
      warn "公网无法直接访问 http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH，可能是安全组/防火墙未放行 $HOST_PORT 端口"
      info "请检查: 云厂商安全组放行 $HOST_PORT/tcp，服务器防火墙: sudo ufw allow $HOST_PORT/tcp"
    fi
  fi
}

print_summary() {
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  部署完成！${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  镜像:     ${CYAN}$FULL_IMAGE${NC}"
  echo -e "  服务器:   ${CYAN}$SERVER_USER@$SERVER_HOST:$SERVER_SSH_PORT${NC}"
  echo -e "  容器:     ${CYAN}$CONTAINER_NAME${NC}  (端口 $HOST_PORT → $CONTAINER_PORT)"
  echo -e "  模式:     ${CYAN}服务器模式 (CC_SERVER_MODE=1, CC_SERVER_KEY=${CC_SERVER_KEY:0:12}...)${NC}"
  echo -e "  Key 隔离: ${CYAN}本地 keys 已排除，服务器 Key 仅环境变量注入${NC}"
  if [[ -n "$CC_SERVER_KEYS_FILE" ]]; then
    echo -e "  多 Key 池: ${CYAN}$CC_SERVER_KEYS_FILE → $REMOTE_DIR/$SERVER_KEYS_FILENAME${NC}"
  fi
  echo -e "  健康检查: ${CYAN}http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH${NC}"
  echo -e "  API 地址: ${CYAN}http://$SERVER_HOST:$HOST_PORT/v1${NC}"
  echo ""
  echo -e "  本地连接示例:"
  echo -e "    ${YELLOW}base_url=\"http://$SERVER_HOST:$HOST_PORT/v1\"${NC}"
  echo -e "    ${YELLOW}curl http://$SERVER_HOST:$HOST_PORT/v1/chat/completions -H \"Authorization: Bearer \$CC_SERVER_KEY\" ...${NC}"
  echo ""
  echo -e "  常用运维命令:"
  echo -e "    查看日志:  ${BLUE}ssh $SERVER_USER@$SERVER_HOST 'docker logs -f $CONTAINER_NAME'${NC}"
  echo -e "    健康检查:  ${BLUE}curl http://$SERVER_HOST:$HOST_PORT$HEALTH_PATH${NC}"
  echo -e "    验证隔离:  ${BLUE}ssh $SERVER_USER@$SERVER_HOST 'docker exec $CONTAINER_NAME cat /app/config.server.json | head'${NC}"
  echo -e "               ${BLUE}ssh $SERVER_USER@$SERVER_HOST 'docker exec $CONTAINER_NAME sh -c \"echo \\\$CC_SERVER_KEY | cut -c1-12\"'${NC} (应显示前缀)"
  echo ""
  warn "如需本地运行: npm start 或 docker compose up -d（本地模式不校验 key）"
  warn "生产环境建议: 用 Nginx/Caddy 加 HTTPS 反代"
  echo ""
}

main() {
  check_deps

  if [[ "$DEPLOY_ONLY" != "1" ]]; then
    build_image
  else
    log "跳过构建 (--deploy-only)"
  fi

  if [[ "$BUILD_ONLY" == "1" ]]; then
    log "仅构建模式完成，镜像: $FULL_IMAGE"
    log "提示: 镜像内不含本地 keys，已通过 .dockerignore 隔离"
    exit 0
  fi

  transfer_image
  remote_deploy
  health_check
  print_summary
}

main "$@"
