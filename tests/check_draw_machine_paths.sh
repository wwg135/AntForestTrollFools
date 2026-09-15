#!/usr/bin/env bash
# 抽抽乐（DrawMachine）自动攒次数 + 一键连抽 —— 结构自检
# 口径来源：manor_probe 抓包 2026-09-11 首发 + 2026-09-12 手动做满两活动全流程
# 用户口径：平时不抽，积满 10 次才连抽；活动当天结束则剩余全抽；当天没做满就一直执行
# 9/12 定案：回包任务项不含 taskSceneCode（只在请求里），分流改按白名单 taskId/bizKey 认；FINISHED=只领奖，TODO=动作+领奖
# 9/15 定案（v3.2.7）：日志带活动剩余天数（0 天=今天结束）；删补抽 cap+5 轮硬顶改时长兜底+自推进；在途/降级/任务上下文按活动隔离
# 9/13 定案（v3.3.2）：补抽只在「活动最后一天」启用；队列按活动分开存（旧版单全局变量被后查的活动覆盖 → IP 场剩余 3 次被提前抽干）
set -u
cd "$(dirname "$0")/.."
M=antforest/AntForestManager.m
H=antforest/AntForestManager.h
fail=0

chk() { if grep -Fq -- "$3" "$2"; then echo "  ok   $1"; else echo "  FAIL $1  <- 缺: $3"; fail=1; fi; }
chkno() { if grep -Fq -- "$3" "$2"; then echo "  FAIL $1  <- 不该出现: $3"; fail=1; else echo "  ok   $1"; fi; }

echo "=== 1. 解析来源台账（六件套 op，照抓包逐字） ==="
chk "查任务 listFarmTask"            "$M" 'com.alipay.antfarm.listFarmTask'
chk "逛杂货铺 antiep.finishTask"      "$M" 'com.alipay.antiep.finishTask'
chk "领次数 receiveFarmTaskAward"     "$M" 'com.alipay.antfarm.receiveFarmTaskAward'
chk "做任务 doFarmTask"               "$M" 'com.alipay.antfarm.doFarmTask'
chk "查活动 queryDrawMachineActivity" "$M" 'com.alipay.antfarm.queryDrawMachineActivity'
chk "抽奖 drawMachine"                "$M" 'com.alipay.antfarm.drawMachine'
chk "outBizNo 带 ADBASICLIB"          "$M" 'ADBASICLIB'
chk "outBizNo 随机后缀"               "$M" 'arc4random_uniform'

echo "=== 2. 两个活动完全对称（A 日常 / B IP） ==="
chk "A scene dailyDrawMachine"        "$M" 'dailyDrawMachine'
chk "B scene ipDrawMachine"           "$M" 'ipDrawMachine'
chk "A 任务 scene ANTFARM_DAILY_DRAW_TASK" "$M" 'ANTFARM_DAILY_DRAW_TASK'
chk "B 任务 scene ANTFARM_IP_DRAW_TASK"    "$M" 'ANTFARM_IP_DRAW_TASK'
chk "A 签到 SIGN_FREE_TASK"           "$M" 'SIGN_FREE_TASK'
chk "B 签到 IP_SIGN_FREE"             "$M" 'IP_SIGN_FREE'
chk "A 杂货铺 SHANGYEHUA_DAILY_DRAW_TIMES" "$M" 'SHANGYEHUA_DAILY_DRAW_TIMES'
chk "B 杂货铺 IP_SHANGYEHUA_TASK"     "$M" 'IP_SHANGYEHUA_TASK'
chk "A 饲料换 DAILY_DRAW_EXCHANGE_TASK_180" "$M" 'DAILY_DRAW_EXCHANGE_TASK_180'
chk "B 饲料换 IP_EXCHANGE_TASK_180"   "$M" 'IP_EXCHANGE_TASK_180'
chk "A 次数类型 DAILY_DRAW_TIMES"     "$M" 'DAILY_DRAW_TIMES'
chk "B 次数类型 IP_DRAW_MACHINE_DRAW_TIMES" "$M" 'IP_DRAW_MACHINE_DRAW_TIMES'

