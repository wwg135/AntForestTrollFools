#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
M="$ROOT/antforest/AntForestManager.m"

grep -q 'gManorPendingFoodClaims' "$M"
grep -q 'manorPendingFoodReserved' "$M"
grep -q 'stock + reserved + award > limit' "$M"
grep -q '无法确认任务.*饲料奖励数量' "$M"
grep -q 'manorReserveFoodClaim(taskId, award)' "$M"
grep -q 'manorReleaseFoodClaim(respTaskId)' "$M"
# Reservation must happen only after the per-task claim key check, otherwise a repeated
# task-list callback would double-count the same reward and permanently block claims.
reserve_line=$(grep -n 'manorReserveFoodClaim(taskId, award)' "$M" | head -1 | cut -d: -f1)
claim_line=$(grep -n 'if (!\[gDailyCompletedTasks containsObject:claimKey\])' "$M" | awk -F: -v r="$reserve_line" '$1 < r {x=$1} END{print x}')
test -n "$claim_line"
test "$claim_line" -lt "$reserve_line"
echo 'food reward capacity regression checks passed'
