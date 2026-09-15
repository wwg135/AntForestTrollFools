#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
panel_file="$(dirname "$0")/../PortEntry.m"

echo "[1/4] Checking cook RPC ops are all present..."
for op in \
  "com.alipay.antfarm.cook" \
  "com.alipay.antfarm.enterKitchen" \
  "com.alipay.antfarm.collectDailyFoodMaterial" \
  "com.alipay.antfarm.collectDailyLimitedFoodMaterial" \
  "com.alipay.antorchard.farmFoodMaterialCollect" \
  "com.alipay.antfarm.collectKitchenGarbage" ; do
  grep -Fq "$op" "$source_file"
done

echo "[2/4] Checking layered value fallback and key fields..."
for token in \
  '"resData.farmVO"' \
  'cookPickLayer' \
  'cookTimesAllowed' \
  'foodMaterialWarehouseStock' \
  'canCollectDailyFoodMaterial' \
  'canCollectDailyLimitedFoodMaterial' \
  'recievedKitchenGarbageAmount' \
  'cookResult' ; do
  grep -Fq "$token" "$source_file"
done

echo "[3/4] Checking order and guards..."
# 垃圾判定必须在「做菜后重新拉状态」之后（做菜会产生厨房垃圾）
a=$(grep -n '做菜后刷新状态' "$source_file" | head -1 | cut -d: -f1)
b=$(grep -n '清厨房垃圾' "$source_file" | head -1 | cut -d: -f1)
if [ -z "$a" ] || [ -z "$b" ] || [ "$a" -ge "$b" ]; then
  echo "❌ 清垃圾必须在做菜后刷新状态之后（a=$a b=$b）"
  exit 1
fi
# 可做 0 次时才试领每日限时食材，且同一轮只试一次
grep -Fq 'gCookLimitedTried' "$source_file"
grep -Fq '每日限时食材' "$source_file"
# 每步等回包超时看门狗
grep -Fq '等回包超时 15s' "$source_file"
# 同一次进入 60 秒内不重复跑
grep -Fq 'now - gCookEndAt < 60' "$source_file"

echo "[4/4] Checking trigger, reply routing and panel switch..."
grep -Fq '[self runCookAutomation];' "$source_file"
grep -Fq 'if (self.enableAutoCook && [AntForestManager isCookPacket:dict]) {' "$source_file"
grep -Fq '+ (BOOL)isCookPacket:(id)value {' "$source_file"
grep -Fq 'enableAutoCook' "$panel_file"
grep -Fq 'toggleAutoCook:' "$panel_file"
echo "    ℹ️  提示：做美食回包分发必须排在 isManorResponse 判定之前（cook 的 op 属于 com.alipay.antfarm.*，否则会被庄园处理链吃掉）"
awk '
  /if \(self\.enableAutoCook && \[AntForestManager isCookPacket:dict\]\) \{/ { c = NR }
  /if \(!\[AntForestManager isManorResponse:args\]\) \{/ { m = NR }
  END { if (c && m && c > m) { print "❌ 做美食分发排在 isManorResponse 之后，会被庄园链吃掉"; exit 1 } }
' "$source_file"

echo "✅ All cook automation path checks passed successfully!"
