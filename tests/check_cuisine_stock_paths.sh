#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/12] Checking 库存识别落盘/读取（NSUserDefaults + 只记正数）..."
grep -Fq 'static NSString * const kManorCuisineStockKey = @"antforest_manor_cuisine_stock_v1";' "$source_file"
grep -Fq 'static NSString * const kManorCuisineEmptyKey = @"antforest_manor_cuisine_empty_v1";' "$source_file"
grep -Fq 'static NSMutableDictionary *gManorCuisineStock = nil;' "$source_file"
grep -Fq 'dictionaryForKey:kManorCuisineStockKey' "$source_file"
grep -Fq 'forKey:kManorCuisineStockKey' "$source_file"

echo "[2/12] Checking 持有数扫描：只认 cuisineId + 数字字段，只记 >0..."
grep -Fq 'static void manorScanCuisineStock(id obj, NSMutableDictionary *out, NSUInteger *budget) {' "$source_file"
grep -Fq 'if (count > 0 && count > old) out[cuisine] = @(count);' "$source_file"
grep -Fq 'static NSInteger manorCuisineCountIn(NSDictionary *dict) {' "$source_file"

echo "[3/12] Checking 可喂清单 = 有库存的菜谱（按持有数降序，识别到的种类全量）..."
grep -Fq 'static NSArray *manorOwnedCuisineList(void) {' "$source_file"
grep -Fq 'if (count > 0 && cookbookId.length > 3) {' "$source_file"
grep -Fq 'sortUsingComparator' "$source_file"
grep -Fq 'NSArray *owned = manorOwnedCuisineList();' "$source_file"
grep -Fq 'if (owned.count > 0) {' "$source_file"
grep -Fq 'return manorBuiltinCuisineList();' "$source_file"

echo "[4/12] Checking 「服务端判无库存」→ 记进当天名单 + 换下一个..."
grep -Fq 'static BOOL isManorCuisineEmptyMemo(NSString *memo) {' "$source_file"
grep -Fq 'containsString:@"不足"' "$source_file"
grep -Fq '[gManorCuisineEmptyIds addObject:emptyId];' "$source_file"
grep -Fq 'manorLoadCuisineEmptyIds();' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"cuisine_empty"' "$source_file"

echo "[5/12] Checking 主动查库存口径（syncAnimalStatus + QUERY_CUISINE_LIST / SYNC_RESUME / 10 分钟节流）..."
grep -Fq -- '- (BOOL)requestManorCuisineStockIfNeeded {' "$source_file"
grep -Fq 'com.alipay.antfarm.syncAnimalStatus' "$source_file"
grep -Fq 'QUERY_USER_INFO|QUERY_CUISINE_LIST|QUERY_SNACKS_FOOD' "$source_file"
grep -Fq 'SYNC_RESUME' "$source_file"
grep -Fq '< 600.0) return NO;' "$source_file"
grep -Fq -- '-(BOOL)requestManorCuisineStockIfNeeded;' "$header_file"

echo "[6/12] Checking 库存过期先查一次再喂（起手 5 秒等回包）..."
grep -Fq 'manorCuisineStockStale(now)' "$source_file"
grep -Fq '5 * NSEC_PER_SEC' "$source_file"

echo "[7/12] Checking 识别到库存就投喂（60 秒监控 + 回包学习两条路）..."
grep -Fq -- '- (void)learnManorCuisineStockFromObject:(id)obj {' "$source_file"
grep -Fq '[self learnManorCuisineStockFromObject:obj];' "$source_file"
grep -Fq '[self requestManorCuisineStockIfNeeded];' "$source_file"
grep -Fq -- '-(void)learnManorCuisineStockFromObject:(id)obj;' "$header_file"

echo "[8/12] Checking 投喂成功扣本地库存（扣到 0 从清单消失）..."
grep -Fq -- '- (NSInteger)consumeManorCuisineStock:(NSString *)cuisineId {' "$source_file"
grep -Fq 'NSInteger cuisineLeft = [self consumeManorCuisineStock:gManorCuisineInFlightId];' "$source_file"
grep -Fq '还剩 %ld 个' "$source_file"

echo "[9/12] Checking 负向：高级饲料入口不得再因「正在吃」早退（吃普通饲料中照喂）..."
feed_block=$(awk '/^- \(void\)feedManorChickenWithAdvancedFood \{/,/^}$/' "$source_file")
case "$feed_block" in
    *'isManorChickenEating'*) echo "❌ 高级饲料入口不得再按进食状态提前返回（9/11 用户口径：除睡觉外任何时候都能喂）"; exit 1 ;;
esac
case "$feed_block" in
    *'// 小鸡正在进食中照喂'*) ;;
    *) echo "❌ 应显式标注「进食中照喂」（9/11 用户口径）"; exit 1 ;;
esac

echo "[10/12] Checking 负向：4 秒无回包不再计成功、拉黑该菜谱后继续..."
timeout_block=$(awk '/4000 \* NSEC_PER_MSEC/,/^}$/' "$source_file")
case "$timeout_block" in
    *'gManorCuisineFedCount++'*) echo "❌ 超时不得记成功（无效请求不能算投喂数）"; exit 1 ;;
esac
case "$timeout_block" in
    *'[gManorCuisineBadIds addObject:gManorCuisineInFlightId];'*) ;;
    *) echo "❌ 超时应把该菜谱拉黑，避免同一轮反复撞同一组"; exit 1 ;;
esac

echo "[11/12] Checking 负向：silent 停止（没库存）不得再转普通饲料..."
silent_block=$(awk '/if \(silent\) \{/{flag=1} flag{print} /^    \}$/{if(flag) exit}' "$source_file")
case "$silent_block" in
    *'[self feedManorChicken];'*) echo "❌ 没库存时静默收工，不该再发普通饲料请求"; exit 1 ;;
    *'recordEggDiagOnce(self, @"cuisine_none"'*) ;;
    *) echo "❌ 没库存时应记一条面板日志（一天一条）"; exit 1 ;;
esac

echo "[12/12] Checking 无独立开关残留 + Makefile 挂载..."
if grep -Fq 'kKeyAdvancedFood' "$source_file"; then
    echo "❌ 不应把 AntManor 的独立开关搬进来（本功能受 enableAutoManor 总闸控制）"
    exit 1
fi
grep -Fq 'sh tests/check_cuisine_stock_paths.sh' "$makefile"

echo "✅ 高级饲料库存识别与投喂（有就投喂 / 没有就跳过）检查通过"
