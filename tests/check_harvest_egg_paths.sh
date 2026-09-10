#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/9] Checking egg harvest implementation & .h declaration..."
grep -Fq -- '- (void)harvestManorEgg {' "$source_file"
grep -Fq -- '-(void)harvestManorEgg;' "$header_file"
grep -Fq -- '-(void)collectManorChickenManurePot:(NSString *)potNo;' "$header_file"   # 同族方法作为对照

echo "[2/9] Checking harvestProduce rpc request shape (NORMALEGG / source=antfarm)..."
grep -Fq 'com.alipay.antfarm.harvestProduce' "$source_file"
grep -Fq 'harvestType\":\"NORMALEGG' "$source_file"
grep -Fq 'source\":\"antfarm' "$source_file"
grep -Fq 'kManorEggRPCSource' "$source_file"
grep -Fq 'chInfo_ch_appcenter__chsub_9patch' "$source_file"

echo "[3/9] Checking gates (total switch / bridge / cooldown / farmId)..."
grep -Fq 'if (!self.enableAutoManor) return;' "$source_file"
grep -Fq 'bridge == self.jsBridge' "$source_file"   # 桥接可用性判定已收敛进 activeManorBridge
grep -Fq -- '- (id)activeManorBridge {' "$source_file"
grep -Fq 'lastEggHarvestTime' "$source_file"
grep -Fq 'now - lastEggHarvestTime < 60' "$source_file"

echo "[4/9] Checking wiring into daily check chain + response-driven retry..."
grep -Fq '[self harvestManorEgg];' "$source_file"
grep -Fq '// 8. 收鸡蛋（有蛋才收' "$source_file"
grep -Fq '7000 * NSEC_PER_MSEC' "$source_file"

echo "[5/9] Checking response branch (success log + egg nest refresh)..."
grep -Fq '// L. 收鸡蛋回包处理 (harvestProduce)' "$source_file"
grep -Eq 'containsString:.*harvestProduce' "$source_file"
grep -Fq '已收取小鸡下的鸡蛋' "$source_file"
grep -Fq 'com.alipay.antfarm.syncAnimalStatus' "$source_file"
grep -Fq 'operTag\":\"SYNC_RESUME' "$source_file"

echo "[6/9] Checking panel logs (success / no-egg / skipped, 每天最多一条防刷屏)..."
grep -Fq 'static void recordEggDiagOnce(AntForestManager *mgr, NSString *key, NSString *message)' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"bridge"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"farmid"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"noegg"' "$source_file"
grep -Fq '收鸡蛋跳过（庄园桥接未就绪）' "$source_file"
grep -Fq '收鸡蛋跳过（尚未获取到庄园 ID）' "$source_file"
grep -Fq '蛋巢暂无可收鸡蛋' "$source_file"

echo "[7/9] Checking no leftover AntManor switch for this feature..."
if grep -Fq 'antmanor_harvest' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的收蛋开关 key（本功能受 enableAutoManor 总闸控制，不加独立开关）"
    exit 1
fi
if grep -Fq 'kKeyHarvest' "$source_file"; then
    echo "❌ 不应把 AntManor 的独立开关搬进来"
    exit 1
fi

echo "[8/9] Checking 60s egg watch timer (常驻监控，照 AntManor 实时监听)..."
grep -Fq 'kManorEggWatchInterval = 60.0' "$source_file"
grep -Fq -- '- (void)startManorEggWatchTimer {' "$source_file"
grep -Fq -- '- (void)manorEggWatchTick {' "$source_file"
grep -Fq 'manorEggWatchTimer = [NSTimer scheduledTimerWithTimeInterval:kManorEggWatchInterval' "$source_file"
grep -Fq 'gManorHeldBridge = self.manorBridge;' "$source_file"
grep -Fq '[self startManorEggWatchTimer];' "$source_file"
grep -Fq '[self retryManorPendingAutomations];' "$source_file"
grep -Fq '已发出收蛋请求' "$source_file"
grep -Fq -- 'NSTimer *manorEggWatchTimer;' "$header_file"
grep -Fq -- '-(void)startManorEggWatchTimer;' "$header_file"
grep -Fq -- '-(void)manorEggWatchTick;' "$header_file"
grep -Fq -- '-(id)activeManorBridge;' "$header_file"
if grep -Fq '10170904231636012088302173366812' "$source_file"; then
    echo "❌ 不得把 AntManor 里硬编码的农场 ID 搬进来（farmId 一律用本仓动态解析的 lastManorFarmId）"
    exit 1
fi
n=$(grep -c '\[self activeManorBridge\]' "$source_file")
if [ "$n" -lt 15 ]; then
    echo "❌ 庄园请求未统一走 activeManorBridge（$n < 15）"
    exit 1
fi

echo "[9/9] Checking 喂鸡静默探针（照 AntManor quietWatchTick：探测即动作、失败静默）..."
grep -Fq 'kManorFeedProbeInterval = 300.0' "$source_file"
grep -Fq -- '- (void)probeFeedManorChicken {' "$source_file"
grep -Fq '[self probeFeedManorChicken];' "$source_file"
grep -Fq 'self.isManorFeedProbe = YES;' "$source_file"
grep -Fq 'if (self.isManorFeedProbe) return;' "$source_file"
grep -Fq 'if (!self.isManorFeedProbe) [self recordStage:@"蚂蚁庄园：正在投喂小鸡（180g 饲料）..."];' "$source_file"
grep -Fq -- 'BOOL isManorFeedProbe;' "$header_file"
grep -Fq -- '-(void)probeFeedManorChicken;' "$header_file"

echo "✅ All egg-harvest checks passed successfully!"
