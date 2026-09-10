#!/bin/sh
set -eu

source_file="$(dirname "$0")/../antforest/AntForestManager.m"
header_file="$(dirname "$0")/../antforest/AntForestManager.h"

echo "[1/9] Checking 统一发送口 manorSendRPC（全文只有它碰 _doFlushMessageQueue）..."
grep -Fq 'static void manorSendRPC(id bridge, id arg, id url) {' "$source_file"
grep -Fq 'sel_registerName("_doFlushMessageQueue:url:")' "$source_file"
grep -Fq 'manorSendRPC(' "$source_file"

echo "[2/9] Checking 庄园目标 URL（庄园 H5，绝不用森林地址兜底）..."
grep -Fq 'kManorH5FallbackUrl = @"https://render.alipay.com/p/yuyan/180020010001247569/index.html"' "$source_file"
grep -Fq -- '- (NSString *)manorRPCUrlString {' "$source_file"
grep -Fq -- '-(NSString *)manorRPCUrlString;' "$header_file"
grep -Fq '[self manorRPCUrlString]' "$source_file"
grep -Fq '[self effectiveUrlForBridge:self.manorBridge]' "$source_file"

echo "[3/9] Checking 负向：庄园 RPC 不再拿森林 h5app 地址兜底..."
if grep -Fq 'self.manorH5Url ?: @"https://66666674.h5app.alipay.com/www/index.html"' "$source_file"; then
    echo "❌ 庄园 RPC 仍以森林地址兜底（庄园 WebView 不认 → 无回包、服务端无动作）"
    exit 1
fi
if grep -Fq 'eggsent' "$source_file" && grep -Fq '_doFlushMessageQueue' "$source_file"; then
    left=$(grep -o '_doFlushMessageQueue' "$source_file" | wc -l | tr -d ' ')
    if [ "$left" -ne 1 ]; then
        echo "❌ 仍有 $left 处直接调用 _doFlushMessageQueue（应全部走 manorSendRPC）"
        exit 1
    fi
fi

echo "[4/9] Checking operationType FIFO 队列（push/pop/remove/clear）..."
grep -Fq 'static NSMutableArray<NSString *> *gManorPendingOps = nil;' "$source_file"
grep -Fq 'static void manorPushPendingOp(NSString *op) {' "$source_file"
grep -Fq 'static NSString *manorPopPendingOp(void) {' "$source_file"
grep -Fq 'static void manorRemovePendingOp(NSString *op) {' "$source_file"
grep -Fq 'static void manorClearPendingOps(void) {' "$source_file"
grep -Fq 'manorPushPendingOp(manorOpInArg(arg));' "$source_file"

echo "[5/9] Checking 只关联庄园 op（森林/海洋等不入队）..."
grep -Fq 'if (![op containsString:@"com.alipay.antfarm."]) return;' "$source_file"
grep -Fq 'static NSString *manorOpInArg(id arg) {' "$source_file"

echo "[6/9] Checking 回包关联（自带 op 优先，否则按发送顺序 FIFO 取）..."
grep -Fq 'NSString *assocOp = manorPopPendingOp();' "$source_file"
grep -Fq 'manorRemovePendingOp(opType);' "$source_file"
grep -Fq 'self.lastRpcOperationType = assocOp;' "$source_file"
grep -Fq '回包未带 operationType，按发送顺序关联' "$source_file"

echo "[7/9] Checking 负向：不再把从未赋值的 lastRpcOperationType 当唯一兜底..."
if grep -Fq 'resData[@"operationType"] ?: (self.lastRpcOperationType ?: @"")' "$source_file"; then
    echo "❌ 回包 op 仍只依赖 lastRpcOperationType（该属性全仓无赋值点 → 回包分支永远进不去）"
    exit 1
fi

echo "[8/9] Checking 换 Bridge 清空 FIFO（防旧请求错位）..."
grep -Fq 'gManorHeldBridge != self.manorBridge' "$source_file"
grep -Fq 'manorClearPendingOps();   // 换页' "$source_file"

echo "[9/9] Checking registerBridge 庄园分支（自动学习庄园 H5 地址）..."
grep -Fq 'self.manorH5Url = effectiveUrl;' "$source_file"
grep -Fq 'lowerUrl containsString:@"180020010001247569"' "$source_file"

echo "✅ RPC 关联与庄园 URL 检查通过"