echo "=== 3. 用户口径：满 10 才抽 / 到期全抽 / 循环次数读服务端 ==="
chk "满次数判定 drawTimes >= maxDraw" "$M" 'drawTimes >= maxDraw'
chk "上限字段 maxDrawTimes"           "$M" 'maxDrawTimes'
chk "连抽参数 batchDrawTimes"         "$M" 'batchDrawTimes'
chk "配额读服务端 rightsTimesLimit"   "$M" 'rightsTimesLimit'
chk "活动最后一天判定 isDateInToday"  "$M" 'isDateInToday'
chk "连抽被拒降级为逐次单抽"          "$M" '降级为逐次单抽'

echo "=== 4. 做满才封盘 + 每 5 分钟补一轮（9/11 修正：旧版发起即收工，实测漏做） ==="
chk "做满标记 DONE"                    "$M" 'manorDrawDailyMark(@"DONE"'
chk "轮数计数标记 RND"                 "$M" 'manorDrawDailyMark(@"RND"'
chkno "6 轮封顶已移除（9/12：当天没做满就一直执行）" "$M" 'kManorDrawMaxRounds'
chk "无封顶口径注释"                   "$M" '当天没做满就一直补做'
chk "60s 无回包诊断日志"               "$M" '发出任务列表请求 60 秒未收到回包'
chk "60s 告警按请求配平表判（不再比运行时刻）" "$M" 'stillAsked.doubleValue == askAt'
chk "请求登记入配平表"                 "$M" 'gManorDrawListAskedAt[scene] = @(askAt)'
chk "回包即摘配平表"                   "$M" 'removeObjectForKey:scene'
chkno "旧按运行时刻比较的诊断已移除"    "$M" 'gManorDrawLastDiag'
chk "空列表诊断需真无 farmTaskList"     "$M" 'taskList.count == 0 && gManorDrawListAskedAt.count > 0'
chk "空列表诊断署名活动"               "$M" '任务列表回包为空（无 farmTaskList）'
chkno "旧误报文案已移除"               "$M" '抽查任务列表被拒'
chk "分流按回包白名单识别"             "$M" 'manorDrawSceneInTaskList(taskList)'
chk "白名单含四类真实 taskId"          "$M" 'SHANGYEHUA_DAILY_DRAW_TIMES'
chk "回包无 taskSceneCode 已注明"      "$M" '回包项里没有 taskSceneCode'
chk "收到任务列表可见留痕"             "$M" '已收到任务列表回包'
chk "FINISHED 只领奖语义"              "$M" 'claimOnly'
chk "饲料换机会不重复领奖"             "$M" '由 doFarmTask 一步到位'
chk "签到未完成不代做"                 "$M" '签到靠进入活动页打卡'
chkno "H1.5 死诊断已移除"              "$M" '未进抽抽乐链路'
chk "两活动错开 8s（旧版 55s）"        "$M" 'kManorDrawSceneStagger = 8.0'
chk "同活动 20s 内不重复下发"          "$M" 'kManorDrawExecThrottle = 20.0'
chk "下发窗口覆盖整轮执行时间"         "$M" 'manorDrawExecHold(scene, queryDelay)'
chk "已抽标记 PULL"                    "$M" 'manorDrawDailyMark(@"PULL"'
chkno "旧版发起即封盘 ROUND 已移除"    "$M" 'manorDrawDailyMark(@"ROUND"'
chk "动作/领奖回执入面板"              "$M" '领奖" : @"动作"'
chk "动作失败短路跳过领奖"             "$M" '动作未成功，跳过本次领奖'
chk "动作失败标记来自回包（按上下文）" "$M" 'manorDrawActContextMark(actScene, actTaskId, !ok)'
chk "动作回执 op 已并入抽抽乐分支"      "$M" 'isManorDrawActOperation'
chk "逛杂货铺浏览停留 15s（任务项 desc）" "$M" 'kManorDrawShopBrowseWait = 15.0'
chk "targetUrl 内嵌真实页解析"          "$M" 'manorDrawInnerPageURL'
chk "照森林浏览任务手法后台预取"        "$M" 'prefetchManorDrawShopPage'
chk "杂货铺轮间隔 2.5s（真机 2.35~2.49）" "$M" 'kManorDrawShopInterval = 2.5'
chk "桥接 ack status:success 也算成功"   "$M" '[actStatus isEqualToString:@"success"]'
chk "失败判据 verdict 独立"             "$M" 'BOOL verdict = (resData[@"success"]'
chk "无显式判据不下失败结论"            "$M" 'isManorDrawActOperation(opType) && verdict'
chk "计划项携带 targetUrl"              "$M" '@"targetUrl": (task[@"targetUrl"] ?: @"")'
chkno "旧版当天一次 HANDLED 已移除"    "$M" 'manorDrawDailyMark(@"HANDLED"'

