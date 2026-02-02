#!/bin/bash

# --- 环境变量设置 ---
export PUID=${PUID:-'1001'}
export PGID=${PGID:-'1001'}
export UMASK=${UMASK:-'022'}

# Komari/Nezha 变量
export KOMARI_HOST=${KOMARI_HOST:-${NEZHA_SERVER:-''}}
export KOMARI_TOKEN=${KOMARI_TOKEN:-${NEZHA_KEY:-''}}
export KOMARI_ARGS=${KOMARI_ARGS:-''}
# Komari 版本号
export KOMARI_VERSION=${KOMARI_VERSION:-'1.1.40'}

# 配置文件路径
SUPERVISORD_CONFIG_PATH="/etc/supervisord.conf"
AGENT_DIR="/opt/komari"
AGENT_BIN="$AGENT_DIR/komari-agent"

########################################################################################
# 1. 官方 Openlist 权限检查逻辑
########################################################################################

umask ${UMASK}

if [ -d ./data ]; then
  # 简单检查数据目录
  echo "Checking data directory permissions..."
fi

# Aria2 目录处理 (如果启用)
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

prepare_komari() {
    # 核心判断：如果没有设置 HOST 或 TOKEN，直接返回 1 (失败/跳过)
    if [ -z "$KOMARI_HOST" ] || [ -z "$KOMARI_TOKEN" ]; then
        echo "Komari: 未检测到环境变量，跳过部署。"
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

    # 构建下载链接 (直接下载二进制)
    DOWNLOAD_URL="https://github.com/komari-monitor/komari-agent/releases/download/${KOMARI_VERSION}/komari-agent-linux-${FILE_ARCH}"
    
    echo "Komari: 正在下载 Agent (${KOMARI_VERSION} - ${FILE_ARCH})..."
    
    # 使用 curl 下载
    if curl -L -o "$AGENT_BIN" "$DOWNLOAD_URL"; then
        chmod +x "$AGENT_BIN"
        echo "Komari: 下载成功。"
        return 0
    else
        echo "Komari: 下载失败，请检查网络。"
        rm -f "$AGENT_BIN"
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

[program:openlist]
directory=/opt/openlist
command=su-exec ${PUID}:${PGID} ./openlist server --no-prefix
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# Aria2 配置
if [ "$RUN_ARIA2" = "true" ] && command -v aria2c >/dev/null 2>&1; then
    cat >> ${SUPERVISORD_CONFIG_PATH} << EOF
[program:aria2]
command=aria2c --conf-path=/opt/openlist/data/aria2.conf
autorestart=true
user=$(whoami)
EOF
fi

# Komari 配置
prepare_komari
if [ $? -eq 0 ] && [ -f "$AGENT_BIN" ]; then
    
    # --- 核心修复：URL 处理逻辑 ---
    # 1. 移除尾部斜杠
    FINAL_HOST=${KOMARI_HOST%/}
    
    # 2. 检查是否包含协议头，如果没有，默认添加 http:// (为了防止 unsupported protocol scheme 报错)
    #    虽然 komari.eee.top 应该是 https，但如果用户没写，我们先补个协议让它能跑起来
    if [[ "$FINAL_HOST" != http://* ]] && [[ "$FINAL_HOST" != https://* ]]; then
        echo "Komari: 检测到 URL 未包含协议头，自动添加 http://"
        FINAL_HOST="http://${FINAL_HOST}"
    fi

    # 3. TLS 标志检测 (如果 URL 是 https，通常不需要额外指定 --tls，除非是 grpc 模式，但保留逻辑无害)
    TLS_FLAG=""
    if [[ "$FINAL_HOST" == https* ]]; then
        TLS_FLAG=""
    fi
    
    echo "配置 Komari Agent (Endpoint: $FINAL_HOST)..."

    cat >> ${SUPERVISORD_CONFIG_PATH} << EOF

[program:komari-agent]
directory=${AGENT_DIR}
command=${AGENT_BIN} -e ${FINAL_HOST} -t ${KOMARI_TOKEN} ${KOMARI_ARGS}
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
fi

########################################################################################
# 4. 启动
########################################################################################

# 修正 ID 以兼容脚本
if [ -f /etc/os-release ]; then
    sed -i "s/^ID=.*/ID=alpine/" /etc/os-release 2>/dev/null || true
fi

# 确保权限
chown -R ${PUID}:${PGID} /opt/openlist/data

if [ "$1" = "version" ]; then
  ./openlist version
else
  echo "启动服务..."
  exec supervisord -n -c ${SUPERVISORD_CONFIG_PATH}
fi
