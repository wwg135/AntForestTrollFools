#!/usr/bin/env bash
# 抽抽乐（DrawMachine）自动攒次数 + 一键连抽 —— 结构自检
# 口径来源：manor_probe 抓包 2026-09-11（两个活动字段完全对称）
# 用户口径：平时不抽，积满 10 次才连抽；活动当天结束则剩余全抽；当天只跑一轮，跑完即收工（防风控）
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

echo "=== 4. 当天只跑一轮，跑完即收工（防风控） ==="
chk "每活动当天一轮标记 ROUND"        "$M" 'manorDrawDailyMark(@"ROUND"'
chk "任务列表当天只处理一次 HANDLED"  "$M" 'manorDrawDailyMark(@"HANDLED"'
chk "已抽标记 PULL"                   "$M" 'manorDrawDailyMark(@"PULL"'

echo "=== 5. 并入总闸 enableAutoManor（不单列开关） ==="
chk "入口受总闸约束"                  "$M" '- (void)runManorDrawMachineDaily {'
chk "心跳挂点 manorEggWatchTick 内调用" "$M" '[self runManorDrawMachineDaily]'
chk "回包分支已接入"                  "$M" '[self handleManorDrawMachineResponse:opType resData:resData dict:dict]'
chk "任务列表分流已接入"              "$M" '[self handleManorDrawTaskList:taskList]'
chk "头文件声明入口"                  "$H" '-(void)runManorDrawMachineDaily;'
chkno "无独立开关变量"                "$M" 'enableAutoDrawMachine'

echo "=== 6. 白名单外一律不下手（小游戏 / 捐款 / 外部跳转） ==="
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
