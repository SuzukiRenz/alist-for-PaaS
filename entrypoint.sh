#!/bin/bash

# --- 环境变量设置 ---
export PUID=${PUID:-'1001'}
export PGID=${PGID:-'1001'}
export UMASK=${UMASK:-'022'}

# Komari/Nezha 变量
# 兼容 PaaS 常用变量名 (-e KOMARI_HOST -t KOMARI_TOKEN) 以及 Nezha 原生变量名
export KOMARI_HOST=${KOMARI_HOST:-${NEZHA_SERVER:-''}}
export KOMARI_TOKEN=${KOMARI_TOKEN:-${NEZHA_KEY:-''}}
export KOMARI_ARGS=${KOMARI_ARGS:-'--disable-command-execute --disable-auto-update'}
# 定义版本号，方便日后维护
export KOMARI_VERSION=${KOMARI_VERSION:-'1.1.40'}

# 配置文件路径
SUPERVISORD_CONFIG_PATH="/etc/supervisord.conf"
AGENT_DIR="/opt/komari"
AGENT_BIN="$AGENT_DIR/komari-agent"

########################################################################################
# 1. 官方 Openlist 权限检查逻辑 (融合自官方 entrypoint.sh)
########################################################################################

umask ${UMASK}

if [ -d ./data ]; then
  # 简单检查数据目录
  echo "Checking data directory permissions..."
fi

# Aria2 目录处理 (官方逻辑)
ARIA2_DIR="/opt/service/start/aria2"
if [ "$RUN_ARIA2" = "true" ]; then
  if [ ! -d "$ARIA2_DIR" ]; then
    mkdir -p "$ARIA2_DIR"
    if [ -d "/opt/service/stop/aria2" ]; then
        cp -r /opt/service/stop/aria2/* "$ARIA2_DIR" 2>/dev/null
    fi
  fi
fi

########################################################################################
# 2. Komari (Nezha) Agent 安装与配置逻辑
########################################################################################

# 辅助函数：处理地址
get_safe_addr() {
    local addr=$1
    addr=${addr#http://}
    addr=${addr#https://}
    addr=${addr%/}
    echo "$addr"
}

prepare_komari() {
    # 核心判断：如果没有设置 HOST 或 TOKEN，直接返回，不做任何操作
    if [ -z "$KOMARI_HOST" ] || [ -z "$KOMARI_TOKEN" ]; then
        echo "Komari: 未检测到 KOMARI_HOST 或 KOMARI_TOKEN 环境变量，跳过 Komari 部署流程。"
        return 1
    fi

    # 创建目录
    if [ ! -d "$AGENT_DIR" ]; then
        mkdir -p "$AGENT_DIR"
    fi

    # 检查是否已存在
    if [ -f "$AGENT_BIN" ]; then
        echo "Komari: Agent 文件已存在，跳过下载。"
        return 0
    fi

    echo "Komari: 正在检测系统架构..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FILE_ARCH="amd64" ;;
        aarch64) FILE_ARCH="arm64" ;;
        *) echo "Komari: 不支持的架构 $ARCH，跳过下载。"; return 1 ;;
    esac

    # 构建下载链接 (直接下载二进制文件)
    DOWNLOAD_URL="https://github.com/komari-monitor/komari-agent/releases/download/${KOMARI_VERSION}/komari-agent-linux-${FILE_ARCH}"
    
    echo "Komari: 正在下载 Agent (${KOMARI_VERSION} - ${FILE_ARCH})..."
    echo "URL: $DOWNLOAD_URL"
    
    # 使用 curl 下载并重命名
    if curl -L -o "$AGENT_BIN" "$DOWNLOAD_URL"; then
        chmod +x "$AGENT_BIN"
        echo "Komari: 下载并赋权成功。"
        return 0
    else
        echo "Komari: 下载失败，请检查网络连接。"
        rm -f "$AGENT_BIN" # 清理失败的残留文件
        return 1
    fi
}

########################################################################################
# 3. 生成 Supervisord 配置
########################################################################################

echo "生成 Supervisord 配置文件..."

cat > ${SUPERVISORD_CONFIG_PATH} << EOF
[supervisord]
nodaemon=true
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid
user=root

[program:nginx]
command=nginx -g 'daemon off;'
autorestart=true
# Nginx Master 进程需要 root 权限

[program:openlist]
directory=/opt/openlist
command=su-exec ${PUID}:${PGID} ./openlist server --no-prefix
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# 如果 Aria2 启用，添加到 Supervisor
if [ "$RUN_ARIA2" = "true" ] && command -v aria2c >/dev/null 2>&1; then
    cat >> ${SUPERVISORD_CONFIG_PATH} << EOF
[program:aria2]
command=aria2c --conf-path=/opt/openlist/data/aria2.conf
autorestart=true
user=$(whoami)
EOF
fi

# 尝试准备 Komari，如果成功 (返回 0)，则添加配置
prepare_komari
if [ $? -eq 0 ] && [ -f "$AGENT_BIN" ]; then
    SAFE_HOST=$(get_safe_addr "$KOMARI_HOST")
    
    # 简单的 TLS 判断逻辑
    TLS_FLAG=""
    if [[ "$KOMARI_HOST" == https* ]]; then
        TLS_FLAG="--tls"
    fi
    
    echo "配置 Komari Agent: Server=$SAFE_HOST $TLS_FLAG"

    cat >> ${SUPERVISORD_CONFIG_PATH} << EOF

[program:komari-agent]
directory=${AGENT_DIR}
command=${AGENT_BIN} -s ${SAFE_HOST} -p ${KOMARI_TOKEN} ${TLS_FLAG} ${KOMARI_ARGS}
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
fi

########################################################################################
# 4. 系统信息修正 (User 原有逻辑)
########################################################################################

if [ -f /etc/os-release ]; then
    sed -i "s/^ID=.*/ID=alpine/" /etc/os-release 2>/dev/null || true
fi

########################################################################################
# 5. 启动
########################################################################################

chown -R ${PUID}:${PGID} /opt/openlist/data

if [ "$1" = "version" ]; then
  ./openlist version
else
  echo "启动 Supervisord 管理所有服务..."
  exec supervisord -n -c ${SUPERVISORD_CONFIG_PATH}
fi