#!/bin/sh
# v3.5.1 庄园桥绑定判据自检（4 段）
# 背景：芭芭农场页会发/收 com.alipay.antfarm.*（做美食、厨房、肥料），只按数据判会把「农场桥」误绑成
#      「庄园桥」→ 庄园 op 全发到农场页 → 全部无回包（高级饲料「4 秒无回执」×8、家庭签到超时反复）。
# 本测试守三件事：①按 op 判庄园前先排除农场任务列表回包 ②页面归属以 URL 优先 ③农场桥不被抢绑为庄园桥。

set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/antforest/AntForestManager.m"
P="$DIR/PortEntry.m"
FAIL=0
ok() { printf '  ✔ %s\n' "$1"; }
bad() { printf '  ✘ %s\n' "$1"; FAIL=1; }

echo "[1/4] isManorResponse：农场任务列表回包不得判成庄园（闸门须在 op 判据之前）"
G=$(grep -n 'hasManorStructure && (dict\[@"taskList"\]' "$M" | head -1 | cut -d: -f1)
O=$(grep -n 'containsString:@"com.alipay.antfarm"' "$M" | head -1 | cut -d: -f1)
if [ -n "$G" ] && [ -n "$O" ] && [ "$G" -lt "$O" ]; then ok "闸门行 $G < op 判据行 $O"; else bad "闸门缺失或顺序错（gate=$G op=$O）"; fi
grep -q 'BOOL hasManorStructure' "$M" && ok "hasManorStructure 结构键白名单存在" || bad "hasManorStructure 缺失"

echo "[2/4] PortEntry：页面归属以 URL 优先（isFarmByUrl 先算，isManor 受 !isFarmByUrl 约束）"
F=$(grep -n 'isFarmByUrl = ctrlUrl && isFarmURL' "$P" | head -1 | cut -d: -f1)
MB=$(grep -n 'BOOL isManor = isManorByUrl' "$P" | head -1 | cut -d: -f1)
if [ -n "$F" ] && [ -n "$MB" ] && [ "$F" -lt "$MB" ]; then ok "isFarmByUrl 行 $F < isManor 行 $MB"; else bad "URL 判定顺序错（farm=$F manor=$MB）"; fi
grep -q 'isManorByData && !isFarmByUrl' "$P" && ok "数据判据被 !isFarmByUrl 约束" || bad "数据判据未受 URL 约束"
grep -q 'manager.manorBridge == self) && !isFarmByUrl' "$P" && ok "粘性绑定同样受 !isFarmByUrl 约束" || bad "粘性绑定未受 URL 约束"

echo "[3/4] PortEntry：农场桥不被抢绑为庄园桥"
grep -q 'BOOL blockedByFarmBridge = (manager.farmBridge == self && !isManorByUrl);' "$P" && ok "blockedByFarmBridge 闸门存在" || bad "blockedByFarmBridge 缺失"
grep -q 'if (isFirstBind && !blockedByFarmBridge) {' "$P" && ok "绑定处已接入闸门" || bad "绑定处未接入闸门"

echo "[4/4] 自愈与降噪：农场判定回包会解绑错误庄园桥；农场三条刷屏日志改为内容变化才打"
if grep -q 'else if (isFarmResp) {' "$P" && awk '/else if \(isFarmResp\) \{/{f=1} f&&/manager.manorBridge == self\) manager.manorBridge = nil;/{print;exit}' "$P" | grep -q 'manorBridge = nil'; then
  ok "isFarmResp 分支解绑错误庄园桥（自愈）"
else
  bad "isFarmResp 分支未解绑错误庄园桥"
fi
for k in farm_manure farm_sign farm_task_count; do
  grep -q "recordStageOnChange:@\"$k\"" "$M" && ok "降噪键 $k 已生效" || bad "降噪键 $k 缺失"
done

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS [4/4]"; else echo "FAILED"; exit 1; fi
