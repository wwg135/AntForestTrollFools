#!/bin/sh
# v3.5.3 高级饲料候选名单自检（4 段）
# 背景：consumeManorCuisineStock 归零时会删条目，库存表因此变空 → manorAdvancedCuisineList 回退
#      「已识别菜谱全量」（持有未知），把没库存的菜谱逐个发 useFarmFood（9/16 实测一轮 41 个判无库存）。
# 守则：只有「从没学到过真实持有数」才允许回退全量；学过库存而当前全 0 ⇒ 收工不喂。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/4] 「学到过真实库存」持久标记存在（读写助手 + NSUserDefaults 键）"
grep -q 'kManorCuisineStockKnownKey' "$M" && ok "持久键存在" || bad "持久键缺失"
grep -q 'static void manorMarkCuisineStockKnown(void) {' "$M" && ok "mark 助手存在" || bad "mark 助手缺失"
grep -q 'static BOOL manorCuisineStockLearned(void) {' "$M" && ok "learned 读取助手存在" || bad "learned 助手缺失"

echo "[2/4] 学到真实持有数时打标记（且只在 count>0 合并成功处）"
L=$(grep -n 'manorMarkCuisineStockKnown();   // v3.5.3' "$M" | head -1 | cut -d: -f1)
U=$(grep -n 'if (!updated) return 0;' "$M" | head -1 | cut -d: -f1)
if [ -n "$L" ] && [ -n "$U" ] && [ "$L" -gt "$U" ]; then ok "标记行 $L 在合并成功判据（$U）之后"; else bad "标记未挂在合并成功处（mark=$L updated=$U）"; fi

echo "[3/4] 回退闸门：学过库存 ⇒ 持有全 0 时返回空列表"
grep -q 'if (manorCuisineStockLearned()) return @\[\];' "$M" && ok "闸门存在" || bad "闸门缺失"
F=$(grep -n 'if (manorCuisineStockLearned()) return @\[\];' "$M" | head -1 | cut -d: -f1)
B=$(grep -n 'manorBuiltinCuisineList();$' "$M" | tail -1 | cut -d: -f1)
if [ -n "$F" ] && [ -n "$B" ] && [ "$F" -lt "$B" ]; then ok "闸门行 $F 在写死兜底（$B）之前"; else bad "闸门顺序错（gate=$F builtin=$B）"; fi

echo "[4/4] 兜底路径保留：从没学到库存时仍可用「已识别菜谱全量 / 写死 7 组」"
grep -q 'manorLoadLearnedCuisines();' "$M" && ok "已识别菜谱回退仍在" || bad "已识别菜谱回退被删"
grep -q 'return manorBuiltinCuisineList();' "$M" && ok "写死兜底仍在" || bad "写死兜底被删"

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [4/4]"; else echo "FAILED"; exit 1; fi
