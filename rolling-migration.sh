#!/bin/bash

# ============================================================
# 黑名单 / Release 配置
# ============================================================
BLACKLIST_FILE="blacklist.txt"
RELEASE_TAG="build-blacklist"
REPO="hqzing/maintenance-tools"

# ============================================================
# 1. 确保 gh CLI 可用（GitHub Actions arm64 runner 预装了 gh，
#    这里作为兜底，不存在则自动下载 linux-arm64 版本）
# ============================================================
ensure_gh() {
    if command -v gh &>/dev/null; then
        return 0
    fi
    echo "[INFO] gh CLI not found, downloading linux-arm64 version..."
    local GH_VERSION="2.64.0"
    curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz" \
        -o /tmp/gh.tar.gz
    tar xzf /tmp/gh.tar.gz -C /tmp
    export PATH="/tmp/gh_${GH_VERSION}_linux_arm64/bin:$PATH"
    if ! command -v gh &>/dev/null; then
        echo "[FATAL] Failed to install gh CLI." >&2
        exit 1
    fi
    echo "[INFO] gh CLI installed successfully."
}
ensure_gh

# ============================================================
# 2. 确保 Release 存在，并下载最新的黑名单
# ============================================================
ensure_release() {
    if ! gh release view "$RELEASE_TAG" --repo "$REPO" &>/dev/null; then
        echo "[INFO] Release '${RELEASE_TAG}' 不存在，正在创建..."
        gh release create "$RELEASE_TAG" \
            --repo "$REPO" \
            --title "构建失败黑名单" \
            --notes "自动记录构建失败的软件包，避免重复建设。" \
            2>/dev/null
        # 创建空的 blacklist.txt 并上传作为占位
        touch "$BLACKLIST_FILE"
        gh release upload "$RELEASE_TAG" "$BLACKLIST_FILE" \
            --repo "$REPO" --clobber 2>/dev/null
    fi
}

download_blacklist() {
    ensure_release
    echo "[INFO] 下载最新黑名单..."
    if ! gh release download "$RELEASE_TAG" \
        --pattern "$BLACKLIST_FILE" \
        --repo "$REPO" \
        --output "$BLACKLIST_FILE" 2>/dev/null; then
        echo "[WARN] 下载黑名单失败，使用空黑名单。"
        touch "$BLACKLIST_FILE"
    fi
    local COUNT
    COUNT=$(wc -l < "$BLACKLIST_FILE")
    echo "[INFO] 当前黑名单条目数: ${COUNT}"
}

upload_blacklist() {
    ensure_release
    echo "[INFO] 上传更新后的黑名单到 Release..."
    gh release upload "$RELEASE_TAG" "$BLACKLIST_FILE" \
        --repo "$REPO" --clobber 2>/dev/null
}

# 判断包名是否已在黑名单中
is_blacklisted() {
    local formula="$1"
    grep -Fx "$formula" "$BLACKLIST_FILE" &>/dev/null
}

# 原子化同步黑名单：下载最新 → 追加 → 上传 → 验证重试
# 解决 18 个并行 job 间的竞态覆盖问题
sync_add_to_blacklist() {
    local formula="$1"
    local max_retry=10
    local retry=0

    while [ $retry -lt $max_retry ]; do
        retry=$((retry + 1))

        # 1) 下载最新的黑名单（从 Release 拉取其他并行 job 已写入的条目）
        download_blacklist

        # 2) 如果已经被其他 job 写入了，直接成功
        if is_blacklisted "$formula"; then
            echo "[INFO] ✅ [ ${formula} ] 已被其他并行任务加入黑名单，跳过。"
            return 0
        fi

        # 3) 追加并去重
        echo "$formula" >> "$BLACKLIST_FILE"
        sort -u -o "$BLACKLIST_FILE" "$BLACKLIST_FILE"

        # 4) 上传覆盖 Release 资产
        upload_blacklist

        # 5) 验证：重新下载，确认我们的条目确实在 Release 中了
        local tmp_file
        tmp_file=$(mktemp)
        if gh release download "$RELEASE_TAG" \
            --pattern "$BLACKLIST_FILE" \
            --repo "$REPO" \
            --output "$tmp_file" 2>/dev/null; then
            if grep -Fx "$formula" "$tmp_file" &>/dev/null; then
                rm -f "$tmp_file"
                echo "[INFO] ✅ [ ${formula} ] 已成功写入黑名单并验证通过。"
                return 0
            fi
        fi
        rm -f "$tmp_file"

        echo "[WARN] 黑名单上传可能被其他并行任务覆盖，正在重试 (${retry}/${max_retry})..."
        sleep 1
    done

    echo "[ERROR] ❌ 黑名单同步失败 (${formula})，已重试 ${max_retry} 次。" >&2
    return 1
}

