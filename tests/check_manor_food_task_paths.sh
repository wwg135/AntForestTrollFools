#!/bin/sh
# v3.5.4 庄园「领饲料」任务自检（4 段）
# 背景：① 小课堂脚本提交后无条件写「今天已答」⇒ 点空也整天不再重试（症状：小课堂一直没做）；
#      ② 任务执行器按「游戏类(Game/Game_Charge) 或 模式 VIEW/TRIGGER 白名单」挑任务 ⇒ 试玩类/小游戏类
#         永远不试（用户截图：看一看水滴排排序、试玩庄园火爆小游戏、继续玩爆款新游 一直 TODO）。
# 守则：doFarmTask 就是 App「去完成」按钮发的 RPC，能后台完成的由服务端回 FINISHED；
#      出资类（捐款/支付/金融）必须继续拦，跳转/点 targetUrl 一律不做。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/4] 小课堂不再「提交即记账」：lastManorAnswerDate 只由 RECEIVED 分支落盘"
N=$(grep -c 'setObject:today forKey:@"lastManorAnswerDate"' "$M")
if [ "$N" = "1" ]; then ok "落盘点仅剩 RECEIVED 分支（1 处）"; else bad "落盘点有 $N 处（应为 1）"; fi
grep -q 'forKey:@"lastManorAnswerAttemptAt"\]' "$M" && ok "已改记「最近尝试时刻」" || bad "未见 lastManorAnswerAttemptAt"

echo "[2/4] 小课堂失败可重试（30 分钟节流）"
grep -q 'lastManorAnswerAttemptAt"\]' "$M" && grep -q '< 1800) return;' "$M" && ok "30 分钟重试闸门在位" || bad "重试闸门缺失"

echo "[3/4] 任务执行器不再按「游戏类/模式」白名单跳过（反向断言）"
if grep -q 'cat isEqualToString:@"Game"' "$M"; then bad "仍存在 Game 类直接 continue"; else ok "Game/Game_Charge 硬拦已移除"; fi
if grep -q 'if (\[mode isEqualToString:@"VIEW"\] || \[mode isEqualToString:@"TRIGGER"\]) {' "$M"; then bad "模式白名单仍在"; else ok "模式白名单已移除（每个 TODO 任务每天试一次）"; fi
grep -q 'v3.5.5：区分「单次任务」与「多阶段任务」' "$M" && ok "注释说明在位（v3.5.5 起区分单次/多阶段）" || bad "说明注释缺失"

echo "[4/4] 安全闸门必须保留：出资类拦截 + 一天一次记账键 + 不做跳转"
grep -q 'Public_Welfare_Behavior' "$M" && grep -q 'DONATION' "$M" && ok "捐款/支付类拦截仍在" || bad "出资类拦截被削弱"
grep -q 'title containsString:@"到店"' "$M" && ok "title 判据已补（到店/充值/购买/下单）" || bad "title 判据未补"
grep -q 'ANTFARM_FOOD_TASK:%@' "$M" && ok "一天一次记账键仍在" || bad "记账键丢失"
if grep -q 'openURL' "$M"; then bad "出现 openURL（本改动不得引入跳转）"; else ok "无跳转逻辑（纯 RPC）"; fi

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [4/4]"; else echo "FAILED"; exit 1; fi
