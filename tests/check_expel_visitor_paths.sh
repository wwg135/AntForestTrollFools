#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/7] Checking expel-visitor implementation in AntForestManager.m..."
grep -Fq 'sendBackManorAnimal:' "$source_file"
grep -Fq 'expelManorVisitors:' "$source_file"
grep -Fq 'com.alipay.antfarm.sendBackAnimal' "$source_file"
grep -Fq 'currentFarmId' "$source_file"
grep -Fq 'receiveNPCReward' "$source_file"
grep -Fq 'sendType' "$source_file"
grep -Fq 'sendType\":\"NORMAL' "$source_file"

echo "[2/7] Checking visitor-source & self-farm filtering..."
grep -Fq 'masterFarmId' "$source_file"
grep -Fq 'isEqualToString:self.lastManorFarmId' "$source_file"   # 自己的小鸡不赶
grep -Fq 'expelledFarmIds' "$source_file"                        # 本次运行不重复发请求
grep -Fq 'lastExpelScanTime' "$source_file"                      # 与其它动作同款节流

echo "[3/7] Checking multi-visitor queue (1 只→1 条请求，2 只→2 条请求，无上限)..."
grep -Fq 'for (NSDictionary *animal in animals) {' "$source_file"
grep -Fq '[queue addObject:' "$source_file"
grep -Fq '蚂蚁庄园：发现 %lu 只来偷吃的小鸡，正在逐个赶走' "$source_file"
grep -Fq 'index * 3.0 * NSEC_PER_SEC' "$source_file"
grep -Fq '[expelledFarmIds intersectSet:presentFarmIds]' "$source_file"
if awk '/^- \(void\)expelManorVisitors:/,/^\}/' "$source_file" | grep -Eq 'break;|queue\.count *(>|<|==|>=|<=)|firstObject';
then
    echo "❌ 队列构建被截断，可能只赶走第一只"
    exit 1
fi

echo "[4/7] Checking post-expel sync & angry emoji..."
grep -Fq 'SYNC_RESUME' "$source_file"
grep -Fq 'com.alipay.antfarm.liveChat' "$source_file"
grep -Fq 'ANGER_03' "$source_file"

echo "[5/7] Checking wiring & no leftover switch/key from AntManor..."
grep -Fq 'expelManorVisitors:animals' "$source_file"             # 由 handleManorResponse 回包驱动
if grep -Fq 'antforest_expel' "$source_file" "$makefile"; then
    echo "❌ 不应为赶走小鸡新增开关（用户要求不加开关）"
    exit 1
fi
if grep -Fq 'antmanor_expel' "$source_file"; then
    echo "❌ 不应残留 AntManor 的开关 key"
    exit 1
fi
if grep -Fq '10170904231636012088302173366812' "$source_file"; then
    echo "❌ 不得把 AntManor 里硬编码的农场 ID 搬进来"
    exit 1
fi

echo "[6/7] Checking .h declaration (same convention as other manor features)..."
grep -Fq -- '-(void)expelManorVisitors:(NSArray *)animals;' "$header_file"
grep -Fq -- '-(void)sendBackManorAnimal:(NSString *)animalId masterFarmId:(NSString *)masterFarmId;' "$header_file"
grep -Fq -- '-(void)collectManorChickenManurePot:(NSString *)potNo;' "$header_file"   # 既有同族方法作对照

echo "[7/7] Checking dylib build outputs..."
test -f "$(dirname "$0")/../build/AntForestPort-Ocean.dylib"
test -f "$(dirname "$0")/../build/AntForestPort-Ocean-iOS14.dylib"

echo "✅ All expel-visitor checks passed successfully!"
