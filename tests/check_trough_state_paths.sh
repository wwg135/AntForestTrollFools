#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
control_file="$(dirname "$0")/../antforest/Package/DEBIAN/control"

echo "[1/9] Checking farm state is read from farmVO.subFarmVO (real state packet shape)..."
grep -Fq 'outerFarmVO[@"subFarmVO"]' "$source_file"
grep -Fq 'NSDictionary *farmSubVO = [outerFarmVO[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? outerFarmVO[@"subFarmVO"] : nil;' "$source_file"
grep -Fq 'NSDictionary *farmVO = outerFarmVO;' "$source_file"
grep -Fq 'NSDictionary *innerSub = farmSubVO ?: subFarm;' "$source_file"

echo "[2/9] Checking candidate pick prefers the subFarmVO that really carries foodInTrough..."
grep -Fq 'NSMutableArray *subFarmCands = [NSMutableArray array];' "$source_file"
grep -Fq 'if (cand[@"foodInTrough"]) { subFarm = cand; break; }' "$source_file"
grep -Fq 'if (!subFarm) subFarm = subFarmCands.firstObject;' "$source_file"

echo "[3/9] Checking empty subFarmVO ({}) is not treated as a state packet..."
grep -Fq 'if ([(NSDictionary *)cand count] == 0) continue;' "$source_file"

echo "[4/9] Checking missing trough field != zero (manorTroughKnown gate)..."
grep -Fq 'id troughRaw = subFarm[@"foodInTrough"] ?: innerSub[@"foodInTrough"];' "$source_file"
grep -Fq 'BOOL manorTroughKnown = (troughRaw != nil);' "$source_file"
grep -Fq 'NSInteger foodInTrough = manorTroughKnown ? [troughRaw integerValue] : 0;' "$source_file"
grep -Fq 'id troughLimitRaw = subFarm[@"foodInTroughLimit"] ?: innerSub[@"foodInTroughLimit"];' "$source_file"
grep -Fq 'id troughCountRaw = subFarm[@"countdown"] ?: innerSub[@"countdown"];' "$source_file"

echo "[5/9] Checking server feed status (animalFeedStatus=EATING) is the authoritative eating signal..."
grep -Fq 'static NSString *manorChickenFeedStatus(NSDictionary *ownAnimal, NSDictionary *subFarm, NSDictionary *innerSub) {' "$source_file"
grep -Fq 'ownAnimal[@"animalStatusVO"]' "$source_file"
grep -Fq 'vo[@"animalFeedStatus"]' "$source_file"
grep -Fq 'BOOL serverEating = [feedStatus isEqualToString:@"EATING"];' "$source_file"
grep -Fq 'BOOL isEating = serverEating || (foodInTrough >= foodLimit) || (countdown > 0 && foodInTrough > 0);' "$source_file"

echo "[6/9] Checking unknown trough defers feeding and pulls authoritative state instead..."
grep -Fq '} else if (!manorTroughKnown) {' "$source_file"
grep -Fq '回包未带盆内余粮，无法判定饭盆空否，本轮暂缓投喂（不盲喂）' "$source_file"
grep -Fq 'static NSTimeInterval gLastManorTroughPullAt = 0;' "$source_file"
grep -Fq 'if (pullNow - gLastManorTroughPullAt > 60) {' "$source_file"

echo "[7/9] Checking the old blind-feed writing does not come back..."
if grep -Fq 'if (subFarm[@"foodInTrough"]) {' "$source_file"; then
    echo "❌ 旧的「缺键读成 0」写法复活了"
    exit 1
fi
if grep -Fq 'BOOL isEating = (foodInTrough >= foodLimit) || (countdown > 0 && foodInTrough > 0);' "$source_file"; then
    echo "❌ 旧的 isEating 判定（不看服务端进食状态）复活了"
    exit 1
fi
if grep -Fq 'NSDictionary *subFarm = [resData[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? resData[@"subFarmVO"]' "$source_file"; then
    echo "❌ 旧的 subFarm 取值链（漏 farmVO.subFarmVO）复活了"
    exit 1
fi

echo "[8/9] Checking backpack stock is read from farmVO.foodStock (enterFarm packet puts it there)..."
grep -Fq 'id stockRaw = subFarm[@"foodStock"] ?: resData[@"foodStock"] ?: dict[@"foodStock"] ?: farmVO[@"foodStock"];' "$source_file"
grep -Fq 'id stockLimitRaw = subFarm[@"foodStockLimit"] ?: resData[@"foodStockLimit"] ?: farmVO[@"foodStockLimit"];' "$source_file"
grep -Fq 'if (stockRaw != nil) {' "$source_file"
if grep -Fq 'if (subFarm[@"foodStock"]) {' "$source_file"; then
    echo "❌ 旧的背包存量取值链（漏 farmVO）复活了"
    exit 1
fi

echo "[9/9] Checking version bump (informational) + no new independent switch..."
control_ver=$(sed -n 's/^Version:[[:space:]]*//p' "$control_file" 2>/dev/null | head -1)
entry_ver=$(sed -n 's/.*当前版本：\(v[0-9][0-9.]*\).*/\1/p' "$entry_file" 2>/dev/null | head -1)
echo "   版本对照：control=${control_ver:-（读不到）} 面板=${entry_ver:-（读不到）}"
if [ "$control_ver" != "3.2.1" ]; then
    echo "⚠️ control 版本不是 3.1.9（实际：${control_ver:-空}）"
    echo "   —— 不影响功能判定，但打出来的 deb 版本号会是旧的；请把 antforest/Package/DEBIAN/control 一并覆盖"
fi
if [ "$entry_ver" != "v3.2.1" ]; then
    echo "⚠️ 面板版本号不是 v3.2.1（实际：${entry_ver:-空}）"
    echo "   —— 请把 PortEntry.m 一并覆盖"
fi
if grep -Fq 'antforest_trough' "$source_file" "$entry_file"; then
    echo "❌ 不得为本次修复新增独立开关"
    exit 1
fi

echo "✅ All trough-state (盆内余粮) checks passed successfully!"
