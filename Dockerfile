FROM node:22-alpine AS frontend-builder

WORKDIR /app/admin-ui
COPY admin-ui/package.json admin-ui/pnpm-lock.yaml admin-ui/.npmrc admin-ui/pnpm-workspace.yaml ./
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile
COPY admin-ui ./
RUN pnpm build

# ─── Rust 构建：用 cargo-chef 缓存依赖 ───
#
# 三段式构建：
# 1. chef-planner：生成 recipe.json（项目依赖清单）
# 2. chef-cooker：根据 recipe 单独编译所有依赖（最耗时，但缓存命中后跳过）
# 3. builder：拿编好的依赖 + 项目源码，只编 kiro-rs 自己
#
# 改 src 后只重跑步骤 3（30 秒-1 分钟），不重跑步骤 2（15+ 分钟）
# 改 Cargo.toml 加依赖时，步骤 2 重跑但已编依赖仍能复用

FROM rust:1.92-alpine AS chef
RUN apk add --no-cache musl-dev perl make
RUN cargo install cargo-chef --locked
WORKDIR /app

FROM chef AS chef-planner
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS chef-cooker
COPY --from=chef-planner /app/recipe.json recipe.json
# 这一步只用 recipe.json，不依赖 src/，缓存极稳定
RUN cargo chef cook --release --no-default-features --recipe-path recipe.json

FROM chef AS builder
# 复用已编译的依赖（来自 chef-cooker 的 target/）
COPY --from=chef-cooker /app/target target
COPY --from=chef-cooker /usr/local/cargo /usr/local/cargo
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
COPY --from=frontend-builder /app/admin-ui/dist /app/admin-ui/dist
# 只编 kiro-rs 自己（所有依赖已经编好）
RUN cargo build --release --no-default-features

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/target/release/kiro-rs /app/kiro-rs
VOLUME ["/app/config"]
EXPOSE 8990
CMD ["./kiro-rs", "-c", "/app/config/config.json", "--credentials", "/app/config/credentials.json"]
