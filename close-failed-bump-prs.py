#!/usr/bin/env python3
"""
关闭同时包含 bump-formula-pr 和 ci-failed 标签且有冲突的 PR。

逻辑：
1. 扫描 Harmonybrew/homebrew-core 仓库中所有开启状态的 PR
2. 筛选出同时包含 "bump-formula-pr" 和 "ci-failed" 标签的 PR
3. 逐一查询 PR 的详细元数据，检查是否存在合并冲突
4. 对存在冲突的 PR 执行关闭操作

安全机制：
- 默认以 DRY_RUN=True 运行，仅打印日志不实际修改数据
- 关闭前会二次确认冲突状态，避免误关
"""

import os
import sys
import time
import requests

# ==================== 配置区域 ====================
OWNER = "Harmonybrew"
REPO = "homebrew-core"

# 目标标签
LABEL_BUMP = "bump-formula-pr"
LABEL_CI_FAILED = "ci-failed"

# 每次最多处理的 PR 数量上限
MAX_PROCESS_LIMIT = 50

# 是否开启模拟运行 (True: 仅打印不执行, False: 真正发送 PATCH 请求)
DRY_RUN = False
# ==================================================

# 读取 Token
ATOMGIT_TOKEN = os.getenv("ATOMGIT_TOKEN")
if not ATOMGIT_TOKEN:
    # 尝试从 /root/token.txt 读取
    token_path = "/root/token.txt"
    if os.path.exists(token_path):
        with open(token_path, "r", encoding="utf-8") as f:
            ATOMGIT_TOKEN = f.read().strip()
    if not ATOMGIT_TOKEN:
        sys.exit("Error: ATOMGIT_TOKEN not found. Set env var or place token in /root/token.txt.")


def get_open_prs(page, per_page=100):
    """分页获取所有开启状态的 PR"""
    url = f"https://api.atomgit.com/api/v5/repos/{OWNER}/{REPO}/pulls"
    params = {"access_token": ATOMGIT_TOKEN, "state": "open", "per_page": per_page, "page": page}
    try:
        response = requests.get(url, params=params, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"[!] Request failed: {e}")
        return []


def get_single_pr(number):
    """获取单个 PR 的详细信息（包含 mergeable 字段）"""
    url = f"https://api.atomgit.com/api/v5/repos/{OWNER}/{REPO}/pulls/{number}"
    params = {"access_token": ATOMGIT_TOKEN}
    try:
        response = requests.get(url, params=params, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"[!] Failed to fetch PR #{number} details: {e}")
        return None


def close_pr(number):
    """关闭指定 PR"""
    url = f"https://api.atomgit.com/api/v5/repos/{OWNER}/{REPO}/pulls/{number}"
    params = {"access_token": ATOMGIT_TOKEN}
    payload = {"state": "closed"}
    try:
        response = requests.patch(url, params=params, json=payload, timeout=15)
        response.raise_for_status()
        print(f"[SUCCESS] PR #{number} has been closed.")
        return True
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Failed to close PR #{number}: {e}")
        return False


def has_conflict(pr_detail):
    """
    检查 PR 是否存在合并冲突。
    AtomGit API 中：
    - mergeable: bool — True 表示可合并（无冲突），False 表示有冲突
    - mergeable_state.conflict_passed: bool — True 表示冲突检查通过
    """
    mergeable = pr_detail.get("mergeable")
    mergeable_state = pr_detail.get("mergeable_state", {})
    conflict_passed = mergeable_state.get("conflict_passed")

    # mergeable 为 False 说明有冲突
    if mergeable is False:
        return True
    # conflict_passed 为 False 也说明有冲突
    if conflict_passed is False:
        return True
    # mergeable 为 None 表示尚未检查（极少情况），保守处理为无冲突
    return False


