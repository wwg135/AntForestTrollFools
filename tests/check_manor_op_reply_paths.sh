#!/bin/sh
# v3.5.2 庄园 op 回执认包自检（4 段）
# 根因：庄园 op 回包不带 operationType（形如 {code,memo,success}），只按 opType 认回执会全部落空
#      ⇒ 实测高级饲料已喂进去、日志却报「4 秒无回执」，家庭签到反复超时。
# 守则：回执判定以「在飞状态 + op 型回包结构」为权威，opType 只作快速路径。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/4] op 型回包结构判定存在，且定义在 opType 之后（先用后判）"
D=$(grep -n 'BOOL manorOpReplyLike = ' "$M" | head -1 | cut -d: -f1)
O=$(grep -n 'self.lastRpcOperationType ?: @""))\];' "$M" | head -1 | cut -d: -f1)
if [ -n "$D" ] && [ -n "$O" ] && [ "$D" -gt "$O" ]; then ok "manorOpReplyLike 行 $D > opType 行 $O"; else bad "判定缺失或顺序错（def=$D op=$O）"; fi
grep -q 'BOOL manorReplyHasStruct = ' "$M" && ok "状态包结构排除表存在（不与状态包混淆）" || bad "manorReplyHasStruct 缺失"

echo "[2/4] 高级饲料回执：在飞状态即可认包（不依赖 opType）"
grep -q 'if (\[opType containsString:@"useFarmFood"\] || (manorOpReplyLike && gManorCuisineInFlight)) {' "$M" && ok "useFarmFood 回执已接结构认包" || bad "useFarmFood 回执未接结构认包"

echo "[3/4] 家庭签到回执：在飞状态 + 1 秒下界（避开前置 enterFamily 迟到回包误归属）"
grep -q 'manorOpReplyLike && gManorFamilySignSentAt > 0' "$M" && ok "签到回执已接结构认包（带时间下界）" || bad "签到回执未接结构认包"
grep -q 'gManorFamilySignSentAt = \[\[NSDate date\] timeIntervalSince1970\];' "$M" && ok "奖励请求发出时刻已记录" || bad "gManorFamilySignSentAt 未赋值"

echo "[4/4] 超时文案如实：不再把「未收到回执」写成「投喂失败」"
grep -q '4 秒未收到回执（服务端可能已投喂）' "$M" && ok "超时文案已改（可能已投喂）" || bad "超时文案未改"

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [4/4]"; else echo "FAILED"; exit 1; fi
