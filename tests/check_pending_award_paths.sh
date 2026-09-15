#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"
entry_file="$(dirname "$0")/../PortEntry.m"
control_file="$(dirname "$0")/../antforest/Package/DEBIAN/control"

echo "[1/26] Checking award unit splits by awardType (ALLPURPOSE=g / CUISINE=个)..."
grep -Fq 'NSString *awardType = [task[@"awardType"] isKindOfClass:NSString.class] ? task[@"awardType"] : @"";' "$source_file"
grep -Fq 'BOOL isFoodAward = [awardType isEqualToString:@"ALLPURPOSE"];' "$source_file"
grep -Fq 'NSString *awardUnit = isFoodAward ? @"g" : @"个";' "$source_file"
grep -Fq 'if (award <= 0) {' "$source_file"

echo "[2/26] Checking pending-feed total helper scans the whole list with the SAME claimability rule..."
grep -Fq 'static NSInteger manorPendingTaskFeedAward(NSArray *taskList, NSUInteger *outCount) {' "$source_file"
grep -Fq 'if (!manorTaskClaimable(t)) continue;   // v3.3.6：与领奖判定同口径（原只认 FINISHED）' "$source_file"
grep -Fq 'if (![t[@"awardType"] isEqualToString:@"ALLPURPOSE"]) continue;' "$source_file"
grep -Fq 'if (outCount) *outCount = count;' "$source_file"
if grep -Fq 'if (![t[@"taskStatus"] isEqualToString:@"FINISHED"]) continue;' "$source_file"; then
    echo "❌ 待领合计又退回「只认 FINISHED」了（与领奖判定不一，会漏掉 CAN_RECEIVE 类任务）"
    exit 1
fi

echo "[3/26] Checking today's sign award is NOT counted into the pending total..."
grep -Fq 'NSUInteger pendingTaskCount = 0;' "$source_file"
grep -Fq 'NSInteger pendingTaskAward = manorPendingTaskFeedAward(taskList, &pendingTaskCount);' "$source_file"
if grep -Fq 'gManorTodaySignAward' "$source_file"; then
    echo "❌ 签到量又被计入待领了（用户口径：签到当日即时到账，不计入）"
    exit 1
fi
if grep -Fq 'pendingTotalAward' "$source_file"; then
    echo "❌ 旧的「任务 + 签到」合计写法复活了"
    exit 1
fi

echo "[4/26] Checking the food-stock cap gate only applies to g-unit awards..."
grep -Fq 'if (isFoodAward && limit > 0 && stock + award > limit) {' "$source_file"

echo "[5/26] Checking panel log shows the task-only total with count..."
grep -Fq '待领合计 %ldg（%lu 个已完成任务）' "$source_file"
grep -Fq '正在领取 %ld%@ 奖励（预估容量 %ldg/%ldg）...' "$source_file"

echo "[6/26] Checking the old single-task / unit-blind writing does not come back..."
if grep -Fq 'NSInteger award = [task[@"awardCount"] integerValue] ?: ([task[@"canReceiveAwardCount"] integerValue] ?: 90);' "$source_file"; then
    echo "❌ 旧的不分单位 award 计算复活了"
    exit 1
fi
if grep -Fq '（当前 %ldg/%ldg，待领 %ldg），暂不领取' "$source_file"; then
    echo "❌ 旧的「单个任务当待领」文案复活了"
    exit 1
fi
if grep -Fq 'if (limit > 0 && stock + award > limit) {' "$source_file"; then
    echo "❌ 旧的满仓闸门（未按 awardType 分支）复活了"
    exit 1
fi

echo "[7/26] Checking 庄园 claimability covers FINISHED + CAN_RECEIVE/WAIT_AWARD/... + 「领取」按钮..."
grep -Fq 'static BOOL manorTaskStatusClaimable(NSString *status) {' "$source_file"
grep -Fq 'states = @[@"FINISHED", @"CAN_RECEIVE", @"WAIT_AWARD", @"WAIT_RECEIVE", @"TO_RECEIVE", @"SUCCESS"];' "$source_file"
grep -Fq 'static BOOL manorTaskClaimable(NSDictionary *task) {' "$source_file"
grep -Fq 'static NSString *manorTaskButtonText(NSDictionary *task) {' "$source_file"
grep -Fq 'displayConfig[@"finishedBtn"] ?: (displayConfig[@"completeBtn"] ?: (displayConfig[@"todoBtn"]' "$source_file"
grep -Fq 'return (btn.length && [btn containsString:@"领"] && ![btn containsString:@"去"]);' "$source_file"