# ============================================================
# 3. 启动时下载黑名单
# ============================================================
download_blacklist

# ============================================================
# 4. 准备 formula-migration-tool 仓库
# ============================================================
rm -rf formula-migration-tool
git clone https://atomgit.com/Harmonybrew/formula-migration-tool.git
cd formula-migration-tool
git reset --hard 4428a7b349b0b78dec3e82688393c78471de236d
cd ../

# ============================================================
# 5. 主循环：摇号 → 跳过黑名单 → 搬运 → 失败则拉黑
# ============================================================
# 记录连续失败的次数，防止网络彻底断开时死循环刷日志
FAILED_COUNT=0
MAX_FAILED=5

echo "[INFO] 开始循环摇号搬运..."

while true; do
    echo "--------------------------------------------------"
    echo "[INFO] 正在摇号挑选软件包..."

    # 5a. 运行 Python 脚本获取随机包名
    FORMULA=$(python3 random-get-formula.py)
    EXIT_CODE=$?

    # 5b. 根据 Python 脚本的退出码进行状态处理
    if [ $EXIT_CODE -eq 1 ]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "[ERROR] 上下游 API 获取失败 (当前连续失败 ${FAILED_COUNT}/${MAX_FAILED} 次)。" >&2

        if [ $FAILED_COUNT -ge $MAX_FAILED ]; then
            echo "[FATAL] 连续失败次数达到上限，退出当前任务。" >&2
            exit 1
        fi

        echo "[INFO] 30 秒后尝试重新摇号..."
        sleep 30
        continue

    elif [ $EXIT_CODE -eq 2 ]; then
        echo "[INFO] 没有找到满足迁移条件的软件包（可能已全部迁移完成），任务安全结束。"
        exit 0

    elif [ $EXIT_CODE -ne 0 ]; then
        echo "[ERROR] Python 脚本发生未知异常退出，状态码: $EXIT_CODE。5 秒后重试..." >&2
        sleep 5
        continue
    fi

    # 5c. 成功获取到包名，清空失败计数器
    FAILED_COUNT=0

    if [ -z "$FORMULA" ]; then
        echo "[WARN] 未获取到有效的软件包名称，5 秒后重新摇号..." >&2
        sleep 5
        continue
    fi

    # 5d. 检查是否在黑名单中
    if is_blacklisted "$FORMULA"; then
        echo "[INFO] ⛔ [ ${FORMULA} ] 在黑名单中，跳过。"
        sleep 2
        continue
    fi

    echo "[INFO] 🎲 摇号成功！选中软件包: [ ${FORMULA} ]"
    echo "[INFO] 正在启动 Docker 容器进行搬运..."

    # 5e. 执行 Docker 搬运任务
    # 这里不要加 -it 参数，因为在 GitHub Actions 等非交互式环境中 -it 会报错
    docker run \
      --rm \
      -v "$PWD"/formula-migration-tool:/workdir \
      -w /workdir \
      -e ATOMGIT_TOKEN="$ATOMGIT_TOKEN" \
      -e ATOMGIT_USER="$ATOMGIT_USER" \
      -e ATOMGIT_EMAIL="$ATOMGIT_EMAIL" \
      swr.cn-north-4.myhuaweicloud.com/harmonybrew/ci-runner:latest \
      python3 auto-migrate.py "$FORMULA"

    DOCKER_EXIT=$?

    # 5f. 检查搬运结果：失败则拉黑并上传
    if [ $DOCKER_EXIT -ne 0 ]; then
        echo "[ERROR] ❌ 软件包 [ ${FORMULA} ] 构建失败（退出码: ${DOCKER_EXIT}），正在同步加入黑名单..."
        sync_add_to_blacklist "$FORMULA"
    else
        echo "[INFO] ✅ 软件包 [ ${FORMULA} ] 构建成功！"
    fi

    echo "[INFO] 软件包 [ ${FORMULA} ] 搬运流程结束。5 秒后搬运下一个软件包..."
    sleep 5
done