chk "回包先查做满标记"                 "$M" 'if ([gDailyCompletedTasks containsObject:manorDrawDailyMark(@"DONE", scene)]) return;'
chk "桥断不消费本轮"                   "$M" 'if (![self activeManorBridge]) return;'
chk "中途离开庄园有日志并留待补做"     "$M" '本轮中断，下次心跳补做'
chk "做满即写 DONE 封盘"               "$M" '今日任务已做满'
chkno "轮数用完文案已删"               "$M" '轮数用完'

echo "=== 5. 并入总闸 enableAutoManor（不单列开关） ==="
chk "入口受总闸约束"                  "$M" '- (void)runManorDrawMachineDaily {'
chk "心跳挂点 manorEggWatchTick 内调用" "$M" '[self runManorDrawMachineDaily]'
chk "回包分支已接入"                  "$M" '[self handleManorDrawMachineResponse:opType resData:resData dict:dict]'
chk "任务列表分流已接入"              "$M" '[self handleManorDrawTaskList:taskList]'
chk "头文件声明入口"                  "$H" '-(void)runManorDrawMachineDaily;'
chkno "无独立开关变量"                "$M" 'enableAutoDrawMachine'

# 本节是「当前版本暂不实现」的负向断言，不是「永远不做」。
# 外部跳转口径已复核：链路本身可走（browse + jumpUrl 后台预取 + finishTask，抓包已实证），用户 9/11 定「先不做，后续再动手」。
# 后续启用时先删对应 chkno 行，再改源码；依据见 skill antmanor-tweak-dev/references/external-jump-task-feasibility.md
echo "=== 6. 白名单外当前版本暂不做（小游戏 / 捐款 / 外部跳转） ==="
chkno "不做江苏文旅"                  "$M" 'jiangsuwenlv'
chkno "不做苏心游"                    "$M" 'suxinyou'
chkno "不做捐款任务"                  "$M" 'JUANZENG'
chk "面板日志有抽抽乐条目"            "$M" '蚂蚁庄园 · 抽抽乐'

echo "=== 7. 满 10 自动抽 / 到期当天抽完 / 抽不完自动补抽 ==="
chk "满上限即连抽"                    "$M" 'drawTimes >= maxDraw'
chk "到期当天剩余全抽"                "$M" 'isDateInToday:endDate'
chk "单次上限兜底常量"                "$M" 'kManorDrawMaxDrawTimes   = 10'
chk "兜底值已启用"                    "$M" 'maxDraw = kManorDrawMaxDrawTimes;'
chk "抽不完剩余入补抽队列"            "$M" 'NSInteger left = drawTimes - times;'
chk "补抽方法存在"                    "$M" '- (void)drainManorDrawPending {'
chk "心跳最前面先补抽"                "$M" '[self drainManorDrawPending];'
chk "补抽轮间隔 25s"                  "$M" 'kManorDrawPendInterval = 25.0'
chk "补抽改时长兜底（删 5 轮硬顶）"   "$M" 'kManorDrawPendTimeout'

