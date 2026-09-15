#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
control_file="$(dirname "$0")/../antforest/Package/DEBIAN/control"

echo "[1/7] Checking award unit splits by awardType (ALLPURPOSE=g / CUISINE=个)..."
grep -Fq 'NSString *awardType = [task[@"awardType"] isKindOfClass:NSString.class] ? task[@"awardType"] : @"";' "$source_file"
grep -Fq 'BOOL isFoodAward = [awardType isEqualToString:@"ALLPURPOSE"];' "$source_file"
grep -Fq 'NSString *awardUnit = isFoodAward ? @"g" : @"个";' "$source_file"
grep -Fq 'if (award <= 0) {' "$source_file"

echo "[2/7] Checking pending-feed total helper (FINISHED + ALLPURPOSE only)..."
grep -Fq 'static NSInteger manorPendingTaskFeedAward(NSArray *taskList) {' "$source_file"
grep -Fq 'if (![t[@"taskStatus"] isEqualToString:@"FINISHED"]) continue;' "$source_file"
grep -Fq 'if (![t[@"awardType"] isEqualToString:@"ALLPURPOSE"]) continue;' "$source_file"

echo "[3/7] Checking today's sign award is counted into the pending total..."
grep -Fq 'static NSInteger gManorTodaySignAward = 0;' "$source_file"
grep -Fq 'gManorTodaySignAward = todaySigned ? award : 0;' "$source_file"
grep -Fq 'NSInteger pendingTaskAward = manorPendingTaskFeedAward(taskList);' "$source_file"
grep -Fq 'NSInteger pendingTotalAward = pendingTaskAward + gManorTodaySignAward;' "$source_file"

echo "[4/7] Checking the food-stock cap gate only applies to g-unit awards..."
grep -Fq 'if (isFoodAward && limit > 0 && stock + award > limit) {' "$source_file"

echo "[5/7] Checking panel log shows the total = tasks + today sign..."
grep -Fq '待领合计 %ldg = 任务 %ldg + 今日签到 %ldg' "$source_file"
grep -Fq '正在领取 %ld%@ 奖励（预估容量 %ldg/%ldg）...' "$source_file"

echo "[6/7] Checking the old single-task / unit-blind writing does not come back..."
if grep -Fq 'NSInteger award = [task[@"awardCount"] integerValue] ?: ([task[@"canReceiveAwardCount"] integerValue] ?: 90);' "$source_file"; then
    echo "❌ 旧的不分单位 award 计算复活了"
    exit 1
fi
if grep -Fq '（当前 %ldg/%ldg，待领 %ldg），暂不领取' "$source_file"; then
    echo "❌ 旧的「单个任务当待领」文案复活了"
    exit 1
fi
if grep -Fq 'if (limit > 0 && stock + award > limit) {' "$source_file"; then
    echo "❌ 旧的满仓闸门（未按 awardType 分支）复活了"
    exit 1
fi

echo "[7/7] Checking version bump (informational) + no new independent switch..."
control_ver=$(sed -n 's/^Version:[[:space:]]*//p' "$control_file" 2>/dev/null | head -1)
entry_ver=$(sed -n 's/.*当前版本：\(v[0-9][0-9.]*\).*/\1/p' "$entry_file" 2>/dev/null | head -1)
echo "   版本对照：control=${control_ver:-（读不到）} 面板=${entry_ver:-（读不到）}"
if [ "$control_ver" != "3.2.0" ]; then
    echo "⚠️ control 版本不是 3.2.0（实际：${control_ver:-空}）—— 请把 antforest/Package/DEBIAN/control 一并覆盖"
fi
if [ "$entry_ver" != "v3.2.0" ]; then
    echo "⚠️ 面板版本号不是 v3.2.0（实际：${entry_ver:-空}）—— 请把 PortEntry.m 一并覆盖"
fi
if grep -Fq 'antforest_pending' "$source_file" "$entry_file"; then
    echo "❌ 不得为本次修复新增独立开关"
    exit 1
fi

echo "✅ All pending-feed award (待领饲料合计) checks passed successfully!"
