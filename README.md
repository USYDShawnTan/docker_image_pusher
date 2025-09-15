# Docker Images Pusher（按官方标签同步）

使用 GitHub Actions 将上游 Docker 镜像按“官方标签”同步到阿里云容器镜像服务（ACR），适合国内环境快速拉取。

- 支持 DockerHub / GHCR / GCR / k8s.gcr.io 等
- 支持多架构（manifest list 原样复制）
- 增量同步：digest 未变则跳过
- 保留官方版本号标签（不再使用时间戳标签）

作者：**[技术爬爬虾](https://github.com/tech-shrimp/me)**

## 快速开始

### 1) 配置 ACR 相关 Secrets
在仓库 Settings -> Secrets and variables -> Actions 中新增：
- `ALIYUN_REGISTRY`（如：`registry.cn-hangzhou.aliyuncs.com`）
- `ALIYUN_NAME_SPACE`（你的命名空间）
- `ALIYUN_REGISTRY_USER`
- `ALIYUN_REGISTRY_PASSWORD`

### 2) 添加需要同步的上游镜像
编辑 `images.txt`，每行一个仓库（无需写 `:latest`）：
- `adguard/adguardhome`
- `ghcr.io/org/app`

支持 `#` 注释；可在行尾添加 `--platform=...` 仅作备注（同步使用 `--all`，一般无需指定）。

### 3) 触发同步
- 提交对 `images.txt` 的修改，或在 Actions 手动运行，或等待定时任务。

## 同步策略

默认：`TAG_POLICY=semver_with_latest`（语义化版本 + latest）。
可选：
- `all`：同步所有标签
- `semver`：仅语义化版本（支持 `v` 前缀、预发布与构建元数据）
- `semver_with_latest`：语义化版本 + latest（默认）
- `latest_only`：仅 latest
- `recent_N`：最近 N 个标签（配合 `RECENT_N`，默认 50）

多架构：`skopeo copy --all` 原样复制 manifest list。

重名处理：不同上游命名空间下存在同名镜像时，目标仓库名自动加前缀（如 `org_adguardhome`），并统一小写。

## 使用镜像

在目标环境拉取：
```
docker pull ${ALIYUN_REGISTRY}/${ALIYUN_NAME_SPACE}/adguardhome:latest
```

当上游 `latest` 发生变更时，ACR 中的 `latest` digest 跟随更新。Watchtower 或 `docker compose up -d --pull always` 可自动检测并更新。

## 工作流设置

在 `.github/workflows/docker.yaml` 中可调整：
- `TAG_POLICY` 与 `RECENT_N`
- `schedule.cron`（默认每天 23:00 UTC）

## 常见问题

1) 推送被拒绝：确保 ACR 有对应仓库（或开启自动创建）并校验四个 Secrets。
2) 只同步 latest：将 `TAG_POLICY` 设为 `latest_only`。
3) 仅同步指定标签：需要“逐行精确同步”模式，可提 Issue 我来扩展。
