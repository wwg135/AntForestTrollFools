#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"
port_file="$(dirname "$0")/../PortEntry.m"

echo "[1/12] Checking 识别入口（.h 声明 / .m 定义 / handleManorResponse 调用）..."
grep -Fq -- '-(void)learnManorCuisinesFromObject:(id)obj;' "$header_file"
grep -Fq -- '- (void)learnManorCuisinesFromObject:(id)obj {' "$source_file"
grep -Fq -- '[self learnManorCuisinesFromObject:dict];' "$source_file"

echo "[2/12] Checking 识别优先 + 写死兜底仍在（7 组不删）..."
grep -Fq 'gManorLearnedCuisines.count > 0' "$source_file"
grep -Fq 'return manorBuiltinCuisineList();' "$source_file"
grep -Fq 'static NSArray *manorBuiltinCuisineList(void) {' "$source_file"
builtin_count=$(grep -o '@{@"cookbookId"' "$source_file" | wc -l | tr -d ' ')
if [ "$builtin_count" -ne 7 ]; then
    echo "❌ 写死兜底菜谱应为 7 组（识别不到时才用），实际 $builtin_count 组"
    exit 1
fi

echo "[3/12] Checking 只认成对数据（cookbookId 与 cuisineId 同一字典内，禁止单边拼装）..."
grep -Fq 'obj[@"cookbookId"] ?: obj[@"cookBookId"]' "$source_file"
grep -Fq 'obj[@"cuisineId"]' "$source_file"
grep -Fq 'out[cuisine] = cookbook;' "$source_file"
grep -Fq '[cookbook length] > 3' "$source_file"

echo "[4/12] Checking 持久化（NSUserDefaults 存盘 + 启动读回）..."
grep -Fq 'antforest_manor_cuisines_v1' "$source_file"
grep -Fq 'dictionaryForKey:kManorLearnedCuisineKey' "$source_file"
grep -Fq 'setObject:gManorLearnedCuisines forKey:kManorLearnedCuisineKey' "$source_file"

echo "[5/12] Checking 扫描节流 + 节点预算（庄园回包很密，不能每包全量递归）..."
grep -Fq 'gManorCuisineLearnScanAt' "$source_file"
grep -Fq 'now - gManorCuisineLearnScanAt < 2.0' "$source_file"
grep -Fq 'NSUInteger budget = 600;' "$source_file"

echo "[6/12] Checking 面板日志（识别结果，每天汇总一条）..."
grep -Fq '蚂蚁庄园 · 高级饲料识别：新增 %lu 种菜谱' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"cuisine_learn"' "$source_file"

echo "[7/12] Checking 回包到达探针（只限庄园三个关键 op + 无 op 兜底，一天一条）..."
grep -Fq 'static BOOL isManorProbeOp(NSString *op) {' "$source_file"
grep -Fq '蚂蚁庄园 · 回包到达：%@（success=%d，memo=%@）' "$source_file"
grep -Fq 'recordEggDiagOnce(self, opType.length ? [@"rsp_" stringByAppendingString:opType] : @"rsp_noop"' "$source_file"

echo "[8/12] Checking 负向（识别不是开关 / 不落 AntManor 独立开关 / 测试已挂载）..."
if grep -Fq 'enableAdvancedFood' "$source_file" "$header_file"; then
    echo "❌ 高级饲料识别不应引入独立开关（受 enableAutoManor 总闸控制）"
    exit 1
fi
if grep -Fq 'antmanor_advanced' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的高级饲料开关 key"
    exit 1
fi
grep -Fq 'sh tests/check_cuisine_learn_paths.sh' "$makefile"

echo "[9/12] Checking 页面自身请求观察（PortEntry 桥钩子 → 学真实菜谱）..."
grep -Fq 'portObserveManorRPCRequest' "$port_file"
grep -Fq 'class_replaceMethod(cls, sendSel, (IMP)portRPCSendProbe' "$port_file"
grep -Fq 'class_replaceMethod(cls, handlerSel, (IMP)portRPCCallHandlerProbe' "$port_file"
grep -Fq '[[AntForestManager sharedInstance] noteManorPageRPCRequest:arg]' "$port_file"
grep -Fq -- '-(void)noteManorPageRPCRequest:(id)payload;' "$header_file"
grep -Fq -- '- (void)noteManorPageRPCRequest:(id)payload {' "$source_file"

echo "[10/12] Checking 被拒菜谱跳过（不整轮停，全被拒才转普通饲料）..."
grep -Fq 'manorNextCuisineToFeed' "$source_file"
grep -Fq '[gManorCuisineBadIds addObject:gManorCuisineInFlightId]' "$source_file"
grep -Fq '换下一个菜谱' "$source_file"
grep -Fq '（可喂菜谱都被拒了）' "$source_file"
if grep -Fq 'cuisineList[gManorCuisineFedCount % cuisineList.count]' "$source_file"; then
    echo "❌ 取菜谱必须走 manorNextCuisineToFeed（跳过被拒的），不能按固定下标硬取"
    exit 1
fi

echo "[11/12] Checking 轮转游标 + 在飞菜谱 + 每轮重置..."
grep -Fq 'gManorCuisineCursor++' "$source_file"
grep -Fq 'gManorCuisineInFlightId = cuisine[@"cuisineId"]' "$source_file"
grep -Fq '[gManorCuisineBadIds removeAllObjects]' "$source_file"
grep -Fq 'gManorCuisineCursor = 0;' "$source_file"

echo "[12/12] Checking 回包到达探针 / 操作类型识别 仍在位..."
grep -Fq '回包到达' "$source_file"
grep -Fq 'manorFindOperationType' "$source_file"
grep -Fq '页面自身请求' "$source_file"

echo "✅ All advanced-feed (cuisine) recognition checks passed successfully!"
