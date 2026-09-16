#!/bin/sh
# v3.5.5 多阶段「领饲料」任务自检（4 段）
# 背景：多阶段任务（打开即得30g、最多240g＝8 阶段，做完一次按钮变「继续完成」）被 v3.5.4 的
#      「一天一次」记账锁死 ⇒ 只做第 1 阶段就不再继续（9/16 用户截图）。
# 守则：按钮「继续…」或次数未满 ⇒ 允许继续触发到当日上限（≤8 次、间隔 ≥20 秒）；
#      单次任务仍一天一次；出资类（捐款/支付）永久拦；一律纯 RPC 不跳转。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/4] 次数记账/节流助手在位（日缓存计数，重启不丢）"
grep -q 'static NSInteger manorFoodTaskSentCount(NSString \*bizKey) {' "$M" && ok "计数助手在位" || bad "计数助手缺失"
grep -q 'ANTFARM_FOOD_TASK_N:%@:' "$M" && ok "次数键前缀在位（条数=当日次数）" || bad "次数键前缀缺失"
grep -q 'static void manorFoodTaskMarkSent(NSString \*bizKey) {' "$M" && ok "记账助手里在位" || bad "记账助手缺失"
grep -q 'kManorFoodTaskMinGap = 20.0' "$M" && ok "最小间隔 20 秒在位" || bad "最小间隔缺失"

echo "[2/4] 多阶段判据：按钮「继续…」或 rightsTimes<rightsTimesLimit"
grep -q 'containsString:@"继续"' "$M" && ok "按钮「继续完成」已识别" || bad "未识别「继续」按钮"
grep -q 'rightsTimesLimit' "$M" && grep -q 'BOOL multiStage = ' "$M" && ok "多阶段判定在位" || bad "multiStage 判定缺失"
grep -q 'NSInteger cap = (stageLimit > 1) ? MIN(stageLimit, 8) : 8;' "$M" && ok "上限硬顶 8 次" || bad "上限硬顶缺失"

echo "[3/4] 单次任务仍一天一次（不得因放宽而重复执行）"
grep -q 'BOOL allowed = multiStage ? (sent < cap) : (sent == 0);' "$M" && ok "单次走 sent==0 分支" || bad "单次分支缺失"
grep -q '单次任务$' "$M" || grep -q '·单次任务' "$M" && ok "日志区分单次/多阶段" || bad "日志未区分"

echo "[4/4] 安全与合规闸门保持：出资类拦截 + 无跳转"
grep -q 'Public_Welfare_Behavior' "$M" && grep -q 'containsString:@"捐"' "$M" && ok "捐款/支付类拦截仍在（棉花馒头任务会被拦）" || bad "出资类拦截被削弱"
if grep -q 'openURL' "$M"; then bad "出现 openURL（不得引入跳转）"; else ok "无跳转逻辑（纯 RPC）"; fi
grep -q 'com.alipay.antfarm.doFarmTask' "$M" && ok "doFarmTask 报文仍在" || bad "doFarmTask 报文丢失"

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [4/4]"; else echo "FAILED"; exit 1; fi
