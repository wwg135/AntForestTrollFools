#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/7] Checking egg harvest implementation & .h declaration..."
grep -Fq -- '- (void)harvestManorEgg {' "$source_file"
grep -Fq -- '-(void)harvestManorEgg;' "$header_file"
grep -Fq -- '-(void)collectManorChickenManurePot:(NSString *)potNo;' "$header_file"   # 同族方法作为对照

echo "[2/7] Checking harvestProduce rpc request shape (NORMALEGG / source=antfarm)..."
grep -Fq 'com.alipay.antfarm.harvestProduce' "$source_file"
grep -Fq 'harvestType\":\"NORMALEGG' "$source_file"
grep -Fq 'source\":\"antfarm' "$source_file"
grep -Fq 'kManorEggRPCSource' "$source_file"
grep -Fq 'chInfo_ch_appcenter__chsub_9patch' "$source_file"

echo "[3/7] Checking gates (total switch / bridge / cooldown / farmId)..."
grep -Fq 'if (!self.enableAutoManor) return;' "$source_file"
grep -Fq 'self.manorBridge && self.manorBridge != self.jsBridge' "$source_file"
grep -Fq 'lastEggHarvestTime' "$source_file"
grep -Fq 'now - lastEggHarvestTime < 60' "$source_file"

echo "[4/7] Checking wiring into daily check chain + response-driven retry..."
grep -Fq '[self harvestManorEgg];' "$source_file"
grep -Fq '// 8. 收鸡蛋（有蛋才收' "$source_file"
grep -Fq '7000 * NSEC_PER_MSEC' "$source_file"

echo "[5/7] Checking response branch (success log + egg nest refresh)..."
grep -Fq '// L. 收鸡蛋回包处理 (harvestProduce)' "$source_file"
grep -Eq 'containsString:.*harvestProduce' "$source_file"
grep -Fq '已收取小鸡下的鸡蛋' "$source_file"
grep -Fq 'com.alipay.antfarm.syncAnimalStatus' "$source_file"
grep -Fq 'operTag\":\"SYNC_RESUME' "$source_file"

echo "[6/7] Checking panel logs (success / no-egg / skipped, 每天最多一条防刷屏)..."
grep -Fq 'static void recordEggDiagOnce(AntForestManager *mgr, NSString *key, NSString *message)' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"bridge"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"farmid"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"noegg"' "$source_file"
grep -Fq '收鸡蛋跳过（庄园桥接未就绪）' "$source_file"
grep -Fq '收鸡蛋跳过（尚未获取到庄园 ID）' "$source_file"
grep -Fq '蛋巢暂无可收鸡蛋' "$source_file"

echo "[7/7] Checking no leftover AntManor switch for this feature..."
if grep -Fq 'antmanor_harvest' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的收蛋开关 key（本功能受 enableAutoManor 总闸控制，不加独立开关）"
    exit 1
fi
if grep -Fq 'kKeyHarvest' "$source_file"; then
    echo "❌ 不应把 AntManor 的独立开关搬进来"
    exit 1
fi

echo "✅ All egg-harvest checks passed successfully!"
