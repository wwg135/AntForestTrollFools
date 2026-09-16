#!/bin/sh
# v3.5.6 「做任务」端满仓闸门自检（3 段）
# 背景：领取端早有满仓闸门（存量+本次奖励>上限 ⇒ 挂起），但**做任务端没有** ⇒ 满仓时照样完成任务，
#      只会挂出「待领奖励」且可能过期作废（9/16 用户口径：满 1800g 就先不做，等消耗再做）。
# 守则：取值口径与领取闸门逐字一致；只对饲料奖励(ALLPURPOSE)生效（菜谱不占饲料上限）；60 秒节流。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/3] 做任务端闸门存在（存量+本次奖励 > 上限 ⇒ 暂停做任务）"
grep -q 'if (isFoodAward && taskStockLimit > 0 && taskStock + award > taskStockLimit) {' "$M" && ok "闸门判据在位" || bad "闸门判据缺失"
grep -q '暂停做任务，待小鸡进食后再做' "$M" && ok "暂停文案在位" || bad "暂停文案缺失"

echo "[2/3] 取值口径与领取端逐字一致（lastManorFoodStockLimit ?: 1800）"
L=$(grep -c 'lastManorFoodStockLimit > 0 ? self.lastManorFoodStockLimit : 1800' "$M")
if [ "$L" -ge 2 ]; then ok "两处闸门同一口径（$L 处）"; else bad "口径不一致（仅 $L 处）"; fi
grep -q 'lastTaskFullLogTime > 60' "$M" && ok "60 秒节流在位" || bad "节流缺失"

echo "[3/3] 闸门只拦饲料奖励、不拦菜谱；触发块仍完整"
grep -q 'isFoodAward && taskStockLimit > 0' "$M" && ok "仅 ALLPURPOSE 受闸门约束" || bad "闸门范围错误"
grep -q 'manorFoodTaskGapOK(bizKey)' "$M" && grep -q 'doManorFarmTaskWithBizKey' "$M" && ok "触发块（含多阶段判据）未被破坏" || bad "触发块受损"
if grep -q 'openURL' "$M"; then bad "出现 openURL（不得引入跳转）"; else ok "无跳转逻辑"; fi

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [3/3]"; else echo "FAILED"; exit 1; fi
