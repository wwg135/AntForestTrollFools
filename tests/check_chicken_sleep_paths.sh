#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
makefile="$(dirname "$0")/../Makefile"

echo "[1/8] Checking 睡觉判定（中文睡觉/休息/无法操作 + 英文 sleep）..."
grep -Fq 'static BOOL isManorSleepMemo(NSString *memo) {' "$source_file"
grep -Fq 'containsString:@"睡觉"' "$source_file"
grep -Fq 'containsString:@"无法操作"' "$source_file"
grep -Fq 'containsString:@"sleep"' "$source_file"

echo "[2/8] Checking 睡觉静默闸门（5 分钟内不发起任何投喂）..."
grep -Fq 'static NSTimeInterval gManorChickenSleepUntil = 0;' "$source_file"
grep -Fq 'static const NSTimeInterval kManorChickenSleepQuiet = 300.0;' "$source_file"
grep -Fq 'static BOOL manorChickenSleeping(void) {' "$source_file"

echo "[3/8] Checking 高级饲料入口先查睡觉闸门..."
grep -Fq 'if (manorChickenSleeping()) return;   // 小鸡在睡觉：饲料投不进去，等静默期过再试' "$source_file"

echo "[4/8] Checking 普通饲料入口先查睡觉闸门..."
grep -Fq 'if (manorChickenSleeping()) return;   // 睡觉静默期内不投喂（普通饲料服务端同样拒）' "$source_file"

echo "[5/8] Checking 饭盆空闲分支：睡觉时走「不投喂」而非「自动投喂」..."
grep -Fq '} else if (manorChickenSleeping()) {' "$source_file"
grep -Fq '小鸡在睡觉，不投喂 | 盆内' "$source_file"

echo "[6/8] Checking 停止分档：睡觉=5 分钟静默（不吃 30 分钟重罚），面板日志一天一条..."
grep -Fq 'if (isManorSleepMemo(reason)) {' "$source_file"
grep -Fq 'gManorCuisineStopUntil = 0;' "$source_file"
grep -Fq '蚂蚁庄园：小鸡在睡觉，暂不投喂饲料（%@）' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"cuisine_sleep"' "$source_file"

echo "[7/8] Checking 负向：睡觉分支直接 return，不得再转普通饲料..."
sleep_block=$(awk '/- \(void\)stopManorAdvancedFoodFeed:/,/^}$/' "$source_file")
case "$sleep_block" in
    *'return;   // 睡觉期间普通饲料同样喂不进'*) ;;
    *) echo "❌ 睡觉分支必须先 return（睡觉期间普通饲料同样被服务端拒）"; exit 1 ;;
esac

echo "[8/8] Checking 负向：诊断探针已删 + 面板日志无英文（回包到达/回包关联/H5 Bridge）..."
if grep -Fq '回包到达' "$source_file" || grep -Fq '回包关联' "$source_file" || grep -Fq 'isManorProbeOp' "$source_file"; then
    echo "❌ 诊断探针应已删除（睡觉根因已坐实，不再需要）"
    exit 1
fi
if grep -n 'recordStage.*H5 Bridge\|waterStopWithReason.*H5 Bridge' "$source_file" "$entry_file"; then
    echo "❌ 面板日志不应再出现英文 H5 Bridge（应为「页面通道」）"
    exit 1
fi
grep -Fq 'sh tests/check_chicken_sleep_paths.sh' "$makefile"

echo "✅ 小鸡睡觉不投喂（睡觉静默闸门）检查通过"