echo "[8/26] Checking the claim site no longer claims by FINISHED-only (regression guard)..."
grep -Fq 'if (manorTaskClaimable(task)) {   // v3.3.6：不再只认 FINISHED（CAN_RECEIVE/WAIT_AWARD/… 与「领取」按钮一并认）' "$source_file"
if grep -Fq 'if ([status isEqualToString:@"FINISHED"]) {' "$source_file"; then
    echo "❌ 领奖条件退回「只认 FINISHED」——UI 显示「领取」的任务会被静默跳过"
    exit 1
fi

echo "[9/26] Checking the troubleshooting 任务诊断 is removed (排查用，已按用户要求删除)..."
if grep -Fq 'manorTaskListDiag' "$source_file"; then
    echo "❌ 排查用的任务诊断又回来了（用户已要求删除）"
    exit 1
fi

echo "[10/26] Checking the claim-receipt fallback retry (记账后无回执 → 允许再试，封顶 2 次)..."
grep -Fq 'static const NSInteger kManorClaimMaxTries = 2;' "$source_file"
grep -Fq 'static const NSTimeInterval kManorClaimReceiptWait = 90.0;' "$source_file"
grep -Fq 'manorClaimMarkSent(taskId);' "$source_file"
grep -Fq 'if (now - sent > kManorClaimReceiptWait && tries < kManorClaimMaxTries) {' "$source_file"
grep -Fq '领奖未收到回执（已试 %ld 次、%ld 秒前提交），重试领取…' "$source_file"

echo "[11/26] Checking the reward-bridge waiting log is throttled (不再每轮刷屏)..."
grep -Fq 'static NSTimeInterval gRewardWaitLogAt = 0;' "$source_file"
grep -Fq 'if (!inStartupGrace && (gRewardWaitLogAt == 0 || nowWait - gRewardWaitLogAt > 1800)) {' "$source_file"
grep -Fq '首页后台：暂无领奖励任务桥接（进一次蚂蚁森林首页即可绑定 H5 会话，绑定后自动接管领奖励与森林寻宝）' "$source_file"
grep -Fq 'gRewardWaitLogAt = 0;' "$source_file"
if grep -Fq 'if (self.enableAutoRewardTasks) [self recordStage:@"首页后台：等待领奖励任务桥接"];' "$source_file"; then
    echo "❌ 无节流的等待日志复活了（用户反馈刷屏）"
    exit 1
fi

echo "[12/26] Checking 睡觉/喂鸡修复没有把任务查询(领奖)链截断..."
claim_body=$(awk '/^- \(void\)queryManorFarmTasks \{/{f=1} f{print} f&&/^\}$/{exit}' "$source_file")
if printf '%s' "$claim_body" | grep -q 'manorChickenSleeping\|manorServerSleeping'; then
    echo "❌ 任务查询/领奖链被睡觉闸门截断——夜间将不再自动领取饲料奖励"
    exit 1
fi
if ! printf '%s' "$claim_body" | grep -q 'com.alipay.antfarm.listFarmTask'; then
    echo "❌ 任务查询链缺 listFarmTask 请求（函数体截取异常）"
    exit 1
fi

echo "[13/26] Checking version sync (informational) + no new independent switch..."
control_ver=$(sed -n 's/^Version:[[:space:]]*//p' "$control_file" 2>/dev/null | head -1)
entry_ver=$(sed -n 's/.*当前版本：\(v[0-9][0-9.]*\).*/\1/p' "$entry_file" 2>/dev/null | head -1)
echo "   版本对照：control=${control_ver:-（读不到）} 面板=${entry_ver:-（读不到）}"
if [ -n "$control_ver" ] && [ -n "$entry_ver" ] && [ "v${control_ver}" != "$entry_ver" ]; then
    echo "⚠️ control 与面板版本号不一致（control=${control_ver} 面板=${entry_ver}）—— 请两处同步（信息型，不作为门）"
fi
if grep -Fq 'antforest_pending' "$source_file" "$entry_file"; then
    echo "❌ 不得为本次修复新增独立开关"
    exit 1
fi

echo "[14/26] Checking claim accounting is persisted (must survive app restart)..."
grep -Fq 'ANTFARM_CLAIM_SENT:' "$source_file"
grep -Fq 'static void manorClaimMarkSent(NSString *taskId) {' "$source_file"
if grep -Fq 'gManorClaimSentAt' "$source_file"; then
    echo "❌ 领奖记账仍存内存字典（App 重启即丢 → 静默不领奖、且无任何日志）"
    exit 1
fi

