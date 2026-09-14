#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bg="$root/antforest/DebugTool/BgRun.m"
tool="$root/antforest/DebugTool/Tool.m"
xml="$root/antforest/DebugTool/XMLReader.m"
mgr="$root/antforest/AntForestManager.m"

grep -Fq '_bgTaskIdentifier = UIBackgroundTaskInvalid;' "$bg"
grep -Fq 'if (self.bgTaskIdentifier != UIBackgroundTaskInvalid || self.bgTaskTimer.valid) return;' "$bg"
grep -Fq '[NSURL fileURLWithPath:cafFilePath]' "$bg"
grep -Fq '[self.bgTaskTimerbadge invalidate];' "$bg"
grep -Fq 'setDateFormat:@"yyyy-MM-dd HH:mm:ss"' "$tool"
grep -Fq 'self.errorPointer = error;' "$xml"
grep -Fq 'if (self.errorPointer)' "$xml"
grep -Fq 'patrolProbeLogIOQueue' "$mgr"
grep -Fq 'dispatch_queue_create("antforest.probe-log-io", DISPATCH_QUEUE_SERIAL)' "$mgr"
grep -Fq 'arc4random_uniform(10)' "$mgr"
echo '第三轮回归检查通过'
