# 两段构建：前面用 Node 打前端和后端，最后只把产物装进运行层。
#
# 构建上下文是仓库根（compose 里写了 context: .），
# 因为前端产物 parent-web/dist 必须和 server/ 一起进镜像。

# ---------- 1. 前端 ----------
FROM node:22-alpine AS web
WORKDIR /w

# package-lock 的 resolved 全部指向 npmmirror，容器内不需要额外配源
COPY parent-web/package*.json ./
RUN npm ci

COPY parent-web/ ./
# 这一步包含 tsc --noEmit，类型错会让整个镜像构建失败 —— 这是刻意的
RUN npm run build

# ---------- 2. 后端编译 ----------
FROM node:22-alpine AS server-build
WORKDIR /app
COPY server/package*.json ./
RUN npm ci
COPY server/tsconfig.json ./
COPY server/src ./src
RUN npm run build

# ---------- 3. 运行 ----------
FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    PORT=8787 \
    DATA_DIR=/data

# 只要生产依赖，devDependencies 不进最终镜像
COPY server/package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=server-build /app/dist ./dist
COPY --from=web /w/dist ./public
COPY server/migrations ./migrations

# 构建上下文来自 NAS 共享盘/网络文件系统时，文件 mode 可能被抹成 000，
# COPY 会原样带进镜像，运行时 node 用户直接 EACCES 读不到迁移脚本。
# 这里统一补一次只读位，不依赖源文件系统的权限表现。
RUN chmod -R a+rX /app

# 上传目录由卷挂进来，先建好并交出属主，避免 node 用户没权限写
RUN mkdir -p /data/uploads && chown -R node:node /data

USER node
EXPOSE 8787

# 迁移在启动时跑（幂等），失败则容器直接退出并由 restart 策略重试
CMD ["node", "dist/main.js"]
