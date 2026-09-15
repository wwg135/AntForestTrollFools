#!/usr/bin/env bash
# 森林寻宝（服务端名：森林抽抽乐）自动抽奖 —— 结构自检
# 证据来源：ManorProbe v0.2.7 真机抓包 2026-09-15（manor_probe(13).log + manor_probe.log(1).1 两份同时抓）
# 关键取证：op 族 = com.alipay.antiepdrawprod.*（前缀既非 antfarm / antiep / antforest → 此前「全资产 0 命中」的真因）
#           机会数 = resData.drawAsset.blance（服务端拼写就是 blance；抽前 2 → 抽后 0，totalTimes 40 → 42）
#           连抽 = batchDrawopengreen{sceneCode, times:N, activityId, userId, source:"IPicon"}
# 用户口径：无阈值，每天任务做完当天一次性连抽（不跨天攒；与庄园抽抽乐「攒满 10 才抽」是两套口径）
# v3.2.8 定稿：两活动对称；机会数驱动 times；熔断 3 次/日；回包超时兜底；桥未就绪不盲发
set -u
cd "$(dirname "$0")/.."
M=antforest/AntForestManager.m
H=antforest/AntForestManager.h
E=PortEntry.m
fail=0

chk() { if grep -Fq -- "$3" "$2"; then echo "  ok   $1"; else echo "  FAIL $1  <- 缺: $3"; fail=1; fi; }
chkno() { if grep -Fq -- "$3" "$2"; then echo "  FAIL $1  <- 不该出现: $3"; fail=1; else echo "  ok   $1"; fi; }

echo "=== 1. 抽奖 op 台账（三个 op 照抓包逐字） ==="
chk "查活动组 enterDrawGroup"   "$M" 'com.alipay.antiepdrawprod.enterDrawGroupopengreen'
chk "查机会数 drawSync"          "$M" 'com.alipay.antiepdrawprod.drawSyncopengreen'
chk "连抽 batchDraw"             "$M" 'com.alipay.antiepdrawprod.batchDrawopengreen'
chk "活动组名 antforestDraw"     "$M" 'antforestDraw'

echo "=== 2. 两个活动完全对称 ==="
chk "普通版 scene ANTFOREST_NORMAL_DRAW"   "$M" 'ANTFOREST_NORMAL_DRAW'
chk "活动版 scene ANTFOREST_ACTIVITY_DRAW" "$M" 'ANTFOREST_ACTIVITY_DRAW'
chk "场景常量成对声明"                      "$M" 'kForestDrawSceneActivity = @"ANTFOREST_ACTIVITY_DRAW"'
chk "两场景遍历起队列"                      "$M" 'for (NSString *scene in @[kForestDrawSceneNormal, kForestDrawSceneActivity])'

echo "=== 3. 机会数与奖品解析 ==="
chk "机会数读 blance"            "$M" 'd[@"blance"]'
chk "机会数落账（按在途场景）"   "$M" 'gForestDrawBalance[scene] = blance;'
chk "奖品读 drawResultList"      "$M" 'drawResultList'
chk "奖品读 prizeVO"             "$M" 'prizeVO'
chk "奖品名 prizeName"           "$M" 'prizeName'
chk "活动身份被动学习（回包）"   "$M" 'forestDrawLearnFromPacket'

echo "=== 4. 一次性连抽（times = 当前机会数，不写死） ==="
chk "连抽带 times 参数"          "$M" 'times\":%ld'
chk "times 取机会数"             "$M" '(long)times'
chk "连抽请求带明文 userId"      "$M" 'userId\":\"%@\"'
chk "uid 被动学习（回包 userId）" "$M" 'gForestDrawUserId = [(NSString *)uid copy];'
chk "source=IPicon（照页面抄）"  "$M" 'source\":\"IPicon'
chk "查机会 source=backend"      "$M" 'source\":\"backend'
chkno "不写死 times:2"           "$M" 'times\":2,'

echo "=== 5. 鲁棒性（熔断 / 在途 / 超时 / 按日清零 / 桥未就绪） ==="
chk "被拒熔断常量"               "$M" 'kForestDrawRejectLimit'
chk "被拒到顶当日停发（熔断日志）" "$M" '抽奖连续被拒 %ld 次，今日停止尝试'
chk "被拒计数按日清零"           "$M" '[gForestDrawRejects removeAllObjects];'
chk "唯一在途闸门（按场景）"     "$M" 'gForestDrawInFlight[scene] = @(times);'
chk "在途未清不再起队列"         "$M" 'if ([gForestDrawInFlight[scene] integerValue] > 0) continue;'
chk "回包超时兜底常量"           "$M" 'kForestDrawReplyWait'
chk "超时按在途场景认领"         "$M" 'if (![gForestDrawPendingScene isEqualToString:scene]) return;'
chk "桥未就绪不盲发（返回即跳过）" "$M" 'if (![self forestDrawBridge]) return;'
chk "回包被拒判定"               "$M" 'forestDrawPacketRejected'
chk "同场景重查节流"             "$M" 'kForestDrawThrottle'

