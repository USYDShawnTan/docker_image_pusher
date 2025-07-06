# 更新日志

## 2025-07-06 - 强制更新 latest 镜像 (方案2)

### 问题描述
原有的脚本在转存 `latest` 镜像时，由于 Docker 缓存和 digest 相同，`docker compose up -d --pull always` 无法感知到镜像的变化，导致无法自动更新到最新版本。

### 解决方案
采用**强制覆盖 latest 标签**的策略，确保每次推送都会改变 `latest` 标签的 digest：

1. **强制覆盖策略**：直接用新的镜像内容覆盖 `latest` 标签
2. **时间戳备份**：同时创建时间戳标签作为备份，便于版本追踪
3. **自动更新支持**：完全兼容 `docker compose up -d --pull always`

### 核心改进

#### 工作原理
- 对于 `latest` 镜像：先推送时间戳备份标签，再强制覆盖 `latest` 标签
- 对于非 `latest` 镜像：保持原有逻辑不变
- 每次推送都会改变 `latest` 标签的 digest，Docker 能检测到变化

#### 标签命名规则
- 主要标签：`registry/namespace/image:latest`（每次都会被覆盖）
- 备份标签：`registry/namespace/image:20250706-142530`（用于版本追踪）

#### 自动更新支持
✅ **完全支持** `docker compose up -d --pull always`
- 无需修改 docker-compose.yml 文件
- 无需更改现有的部署脚本
- 保持使用 `latest` 标签的习惯

### 使用方式

#### Docker Compose 文件
```yaml
services:
  adguard:
    image: registry.cn-hangzhou.aliyuncs.com/your-namespace/adguardhome:latest
```

#### 自动更新命令
```bash
# 这个命令现在会自动检测并拉取最新的镜像
docker compose up -d --pull always
```

#### 手动版本控制
```bash
# 如果需要回滚到特定版本，可以使用时间戳标签
docker pull registry.cn-hangzhou.aliyuncs.com/your-namespace/adguardhome:20250706-142530
```

### 示例
假设转存 `adguard/adguardhome:latest`：
1. 首先推送：`registry.cn-hangzhou.aliyuncs.com/your-namespace/adguardhome:20250706-142530`
2. 然后覆盖：`registry.cn-hangzhou.aliyuncs.com/your-namespace/adguardhome:latest`

每次运行后，`latest` 标签都会指向最新的镜像内容，digest 发生变化。

### 通知改进
- Telegram 通知会明确显示"强制更新成功"
- 显示 latest 标签和时间戳备份标签
- 提醒用户现在可以使用 `docker compose up -d --pull always`

### 优势
1. **零配置更新**：无需修改任何现有配置
2. **完全兼容**：与 Docker Compose 的 `--pull always` 完美配合
3. **版本追踪**：时间戳标签提供版本历史
4. **强制刷新**：确保每次都能检测到更新

### 注意事项
1. 只有 `latest` 标签会被强制覆盖
2. 时间戳标签作为备份，便于版本管理和回滚
3. 非 `latest` 镜像的行为保持不变
4. 推送成功后，`docker compose up -d --pull always` 会自动工作
- 现在会同时清理原始标签和时间戳标签的镜像
- 确保磁盘空间得到充分释放

### 注意事项
1. 只有 `latest` 标签的镜像会创建时间戳标签
2. 时间戳使用 UTC 时间，确保全球一致性
3. 如果只有其中一个标签推送成功，仍会发送成功通知
4. 镜像清理会处理所有创建的标签
