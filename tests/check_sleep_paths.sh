#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
control_file="$(dirname "$0")/../antforest/Package/DEBIAN/control"
makefile="$(dirname "$0")/../Makefile"

echo "[1/7] Checking sleep implementation & rpc31 request shape..."
grep -Fq 'sleepManorChicken' "$source_file"
grep -Fq 'com.alipay.antfarm.enterFamily' "$source_file"
grep -Fq 'com.alipay.antfarm.sleep' "$source_file"
grep -Fq 'spaceType\":\"ChickFamily' "$source_file"
grep -Fq 'aixinxiaowutojiating' "$source_file"
grep -Fq 'kManorFamilyGroupId' "$source_file"

echo "[2/7] Checking family-villa only (no love cabin)..."
if grep -Fq 'LOVECABIN' "$source_file"; then
    echo "❌ 用户要求只去家庭别墅睡觉，不得出现爱心小屋分支 (LOVECABIN)"
    exit 1
fi
if grep -Fq 'LOVECABIN' "$makefile"; then
    echo "❌ Makefile 不应出现爱心小屋"
    exit 1
fi

echo "[3/7] Checking the sleep window spans midnight (20:00 -> next day 06:00, any time inside)..."
grep -Fq 'static const NSInteger kManorSleepWindowStartHour = 20;' "$source_file"
grep -Fq 'static const NSInteger kManorSleepWindowEndHour = 6;' "$source_file"
grep -Fq 'return (hour >= kManorSleepWindowStartHour || hour < kManorSleepWindowEndHour);' "$source_file"
if grep -Fq 'return comp.hour >= 20;' "$source_file"; then
    echo "❌ 旧的窗口判定（只判 hour>=20，凌晨 0–5 点被漏掉）复活了"
    exit 1
fi

echo "[4/7] Checking the once-per-night key (midnight belongs to the same night)..."
grep -Fq 'static NSString *manorSleepNightKey(void) {' "$source_file"
grep -Fq 'if (manorCurrentHour() >= kManorSleepWindowEndHour) return getCurrentDateString();' "$source_file"
grep -Fq '[fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:-24 * 3600]]' "$source_file"
grep -Fq 'return [last isEqualToString:manorSleepNightKey()];' "$source_file"
grep -Fq '[[NSUserDefaults standardUserDefaults] setObject:manorSleepNightKey() forKey:kManorSleepDoneDateKey];' "$source_file"

echo "[5/7] Checking server-authoritative canSleep gate + split cooldown..."
grep -Fq 'static NSInteger gManorCanSleepState = 0;' "$source_file"
grep -Fq 'gManorCanSleepState = [sleepNotify[@"canSleep"] boolValue] ? 1 : -1;' "$source_file"
grep -Fq 'if (gManorCanSleepState == -1) {' "$source_file"
grep -Fq 'BOOL serverSaysCanSleep = (gManorCanSleepState == 1);' "$source_file"
grep -Fq 'static const NSTimeInterval kManorSleepRetryCooldown = 300.0;' "$source_file"
grep -Fq 'static const NSTimeInterval kManorSleepForceGap = 60.0;' "$source_file"
if grep -Fq 'now - lastSleepAttempt < 1800' "$source_file"; then
    echo "❌ 旧的 30 分钟盲等冷却复活了"
    exit 1
fi

echo "[6/7] Checking 20:00 one-shot timer + no panel-log spam (diag-once for wait/cool/bridge)..."
grep -Fq 'static void manorScheduleSleepAt20(AntForestManager *mgr) {' "$source_file"
grep -Fq 'static NSTimeInterval manorSecondsUntilNext20(void) {' "$source_file"
grep -Fq '[mgr recordStage:@"蚂蚁庄园：到 20:00 睡觉时间了，主动刷新状态送小鸡回别墅..."];' "$source_file"
grep -Fq '[mgr enterManorFarm];' "$source_file"
grep -Fq 'manorScheduleSleepAt20(self);' "$source_file"
grep -Fq 'manorScheduleSleepAt20(mgr);   // 预约下一夜' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_wait",' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_cool",' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_bridge",' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_server_no",' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"familysign_bridge",' "$source_file"
if grep -Fq '[self recordStage:@"蚂蚁庄园：还没到 20:00，小鸡先在外面玩"];' "$source_file"; then
    echo "❌ 刷屏版「还没到 20:00」日志复活了（应走 recordEggDiagOnce）"
    exit 1
fi
if grep -Fq '[self recordStage:@"蚂蚁庄园：睡觉重试冷却中（每 30 分钟一次）"];' "$source_file"; then
    echo "❌ 刷屏版「睡觉重试冷却中」日志复活了"
    exit 1
fi

echo "[7/7] Checking wiring, response marking, .h declaration & version..."
grep -Fq '[self sleepManorChicken];' "$source_file"
grep -Eq 'containsString:.*antfarm[.]sleep' "$source_file"
grep -Fq 'markManorSleepDone' "$source_file"
grep -Fq 'antforest_manor_sleep_date' "$source_file"
if grep -Fq 'antmanor_sleep' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的睡觉开关 key"
    exit 1
fi
if grep -Fq 'kKeySleepFamily' "$source_file"; then
    echo "❌ 不应把 AntManor 的开关搬进来（本功能默认开启，不加开关）"
    exit 1
fi
grep -Fq -- '-(void)sleepManorChicken;' "$header_file"
grep -Fq -- '-(void)feedManorChicken;' "$header_file"
grep -Fq -- '-(void)checkAndRunManorAutomations;' "$header_file"
control_ver=$(sed -n 's/^Version:[[:space:]]*//p' "$control_file" 2>/dev/null | head -1)
entry_ver=$(sed -n 's/.*当前版本：\(v[0-9][0-9.]*\).*/\1/p' "$entry_file" 2>/dev/null | head -1)
echo "   版本对照：control=${control_ver:-（读不到）} 面板=${entry_ver:-（读不到）}"

echo "✅ All sleep (family villa) checks passed successfully!"
