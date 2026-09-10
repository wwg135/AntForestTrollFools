#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/5] Checking sleep implementation & rpc31 request shape..."
grep -Fq 'sleepManorChicken' "$source_file"
grep -Fq 'com.alipay.antfarm.enterFamily' "$source_file"
grep -Fq 'com.alipay.antfarm.sleep' "$source_file"
grep -Fq 'spaceType\":\"ChickFamily' "$source_file"
grep -Fq 'aixinxiaowutojiating' "$source_file"
grep -Fq 'kManorFamilyGroupId' "$source_file"

echo "[2/5] Checking family-villa only (no love cabin)..."
if grep -Fq 'LOVECABIN' "$source_file"; then
    echo "❌ 用户要求只去家庭别墅睡觉，不得出现爱心小屋分支 (LOVECABIN)"
    exit 1
fi

echo "[3/5] Checking night gate (20:00) & once-a-day marking..."
grep -Fq 'isManorSleepTime' "$source_file"
grep -Fq 'comp.hour >= 20' "$source_file"
grep -Fq 'isManorSleepDoneToday' "$source_file"
grep -Fq 'markManorSleepDone' "$source_file"
grep -Fq 'antforest_manor_sleep_date' "$source_file"
grep -Fq '1800' "$source_file"

echo "[4/5] Checking wiring, response marking & no leftover AntManor switch..."
grep -Fq '[self sleepManorChicken];' "$source_file"
grep -Eq 'containsString:.*antfarm[.]sleep' $source_file
if grep -Fq 'antmanor_sleep' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的睡觉开关 key"
    exit 1
fi
if grep -Fq 'kKeySleepFamily' "$source_file"; then
    echo "❌ 不应把 AntManor 的开关搬进来（本功能默认开启，不加开关）"
    exit 1
fi
if grep -Fq 'LOVECABIN' "$makefile"; then
    echo "❌ Makefile 不应出现爱心小屋"
    exit 1
fi

echo "[5/5] Checking .h declaration (same convention as other manor features)..."
grep -Fq -- '-(void)sleepManorChicken;' "$header_file"
grep -Fq -- '-(void)feedManorChicken;' "$header_file"      # 既有同族方法作为对照
grep -Fq -- '-(void)checkAndRunManorAutomations;' "$header_file"

echo "✅ All sleep (family villa) checks passed successfully!"
