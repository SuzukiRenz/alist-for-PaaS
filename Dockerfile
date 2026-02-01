# 使用 alpine:edge 作为构建阶段的基础镜像
FROM alpine:edge as builder
LABEL stage=go-builder
WORKDIR /app/

# 安装必要的软件包
RUN apk add --no-cache bash curl jq gcc git go musl-dev

# 拉取远程仓库的代码
RUN git clone https://github.com/OpenListTeam/OpenList.git ./ && ls -la

# 使用 git 克隆下来的 go.mod 和 go.sum 文件
RUN go mod download

# 运行构建脚本
RUN bash build.sh release docker

############################################

# 使用 alpine:edge 作为最终镜像
FROM alpine:edge
USER root

ARG INSTALL_FFMPEG=false
# 定义构建参数，默认适配 PaaS 环境
ARG UID=1001
ARG GID=1001

# 设置工作目录
WORKDIR /opt/openlist/

# 安装必要的软件包
# 移除 unzip (因为新版 URL 是直接下载二进制)，保留 curl, ca-certificates
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache bash ca-certificates su-exec tzdata nginx supervisor curl jq && \
    [ "$INSTALL_FFMPEG" = "true" ] && apk add --no-cache ffmpeg; \
    rm -rf /var/cache/apk/* && \
    mkdir -p /var/run /var/log/nginx && \
    chown -R nginx:nginx /var/run /var/log/nginx && \
    chmod 777 /var/run /var/log/nginx

# 复制 Nginx 配置文件
COPY nginx.conf /etc/nginx/nginx.conf

# 从构建阶段复制构建好的二进制文件
# OpenList 编译出的文件名可能是 openlist，统一复制为 openlist
COPY --from=builder /app/bin/openlist ./openlist
COPY entrypoint.sh /entrypoint.sh

# 设置权限
RUN chmod +x /entrypoint.sh && \
    chmod +x ./openlist && \
    mkdir -p /opt/openlist/data && \
    chown -R ${UID}:${GID} /opt/openlist

# 设置环境变量
ENV PUID=0 PGID=0 UMASK=022

# 定义数据卷和暴露端口
VOLUME /opt/openlist/data/
EXPOSE 80

# 设置容器启动命令

CMD [ "/entrypoint.sh" ]