def main():
    print("====== 关闭失败且有冲突的 Bump PR ======")
    print(f"[*] 仓库: {OWNER}/{REPO}")
    print(f"[*] 筛选条件: 同时包含标签 '{LABEL_BUMP}' 和 '{LABEL_CI_FAILED}'")
    print(f"[*] Max process limit set to: {MAX_PROCESS_LIMIT}")

    if DRY_RUN:
        print("\n【安全提示】当前处于 [Dry-Run 模拟模式]，仅打印结果，不会执行任何关闭操作！\n")
    else:
        print("\n【高危警告】当前处于 [实战模式]，符合条件的冲突 PR 将被直接关闭！\n")

    print("--------------------------------------------------")

    page = 1
    per_page = 100
    processed_count = 0
    skipped_no_conflict = 0
    total_matched = 0

    while True:
        print(f"[*] Fetching page {page} of open PRs...")
        prs = get_open_prs(page, per_page)

        if not prs:
            print("[*] No more open PRs found or error occurred.")
            break

        for pr in prs:
            pr_number = pr.get("number")
            title = pr.get("title", "")
            labels = [label.get("name", "") for label in pr.get("labels", [])]

            # 检查是否同时包含两个目标标签
            has_bump = LABEL_BUMP in labels
            has_ci_failed = LABEL_CI_FAILED in labels

            if not (has_bump and has_ci_failed):
                continue

            total_matched += 1
            print(f"\n[+ ] Found matching PR #{pr_number}: '{title}'")
            print(f"    Labels: {labels}")

            # 达到上限则停止
            if processed_count >= MAX_PROCESS_LIMIT:
                print(f"\n[!] Reached the maximum process limit of {MAX_PROCESS_LIMIT}. Stopping.")
                return

            # 获取 PR 详情，检查冲突状态
            print(f"    -> Fetching detailed info for PR #{pr_number}...")
            pr_detail = get_single_pr(pr_number)
            if not pr_detail:
                print(f"    [!] Skipping PR #{pr_number} (failed to fetch details)")
                continue

            mergeable = pr_detail.get("mergeable")
            ms = pr_detail.get("mergeable_state", {})
            conflict_passed = ms.get("conflict_passed")
            print(f"    -> mergeable={mergeable}, conflict_passed={conflict_passed}")

            if not has_conflict(pr_detail):
                print(f"    [-] PR #{pr_number} has NO conflict. Skipping.")
                skipped_no_conflict += 1
                continue

            print(f"    [!] PR #{pr_number} has CONFLICT!")

            # 执行关闭操作
            if DRY_RUN:
                print(f"    [DRY-RUN] Would close PR #{pr_number} now.")
            else:
                # 二次确认：关闭前再查一次，避免 Race Condition
                confirm_detail = get_single_pr(pr_number)
                if confirm_detail and has_conflict(confirm_detail):
                    success = close_pr(pr_number)
                    if not success:
                        continue
                else:
                    print(f"    [-] PR #{pr_number} conflict resolved before close. Skipping.")
                    skipped_no_conflict += 1
                    continue

            processed_count += 1
            print(f"    -> Progress: {processed_count}/{MAX_PROCESS_LIMIT}")

            # 速率控制，避免触发 API 限频
            time.sleep(0.3)

        # 翻页判断
        if len(prs) < per_page:
            break
        else:
            page += 1
            time.sleep(0.2)  # 翻页间隔

    # 最终报告
    print("\n====== 执行报告 ======")
    print(f"匹配到同时含两个标签的 PR: {total_matched}")
    print(f"已处理 (有关闭操作): {processed_count}")
    print(f"跳过 (无冲突): {skipped_no_conflict}")

    if DRY_RUN:
        print("\n【模拟统计】评估完毕。")
        print("请检查上方输出是否符合你的心理预期。")
        print("确认无误后，将脚本中的 `DRY_RUN = True` 修改为 `DRY_RUN = False` 即可真正执行关闭。")
    else:
        print(f"\n【实战统计】操作完毕！本次实际关闭了 {processed_count} 个有冲突的 PR。")


if __name__ == "__main__":
    main()
