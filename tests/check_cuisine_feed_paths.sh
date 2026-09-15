#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/8] Checking advanced-feed implementation & .h declaration..."
grep -Fq -- '- (void)feedManorChickenWithAdvancedFood {' "$source_file"
grep -Fq -- '- (void)stopManorAdvancedFoodFeed:(NSString *)reason silent:(BOOL)silent {' "$source_file"
grep -Fq -- '-(void)feedManorChickenWithAdvancedFood;' "$header_file"
grep -Fq -- '-(void)stopManorAdvancedFoodFeed:(NSString *)reason silent:(BOOL)silent;' "$header_file"
grep -Fq -- '-(void)feedManorChicken;' "$header_file"   # 同族方法作为对照

echo "[2/8] Checking useFarmFood rpc shape (flat 1-per-request / 7 cuisines)..."
grep -Fq 'com.alipay.antfarm.useFarmFood' "$source_file"
grep -Fq 'cookbookId' "$source_file"
grep -Fq 'cuisineId' "$source_file"
grep -Fq 'useCuisine' "$source_file"
grep -Fq 'kManorCuisineSource' "$source_file"
grep -Fq 'chInfo_ch_appcenter__chsub_9patch' "$source_file"
cuisine_count=$(grep -o '@{@"cookbookId"' "$source_file" | wc -l | tr -d ' ')
if [ "$cuisine_count" -ne 7 ]; then
    echo "❌ 高级饲料菜谱应为 7 组（照 AntManor 抓包口径），实际 $cuisine_count 组"
    exit 1
fi

echo "[3/8] Checking gates (total switch / bridge / cooldown / single-round cap 15)..."
grep -Fq 'if (!self.enableAutoManor) return;' "$source_file"
grep -Fq 'self.manorBridge && self.manorBridge != self.jsBridge' "$source_file"
grep -Fq 'gManorCuisineInFlight' "$source_file"
grep -Fq 'gManorCuisineStopUntil' "$source_file"
grep -Fq '+ 1800;' "$source_file"
grep -Fq 'gManorCuisineFedCount >= 15' "$source_file"

echo "[4/8] Checking one-by-one wiring (1.2s chaining / 4s no-response guard / chain + response driven)..."
grep -Fq '1200 * NSEC_PER_MSEC' "$source_file"
grep -Fq '4000 * NSEC_PER_MSEC' "$source_file"
grep -Fq '[self feedManorChickenWithAdvancedFood];' "$source_file"
grep -Fq '// 4. 自动投喂小鸡（优先逐个投喂高级饲料' "$source_file"
grep -Fq '优先高级饲料' "$source_file"
grep -Fq '[self feedManorChicken];' "$source_file"   # 普通饲料兜底入口仍在

echo "[5/8] Checking response branch M (success continues / 喂不动 falls back to normal feed)..."
grep -Fq '// M. 高级饲料投喂回包处理 (useFarmFood)' "$source_file"
grep -Eq 'containsString:.*useFarmFood' "$source_file"
grep -Fq '转普通饲料投喂' "$source_file"
grep -Fq 'isManorCuisineSkipMemo' "$source_file"
grep -Fq '还没吃完' "$source_file"
grep -Fq '已满' "$source_file"

echo "[6/8] Checking panel logs (send / success / pause)..."
grep -Fq '高级饲料投喂开始（识别到持有' "$source_file"
grep -Fq '正在投喂第 %lu 个高级饲料' "$source_file"
grep -Fq '高级饲料投喂成功（第 %lu 个，' "$source_file"
grep -Fq '高级饲料本轮结算——成功' "$source_file"
grep -Fq '高级饲料投喂暂停（%@）' "$source_file"

echo "[7/8] Checking bowl-empty feed falls back to plain 180g when no cuisine/snack is available..."
grep -Fq 'static NSTimeInterval gManorBowlEmptyFeedWantedAt = 0;' "$source_file"
grep -Fq 'static BOOL manorConsumeBowlEmptyFeedWanted(void) {' "$source_file"
grep -Fq 'gManorBowlEmptyFeedWantedAt = [[NSDate date] timeIntervalSince1970];' "$source_file"
grep -Fq 'gManorBowlEmptyFeedWantedAt = 0;   // 高级饲料已在投，不需要普通饲料兜底' "$source_file"
grep -Fq '蚂蚁庄园：没有可投喂的高级饲料/零食包，转普通 180g 饲料投喂' "$source_file"
grep -Fq '蚂蚁庄园：高级饲料冷却中且没有零食包，转普通 180g 饲料投喂' "$source_file"
silent_body=$(awk '/^    if \(silent\) \{/,/^        return;$/' "$source_file")
if [ -z "$silent_body" ]; then
    echo "❌ 抽不到 silent 收工分支"
    exit 1
fi
echo "$silent_body" | grep -Fq 'manorConsumeBowlEmptyFeedWanted()'
echo "$silent_body" | grep -Fq '[self feedManorChicken];'

echo "[7/8] Checking no leftover AntManor switch for this feature..."
if grep -Fq 'antmanor_advanced' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的高级饲料开关 key（本功能受 enableAutoManor 总闸控制，不加独立开关）"
    exit 1
fi
if grep -Fq 'kKeyAdvancedFood' "$source_file"; then
    echo "❌ 不应把 AntManor 的独立开关搬进来"
    exit 1
fi

echo "✅ All advanced-feed (cuisine) checks passed successfully!"