echo "[15/26] Checking a billed-but-never-sent claim is re-claimed instead of silently skipped..."
grep -Fq 'if (sent <= 0) {' "$source_file"
grep -Fq '今日有领奖记账但查不到发送记录，按未领取补领一次' "$source_file"

echo "[16/26] Checking waiting / retry-limit claims always leave a log line (no silent skip)..."
grep -Fq '今日已记账领奖（%@），本轮跳过' "$source_file"
grep -Fq '"manor_claim_wait:%@"' "$source_file"

echo "[17/26] Checking receipt wait is bounded (<=120s, else a whole day can pass without a retry)..."
wait_val=$(sed -n 's/.*kManorClaimReceiptWait = \([0-9][0-9.]*\).*/\1/p' "$source_file" | head -1)
echo "   kManorClaimReceiptWait=${wait_val:-（读不到）}"
if [ -z "$wait_val" ]; then
    echo "❌ 读不到回执等待时长常量"
    exit 1
fi
if awk "BEGIN{exit !(${wait_val} > 120)}"; then
    echo "❌ 回执等待时长过长（${wait_val}s > 120s）——跨轮久等，整天不补领"
    exit 1
fi

echo "[18/26] Checking server-state receipt (RECEIVED) confirms delivery once and clears the wait record..."
grep -Fq '奖励已到账（服务端状态 RECEIVED）' "$source_file"
grep -Fq '"manor_claim_ok:%@"' "$source_file"

echo "[19/26] Checking the claim reply is traced (was silently dropped by the status-packet router)..."
grep -Fq '蚂蚁庄园 · 领取回包（taskId=%@）' "$source_file"
grep -Fq 'isClaimReply' "$source_file"

echo "[20/26] Checking a 20s no-reply watchdog exists for the claim request..."
grep -Fq '领取请求已发出 20 秒仍未见回包' "$source_file"

echo "[21/26] Checking a reply marks the receipt (no blind retry, no legacy re-claim loop)..."
grep -Fq 'ANTFARM_CLAIM_REPLY:' "$source_file"
grep -Fq 'manorClaimHasReply(taskId)' "$source_file"
grep -Fq '今日已收到领取回包，不再重复领取' "$source_file"

echo "[22/26] Checking the claim submit log carries taskId + op (so the reply can be matched)..."
grep -Fq '（taskId=%@, op=receiveFarmTaskAward）' "$source_file"

echo "[23/26] Checking any bound bridge can serve the generic gateway chains (进一个页面即可跑另外两家网关任务)..."
grep -Fq -- '-(PSDJsBridge *)anyRewardTaskBridge {' "$source_file"
grep -Fq 'if (self.manorBridge) return (PSDJsBridge *)self.manorBridge;' "$source_file"
grep -Fq 'self.rewardTaskBridge = [self anyRewardTaskBridge];' "$source_file"
if grep -Fq 'self.rewardTaskBridge ?: self.jsBridge' "$source_file"; then
    echo "❌ 仍有只认 jsBridge 的旧回退链（会漏掉已绑定的庄园/农场/寻宝桥接）"
    exit 1
fi

echo "[24/26] Checking the cross-page guard now leaves a log line (不再静默 return)..."
grep -Fq '本轮跳过森林主线/领奖励 RPC（跨 AppId 直发会报 3000/100000008），通用网关任务不受影响' "$source_file"
grep -Fq 'NSString *skipPage = isMonopolyPage ? @"新版保护地"' "$source_file"

echo "[25/26] Checking the startup grace period for the bridge-waiting log (启动瞬间误报不再提示)..."
grep -Fq 'static NSTimeInterval gProcStartAt = 0;' "$source_file"
grep -Fq 'BOOL inStartupGrace = (nowWait - gProcStartAt < 120.0);' "$source_file"
grep -Fq 'if (!inStartupGrace && (gRewardWaitLogAt == 0 || nowWait - gRewardWaitLogAt > 1800)) {' "$source_file"

echo "[26/26] Checking the claim reply is never swallowed + always traced (只记不吞 + 兜底留痕)..."
grep -Fq '蚂蚁庄园 · 领奖回包：haveAddFoodStock=%@ foodStock=%@ memo=%@ · 顶层键=%@' "$source_file"
grep -Fq '（家庭签到在途：只记不吞，不据此改背包存量）' "$source_file"
grep -Fq -- '- (void)handleManorResponse:(NSDictionary *)dict {' "$source_file"
if grep -Fq 'if (!gManorFamilySignPending && (resData[@"haveAddFoodStock"] || [opType containsString:@"receiveFarmTaskAward"])) {' "$source_file"; then
    echo "❌ 家庭签到在途时整段吞掉领奖回包的旧写法复活了"
    exit 1
fi


