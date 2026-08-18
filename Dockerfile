FROM node:22-alpine
WORKDIR /app
# 本地/服务器两套配置同时打包，运行时由 CC_SERVER_MODE 决定读取哪套
COPY package.json proxy.mjs config.json config.server.json ./
EXPOSE 3050
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --spider http://127.0.0.1:3050/health || exit 1
# 服务器模式要求 CC_SERVER_MODE=1 + CC_SERVER_KEY=user_xxx，否则进程启动即失败（见 proxy.mjs）
CMD ["node", "proxy.mjs"]