echo "=== 8. v3.3.2：补抽只在活动最后一天 / 两活动互不覆盖 / 到期清空剩余 ==="
chk   "剩余次数排队加最后一天门"      "$M" 'if (left > 0 && isLastDay) {'
chk   "非最后一天剩余只记不抽"        "$M" '留着不抽（只在活动最后一天才清空）'
chk   "补抽队列按活动分开存（删 cap）" "$M" 'gManorDrawPend[scene] = [@{@"remain": @(left)'
chk   "补抽按场景逐个遍历"            "$M" 'for (NSString *scene in [gManorDrawPend.allKeys copy]) {'
chk   "每日一批门到期当天放开"        "$M" 'if (!isLastDay && [gDailyCompletedTasks containsObject:manorDrawDailyMark(@"PULL", scene)]) return;'
chk   "到期且已封盘仍查一轮清空"      "$M" 'if (!(lastDayScene && leftTimes > 0)) continue;'
chk   "结束时间原值统一解析"          "$M" 'manorDrawDateFromRaw'
chk   "到期日志带剩余天数"            "$M" '活动今天结束（剩余 0 天'
chk   "日期状态按活动缓存"            "$M" 'gManorDrawEndToday[scene] = @(isLastDay);'
chk   "可抽次数按活动缓存"            "$M" 'gManorDrawLastDrawTimes[scene] = @(drawTimes);'
chkno "旧全局队列活动变量已清"        "$M" 'gManorDrawPendScene'
chkno "旧全局剩余次数变量已清"        "$M" 'gManorDrawPendRemain'
chkno "旧全局补抽轮数变量已清"        "$M" 'gManorDrawPendRound'

echo "=== 9. v3.3.3：核对汇总日志（两活动各一条） ==="
chk "汇总日志文案"                    "$M" '核对完成——回包 %lu 项，可执行 %lu 项，跳过 %ld 项'
chk "汇总日志带活动标识"              "$M" '抽抽乐（%@）：核对完成'
chk "跳过数=回包-可执行"              "$M" 'NSInteger skipTotal = (NSInteger)taskList.count - (NSInteger)plan.count;'
chk "非白名单明细附注"                "$M" '（其中非白名单小游戏/捐款/外部跳转 %ld 项）'
chk "汇总后接封盘分支"                "$M" 'skipDetail]];'
n=$(grep -c '核对完成——回包' "$M")
if [ "$n" -eq 1 ]; then echo "  ok   汇总日志只此一处（两活动共用同一函数）"; else echo "  FAIL 汇总日志出现 $n 次"; fail=1; fi
container=$(awk '/^- *\(/ {fn = ($0 ~ /handleManorDrawTaskList/) ? "in" : "out"} /核对完成——回包/ {print fn; exit}' "$M")
chk "两活动由同一循环遍历（各自一条汇总）"  "$M" 'for (NSString *scene in @[kManorDrawSceneDaily, kManorDrawSceneIP]) {'
if [ "$container" = "in" ]; then echo "  ok   汇总日志位于 handleManorDrawTaskList 内"; else echo "  FAIL 汇总日志不在两活动共用函数内（$container）"; fail=1; fi

echo "=== 10. v3.3.4：白名单外任务留痕（纯日志、零行为改动） ==="
chk "未收录任务日志文案"                "$M" '未收录任务「%@」'
chk "日志含标识/状态/进度"              "$M" '｜标识:%@｜状态:%@｜进度:%ld/%ld｜'
chk "日志含模式/动作/组"                "$M" '｜模式:%@｜动作:%@｜组:%@｜'
chk "日志含描述/内嵌页"                 "$M" '｜描述:%@｜内嵌页:%@'
chk "组标识取自 iepTaskTracer"          "$M" 'rangeOfString:@"groupId:"'
chk "内嵌页沿用既有解析"                "$M" 'manorDrawInnerPageURL(targetUrl)'
chk "同 标识+状态+进度 去重"            "$M" 'gManorDrawUnknownSeen containsObject:seenKey'
chk "未收录项仍计入跳过数"              "$M" 'skipped++;'
chk "未收录项仍零请求（只留痕）"        "$M" 'logManorDrawUnknownTask:task scene:scene taskId:taskId status:status];   // v3.3.4 探针：只留痕，不改行为'
n=$(grep -c 'logManorDrawUnknownTask' "$M")
if [ "$n" -eq 2 ]; then echo "  ok   探针只此一处调用（另一次为方法定义）"; else echo "  FAIL logManorDrawUnknownTask 出现 $n 次"; fail=1; fi
p=$(awk '/^- *\(/ {fn = ($0 ~ /handleManorDrawTaskList/) ? "in" : "out"} /logManorDrawUnknownTask:task scene:scene/ {print fn; exit}' "$M")
if [ "$p" = "in" ]; then echo "  ok   探针落在 handleManorDrawTaskList 内（两活动共用）"; else echo "  FAIL 探针不在两活动共用函数内（$p）"; fail=1; fi

