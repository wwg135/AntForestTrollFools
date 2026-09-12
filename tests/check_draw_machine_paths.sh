#!/usr/bin/env bash
# 抽抽乐（DrawMachine）自动攒次数 + 一键连抽 —— 结构自检
# 口径来源：manor_probe 抓包 2026-09-11 首发 + 2026-09-12 手动做满两活动全流程
# 用户口径：平时不抽，积满 10 次才连抽；活动当天结束则剩余全抽；当天没做满就一直执行
# 9/12 定案：回包任务项不含 taskSceneCode（只在请求里），分流改按白名单 taskId/bizKey 认；FINISHED=只领奖，TODO=动作+领奖
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
chk "动作失败标记来自回包"             "$M" 'gManorDrawActFailed = !ok'
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
chk "补抽轮数封顶（防风控）"          "$M" 'kManorDrawPendMaxRounds'

echo
if [ "$fail" -eq 0 ]; then echo "全部通过"; else echo "存在失败项"; fi
exit "$fail"
