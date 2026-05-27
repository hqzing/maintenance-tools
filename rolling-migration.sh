#!/bin/bash

# 记录连续失败的次数，防止网络彻底断开时死循环刷日志
FAILED_COUNT=0
MAX_FAILED=5

rm -rf formula-migration-tool
git clone https://atomgit.com/Harmonybrew/formula-migration-tool.git

echo "[INFO] 开始循环摇号搬运..."

while true; do
    echo "--------------------------------------------------"
    echo "[INFO] 正在摇号挑选软件包..."
    
    # 1. 运行 Python 脚本获取随机包名
    FORMULA=$(python3 random-get-formula.py)
    EXIT_CODE=$?

    # 2. 根据 Python 脚本的退出码进行状态处理
    if [ $EXIT_CODE -eq 1 ]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        echo "[ERROR] 上下游 API 获取失败 (当前连续失败 ${FAILED_COUNT}/${MAX_FAILED} 次)。" >&2
        
        if [ $FAILED_COUNT -ge $MAX_FAILED ]; then
            echo "[FATAL] 连续失败次数达到上限，退出当前任务。" >&2
            exit 1
        fi
        
        echo "[INFO] 30 秒后尝试重新摇号..."
        sleep 30
        continue  # 跳过本次循环，进入下一次摇号
        
    elif [ $EXIT_CODE -eq 2 ]; then
        echo "[INFO] 没有找到满足迁移条件的软件包（可能已全部迁移完成），任务安全结束。"
        exit 0  # 绿灯退出，结束当前矩阵任务
        
    elif [ $EXIT_CODE -ne 0 ]; then
        echo "[ERROR] Python 脚本发生未知异常退出，状态码: $EXIT_CODE。5 秒后重试..." >&2
        sleep 5
        continue
    fi

    # 3. 成功获取到包名，清空失败计数器
    FAILED_COUNT=0

    if [ -n "$FORMULA" ]; then
        echo "[INFO] 🎲 摇号成功！选中软件包: [ ${FORMULA} ]"
        echo "[INFO] 正在启动 Docker 容器进行搬运..."
        
        # 4. 执行 Docker 搬运任务
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

        echo "[INFO] 软件包 [ ${FORMULA} ] 搬运流程结束。5 秒后搬运下一个软件包..."
    else
        echo "[WARN] 未获取到有效的软件包名称，5 秒后重新摇号..." >&2
    fi

    sleep 5
done