echo "=== 11. v3.3.5：VIEW/JUMP 访问型任务（去芭芭农场逛一逛）纳入派单 ==="
chk "任务级分组判定函数"                "$M" 'static NSString *manorDrawTaskGroupForTask(NSDictionary *task) {'
chk "派单口径改用任务级判定"            "$M" 'NSString *group = manorDrawTaskGroupForTask(task);'
chk "先走白名单，再走字段规则"          "$M" 'NSString *group = manorDrawTaskGroup(taskId);'
chk "VIEW 模式门槛"                     "$M" '[mode isEqualToString:@"VIEW"]'
chk "JUMP 动作门槛"                     "$M" '[action isEqualToString:@"JUMP"]'
chk "访问型组标识 VISIT"                "$M" 'return @"VISIT";'
chk "needAct 纳入 VISIT"                "$M" '|| [group isEqualToString:@"VISIT"]));'
chk "needClaim 纳入 VISIT"              "$M" '[group isEqualToString:@"VISIT"] || claimOnly);'
chk "访问型动作报文（doFarmTask）"      "$M" '- (void)doManorDrawVisitTask:(NSString *)taskId taskSceneCode:(NSString *)taskScene {'
chk "访问型派发挂点"                    "$M" '[self doManorDrawVisitTask:taskId taskSceneCode:ts];'
chk "访问型 source=antfarm_villa（抓包）" "$M" '\"source\":\"antfarm_villa\"'
chk "领奖 source 参数化（默认 icon）"    "$M" '(source.length ? source : @"icon")'
chk "领奖按组选 source"                 "$M" 'NSString *claimSource = [group isEqualToString:@"VISIT"] ? @"antfarm_villa" : @"icon";'
chk "访问型不套 15s 停留"               "$M" 'needAct && [group isEqualToString:@"SHOP"]) ? kManorDrawShopBrowseWait'
chk "面板名 芭芭农场逛逛"               "$M" 'return @"芭芭农场逛逛";'
chk "回包归属认 BBNC_GYG"               "$M" 'rangeOfString:@"BBNC_GYG"'
chkno "派单不写死单个 taskId"           "$M" '[taskId isEqualToString:@"IP_BBNC_GYG26"]'
r=$(awk '/^- *\(/ {fn = ($0 ~ /handleManorDrawTaskList/) ? "in" : "out"} /manorDrawTaskGroupForTask\(task\)/ {print fn; exit}' "$M")
if [ "$r" = "in" ]; then echo "  ok   任务级判定落在两活动共用函数内"; else echo "  FAIL 任务级判定不在 handleManorDrawTaskList 内（$r）"; fail=1; fi