echo "=== 6. 触发点（批次收尾 / 桥就绪后台 / 寻宝页兜底） ==="
chk "任务批次收尾触发抽奖"       "$M" '[self forestDrawSweepAfterTaskBatch:@"ANTFOREST_NORMAL_DRAW_TASK"]'
chk "后台探测有明确日志"         "$M" '不进寻宝页面'
# v3.2.9：真实桥路径 = PortEntry finishForestHomeStart（registerBridge 是零调用死方法，曾挂错在此导致探测从不触发）
awk '/^static void finishForestHomeStart/,/^}/' "$E" > /tmp/forest_home_start.txt
awk '/^-[( ]*void[)]autoCollectBubbles \{/,/^}/' "$M" > /tmp/forest_collect_tick.txt
chk "首页桥就绪路径挂探测"       "/tmp/forest_home_start.txt" '[manager forestDrawBackgroundProbe];'
chk "后台循环每轮也试探测"       "/tmp/forest_collect_tick.txt" '[self forestDrawBackgroundProbe];'
awk '/^- \(void\)registerBridge:/,/^}/' "$M" > /tmp/forest_regbridge.txt
chkno "探测不再挂在零调用死方法上" "/tmp/forest_regbridge.txt" 'forestDrawBackgroundProbe'
chk "后台被拒当日停"             "$M" 'gForestDrawProbeDeniedDay'
chk "被拒判定在早返回之前"       "$M" '后台拉取被服务端拒绝，今日不再后台尝试'
chk "寻宝页进来兜底扫一轮"       "$E" '[manager forestDrawSweepAfterTaskBatch:@"ANTFOREST_NORMAL_DRAW_TASK"]'
chk "头文件公开两个入口"         "$H" '- (void)forestDrawBackgroundProbe;'

echo "=== 7. 日志带活动剩余天数 ==="
chk "剩余天数文案函数"           "$M" 'static NSString *forestDrawDaysText(NSString *scene) {'
chk "复用庄园天数口径"           "$M" 'manorDrawDaysText(manorDrawRemainingDays(endDate), endDate)'
chk "连抽完成日志含天数"         "$M" '连抽完成 %ld 次，获得 %@ · %@'
chk "连抽开始日志含天数"         "$M" '任务已完成 → 当天连抽 %ld 次…'
chk "无机会不刷屏（每天每场一次）" "$M" 'forestDrawQuietLog'

echo "=== 8. 负向断言（历史坑） ==="
chkno "不靠猜域前缀 antiep/antforest 找 op" "$M" 'com.alipay.antiep.batchDraw'
# 抽奖模块切片（只在本版新增的模块内断言，避免命中历史路由白名单里的同名字符串）
awk '/^#pragma mark - 森林寻宝（服务端名：森林抽抽乐）自动抽奖 v3.2.8/,/^\/\/ ---- v3.2.7 新增：任务上下文按 scene\|taskId 存/' "$M" > /tmp/forest_draw_module.txt
if [ -s /tmp/forest_draw_module.txt ]; then echo "  ok   抽奖模块切片可取（$(wc -l < /tmp/forest_draw_module.txt) 行）"; else echo "  FAIL 抽奖模块切片为空"; fail=1; fi
chkno "模块内不读官方 dylib 的 drawEntranceVO" "/tmp/forest_draw_module.txt" 'drawEntranceVO'
chk   "模块内机会数只认 drawAsset/blance"      "/tmp/forest_draw_module.txt" 'd[@"blance"]'
chkno "抽奖不掺庄园喂食链"                   "$M" 'forestDrawFeedAnimal'
chkno "不按阈值攒次数（用户口径无阈值）"     "$M" 'gForestDrawMinTimes'
echo "  ---- 版本号（信息型，不作为门）----"
grep -o 'v3\.2\.[0-9]*' PortEntry.m | head -1 | sed 's/^/    PortEntry 版本串: /'
grep -m1 '^Version:' antforest/Package/DEBIAN/control | sed 's/^/    control: /'

echo
if [ "$fail" -eq 0 ]; then echo "全部通过"; else echo "存在失败项"; fi
exit "$fail"
