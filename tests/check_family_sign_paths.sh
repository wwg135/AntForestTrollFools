#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
makefile="$(dirname "$0")/../Makefile"

echo "[1/5] Checking family-sign chain (enterFamily -> refinedOperation -> receiveFarmTaskAward)..."
grep -Fq 'signManorFamily' "$source_file"
grep -Fq 'com.alipay.antfarm.enterFamily' "$source_file"
grep -Fq 'com.alipay.antfarm.refinedOperation' "$source_file"
grep -Fq 'ENTERFAMILY' "$source_file"
grep -Fq 'com.alipay.antfarm.receiveFarmTaskAward' "$source_file"

echo "[2/5] Checking award params (FAMILY_SIGN_TASK / ANTFARM_FAMILY_TASK / FAMILY_INTIMACY)..."
grep -Fq 'FAMILY_SIGN_TASK' "$source_file"
grep -Fq 'ANTFARM_FAMILY_TASK' "$source_file"
grep -Fq 'FAMILY_INTIMACY' "$source_file"

echo "[3/5] Checking post-success syncs (syncFamilyStatus / syncAnimalStatus)..."
grep -Fq 'com.alipay.antfarm.syncFamilyStatus' "$source_file"
grep -Fq 'INTIMACY_VALUE' "$source_file"
grep -Fq 'syncUserIds' "$source_file"
grep -Fq 'SYNC_RESUME_FAMILY' "$source_file"
grep -Fq 'QUERY_ALL|QUERY_FAMILY_ANIMAL' "$source_file"

echo "[4/5] Checking daily gate, wiring & no leftover AntManor switch..."
grep -Fq 'antforest_manor_family_sign_date' "$source_file"
grep -Fq 'isManorFamilySignDoneToday' "$source_file"
grep -Fq 'markManorFamilySignDone' "$source_file"
grep -Fq '[self signManorFamily];' "$source_file"
grep -Eq 'containsString:.*receiveFarmTaskAward' "$source_file"
if grep -Fq 'antmanor_familySign' "$source_file" "$makefile"; then
    echo "❌ 不应残留 AntManor 的家庭签到开关 key（本功能不加开关，只受 enableAutoManor）"
    exit 1
fi
if grep -Fq 'kKeyFamilySign' "$source_file"; then
    echo "❌ 不应把 AntManor 的开关搬进来"
    exit 1
fi

echo "[5/5] Checking .h declaration (same convention as other manor features)..."
grep -Fq -- '-(void)signManorFamily;' "$header_file"
grep -Fq -- '-(void)syncManorFamilyStatusAndAnimal;' "$header_file"
grep -Fq -- '-(void)sleepManorChicken;' "$header_file"

echo "✅ All family-sign checks passed successfully!"