echo "=== 12. v3.2.7：活动剩余天数入日志 / 最后一天抽得完 / 并发按活动隔离 ==="
chk "剩余天数口径函数（自然日差）"      "$M" 'static NSInteger manorDrawRemainingDays(NSDate *endDate) {'
chk "口径按 startOfDay 自然日差"        "$M" '[cal startOfDayForDate:endDate]'
chk "最后一天文案=今天结束+剩余0天"     "$M" '活动今天结束（剩余 0 天%@）'
chk "天数未知不写成 0 天"               "$M" 'return @"剩余天数未知";'
chk "正数天数文案"                      "$M" '活动剩余 %ld 天%@'
chk "结束时间兜底=毫秒倒计时"           "$M" 'drawMachineCountDownVO'
chk "倒计时字段 expirationDuration"     "$M" 'expirationDuration'
chk "activity 兼容数组形态"             "$M" '[resData[@"drawMachineActivity"] isKindOfClass:NSArray.class]'
chk "剩余天数按活动缓存"                "$M" 'gManorDrawRemainDays[scene] = @(remainDays);'
chk "结束时刻按活动缓存"                "$M" 'gManorDrawEndAt[scene] = @([endDate timeIntervalSince1970]);'
chk "满次连抽日志带天数"                "$M" '已积满 %ld 次（%@）'
chk "未满不抽日志带天数"                "$M" '未满不抽（满 %ld 自动连抽）'
chk "到期全抽日志带天数"                "$M" '：%@，剩余 %ld 次全部抽掉…'
chk "连抽完成日志带剩余天数"            "$M" '｜%@", manorDrawDaysText(sceneDays, sceneEndAt)'
chk "0 次机会日志也带天数"              "$M" '当前 0 次机会，今日不抽（%@）'
chk "在途批次按活动登记"                "$M" 'gManorDrawInFlight[scene] = @{@"times": @(times)'
chk "回包按唯一在途认领"                "$M" 'drawScene = inFlightKeys.firstObject;'
chk "在途过期窗口"                      "$M" 'kManorDrawInFlightWindow'
chk "降级单抽计数按活动隔离"            "$M" 'gManorDrawRetryRemain[drawScene] = @(retryRemain);'
chk "降级预算=被拒批次数（不写死10）"   "$M" 'retryRemain = drawBatchTimes;'
chk "只有连抽被拒才降级（断自续杯）"   "$M" 'if (retryRemain <= 0 && drawBatchTimes > 1) {'
chk "单抽被拒不自我续杯（终态日志）"    "$M" '单次抽奖未被接受（当日第 %ld 次），本轮不重试'
chk "被拒到顶当日停抽（熔断）"          "$M" '当日已被拒 %ld 次，今日停止抽奖'
chk "被拒上限常量"                      "$M" 'kManorDrawRejectLimit'
chk "被拒计数按日清零"                  "$M" 'gManorDrawRejectCount removeAllObjects'
chk "预算跑完有收尾日志"                "$M" '逐次单抽已跑完本轮预算'
chk "抽奖归属不明时不碰按活动状态"      "$M" '无法归属活动，本轮跳过'
chk "任务上下文按 scene|taskId 存"      "$M" 'static void manorDrawActContextSet(NSString *scene, NSString *taskId, NSString *group) {'
chk "领奖前短路只读本任务上下文"        "$M" 'manorDrawActContextFailedRecently(scene, taskId, 12.0)'
chk "回执按回包反查上下文"              "$M" 'manorDrawActContextResolve(resData, dict)'
chk "上下文过期闸门"                    "$M" 'manorDrawActContextLive'
chk "补抽自推进方法"                    "$M" '- (void)scheduleManorDrawPendingDrain {'
chk "自推进代次防叠加"                  "$M" 'if (seq != gManorDrawPendDrainSeq) return;'
chk "补抽时长兜底常量"                  "$M" 'kManorDrawPendTimeout'
chkno "旧 cap 截断已删（抽不完根因）"   "$M" 'NSInteger cap = maxDraw * kManorDrawPendMaxRounds'
chkno "旧 5 轮硬顶常量已删"             "$M" 'kManorDrawPendMaxRounds'
chkno "旧单全局在途归属已删"            "$M" 'gManorDrawLastDrawScene'
chkno "旧单全局降级活动已删"            "$M" 'gManorDrawRetryScene'
chkno "旧单全局降级计数已删"            "$M" 'NSInteger gManorDrawRetryRemain = 0'
chkno "旧任务上下文全局已删"            "$M" 'gManorDrawActTaskId ='
chkno "旧 millis 直判已删"              "$M" 'else if (raw > 1000000000LL)'
chkno "旧毫秒串日志已删"                "$M" '活动今日结束（endTime='
echo "  ---- 版本号（信息型，不作为门）----"
grep -o 'v3\.2\.[0-9]*' PortEntry.m | head -1 | sed 's/^/    PortEntry 版本串: /'
grep -m1 '^Version:' antforest/Package/DEBIAN/control | sed 's/^/    control: /'

echo
if [ "$fail" -eq 0 ]; then echo "全部通过"; else echo "存在失败项"; fi
exit "$fail"
