#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
port_file="$(dirname "$0")/../PortEntry.m"

echo "[1/6] Checking panel-log pipeline (recordStage -> addLog -> logRecord -> LogUpdated)..."
grep -Fq 'recordStage:' "$source_file"
grep -Fq 'if (self.logRecord)' "$source_file"
grep -Fq 'LogUpdated' "$source_file"
grep -Fq 'logRecord' "$port_file"

echo "[2/6] Checking expel-visitor panel logs (request / server-confirmed / failed)..."
grep -Fq '正在赶走偷吃的小鸡' "$source_file"
grep -Fq '已赶走一只偷吃的小鸡' "$source_file"
grep -Fq '赶走小鸡未成功' "$source_file"
grep -Eq 'containsString:.*sendBackAnimal' "$source_file"
grep -Fq 'gLastExpelledTail' "$source_file"

echo "[3/6] Checking sleep panel logs (start / success / once-a-day diagnostics)..."
grep -Fq '天黑了，正在送小鸡回家庭别墅睡觉' "$source_file"
grep -Fq '小鸡已在家庭别墅睡着' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_wait"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_cool"' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"sleep_bridge"' "$source_file"
grep -Fq 'if (isManorSleepDoneToday()) return;' "$source_file"

echo "[4/6] Checking family-sign panel logs (start / success / timeout / sync / daily gate)..."
grep -Fq '正在执行家庭签到' "$source_file"
grep -Fq '家庭签到成功（+亲密值）' "$source_file"
grep -Fq '家庭签到跳过（庄园桥接未就绪）' "$source_file"
grep -Fq 'recordEggDiagOnce(self, @"familysign_bridge"' "$source_file"
grep -Fq '家庭签到回包超时' "$source_file"
grep -Fq '正在同步家庭状态（亲密值）' "$source_file"
grep -Fq 'if (isManorFamilySignDoneToday()) return;' "$source_file"

echo "[5/6] Checking 「当天已完成」不再逐轮刷屏（当天成功后静默）..."
if grep -Fq '家庭签到今天已完成' "$source_file"; then
    echo "❌ 家庭签到当天成功后不应再逐轮提示「已完成，无需重复」"
    exit 1
fi
if grep -Fq '小鸡今天已经在家庭别墅睡过了' "$source_file"; then
    echo "❌ 小鸡当天睡过后不应再逐轮提示「已经在家庭别墅睡过了」"
    exit 1
fi

echo "[6/6] Checking hide-finance outputs NO panel log (功能类，非后台自动化)..."
if grep -Fq '隐藏理财：已隐藏底部' "$port_file" || grep -Fq '隐藏理财：已恢复底部' "$port_file"; then
    echo "❌ 隐藏理财是功能类，不应输出页签变化日志"
    exit 1
fi
if grep -Fq '隐藏理财 · 功能已' "$port_file"; then
    echo "❌ 隐藏理财是功能类，不应输出开关动作日志"
    exit 1
fi

echo "✅ All panel-log checks passed successfully!"
