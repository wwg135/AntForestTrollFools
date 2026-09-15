#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
control_file="$(dirname "$0")/../antforest/Package/DEBIAN/control"

echo "[1/8] Checking one-shot wake timer exists (generation + absolute time, no runloop ownership)..."
grep -Fq 'static NSInteger gManorFeedWakeSeq = 0;' "$source_file"
grep -Fq 'static NSTimeInterval gManorFeedWakeAt = 0;' "$source_file"
grep -Fq 'static const NSTimeInterval kManorFeedWakeGrace = 1.0;' "$source_file"
grep -Fq 'static void manorScheduleFeedWake(AntForestManager *mgr, NSInteger countdown) {' "$source_file"
grep -Fq 'static void manorCancelFeedWake(void) {' "$source_file"
grep -Fq 'if (seq != gManorFeedWakeSeq) return;' "$source_file"

echo "[2/8] Checking wake is scheduled from the state packet's countdown (feeding remaining seconds)..."
grep -Fq 'if (troughCountRaw != nil) {' "$source_file"
grep -Fq 'manorScheduleFeedWake(self, countdown);' "$source_file"
grep -Fq 'manorCancelFeedWake();' "$source_file"
grep -Fq 'countdown > 0 && !manorChickenSleeping()' "$source_file"

echo "[3/8] Checking wake refreshes authoritative state instead of blind-feeding..."
wake_body=$(awk '/^static void manorScheduleFeedWake/,/^\}$/' "$source_file")
if [ -z "$wake_body" ]; then
    echo "❌ 抽不到 manorScheduleFeedWake 函数体"
    exit 1
fi
echo "$wake_body" | grep -Fq '[mgr enterManorFarm];'
if echo "$wake_body" | grep -Fq 'feedManorChicken'; then
    echo "❌ 到点时刻不得直接盲喂（必须先 enterManorFarm 拉权威状态，由状态驱动投喂）"
    exit 1
fi
grep -Fq '小鸡进食倒计时结束，正在刷新状态并补喂' "$source_file"

echo "[4/8] Checking repeat packets do not reschedule and the wake itself is one-shot (no repeating timer)..."
grep -Fq '同一轮的重复回包不重排' "$source_file"
if echo "$wake_body" | grep -Fq 'NSTimer'; then
    echo "❌ 唤醒链不得用 NSTimer（用 dispatch_after 单次定时，不持有 runloop）"
    exit 1
fi
if echo "$wake_body" | grep -Fq 'repeats:YES'; then
    echo "❌ 唤醒链不得引入重复定时（重复定时=发热风险）"
    exit 1
fi
grep -Fq 'NSTimeInterval delay = (NSTimeInterval)countdown + kManorFeedWakeGrace;' "$source_file"
grep -Fq 'dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{' "$source_file"

echo "[5/8] Checking the chick's sleep state also blocks feeding (panel/user rule)..."
grep -Fq 'static NSString *manorChickenFeedStatus(NSDictionary *ownAnimal, NSDictionary *subFarm, NSDictionary *innerSub) {' "$source_file"
grep -Fq 'static BOOL manorServerSleeping(NSString *feedStatus, NSDictionary *ownAnimal, NSDictionary *subFarm, NSDictionary *innerSub) {' "$source_file"
grep -Fq 'BOOL serverSleeping = manorServerSleeping(feedStatus, ownAnimal, subFarm, innerSub);' "$source_file"
grep -Fq '} else if (serverSleeping) {' "$source_file"
grep -Fq 'if (manorChickenSleeping()) return;   // 小鸡在睡觉：普通饲料同样喂不进，省一次无效请求' "$source_file"

echo "[6/8] Checking the sleep branch is silent (neither feeds nor pulls state)..."
sleep_body=$(awk '/\} else if \(serverSleeping\) \{/,/^                \}/' "$source_file")
if [ -z "$sleep_body" ]; then
    echo "❌ 抽不到 serverSleeping 分支"
    exit 1
fi
if echo "$sleep_body" | grep -Fq 'feedManorChicken'; then
    echo "❌ 睡觉分支不得投喂"
    exit 1
fi

echo "[7/8] Checking overdue wake (long absence) triggers an immediate state refresh..."
grep -Fq 'static const NSTimeInterval kManorFeedWakeStale = 60.0;' "$source_file"
grep -Fq 'if (gManorFeedWakeAt > 0 && wakeNow > gManorFeedWakeAt + kManorFeedWakeStale) {' "$source_file"
grep -Fq '小鸡进食倒计时早已结束（本地预约已过 %ld 分钟），立即刷新状态并补喂' "$source_file"
stale_body=$(awk '/^            \/\/ 久别回来/,/^            \}$/' "$source_file")
echo "$stale_body" | grep -Fq '[self enterManorFarm];'

echo "[8/8] Checking version bump (informational) + no new independent switch..."
control_ver=$(sed -n 's/^Version:[[:space:]]*//p' "$control_file" 2>/dev/null | head -1)
entry_ver=$(sed -n 's/.*当前版本：\(v[0-9][0-9.]*\).*/\1/p' "$entry_file" 2>/dev/null | head -1)
echo "   版本对照：control=${control_ver:-（读不到）} 面板=${entry_ver:-（读不到）}"
if [ "$control_ver" != "3.2.3" ]; then
    echo "⚠️ control 版本不是 3.2.3（实际：${control_ver:-空}）—— 请把 antforest/Package/DEBIAN/control 一并覆盖"
fi
if [ "$entry_ver" != "v3.2.3" ]; then
    echo "⚠️ 面板版本号不是 v3.2.3（实际：${entry_ver:-空}）—— 请把 PortEntry.m 一并覆盖"
fi
if grep -Fq 'antforest_feedwake' "$source_file" "$entry_file"; then
    echo "❌ 不得为本次修复新增独立开关"
    exit 1
fi

echo "✅ All feed-wake (倒计时结束立即补喂 / 睡觉不投喂 / 久别立即补喂) checks passed successfully!"
