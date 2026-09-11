//
//  AntForestManager.m
//  antforest
//
//  Created by walt-chenp.
//

#import "AntForestManager.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Tool.h"

// ===== 庄园 RPC 发送口（2026-09-11 修正）：目标 URL + operationType FIFO 关联 =====
// ① URL：庄园 RPC 必须发往庄园 H5。原来 16 处全部用「森林」地址兜底（66666674.h5app.alipay.com），
//    庄园 WebView 不认这批消息 → 服务端无动作也没有回包。
//    真机症状：高级饲料「连喂 15 个未收到成功回执」、普通饲料与收蛋永远没有成功日志。
static NSString * const kManorH5FallbackUrl = @"https://render.alipay.com/p/yuyan/180020010001247569/index.html";
// ② 关联：庄园回包不带 operationType（dict/resData 里都没有）。只按字段猜 op，会让
//    「喂鸡 / 收蛋 / 高级饲料」等回包分支永远进不去，所以发请求时把 op 入队、回包按发送顺序取（照 AntManor gPendingOps）。
static NSMutableArray<NSString *> *gManorPendingOps = nil;

static void manorPushPendingOp(NSString *op) {
    if (![op isKindOfClass:NSString.class] || !op.length) return;
    if (![op containsString:@"com.alipay.antfarm."]) return;   // 只关联庄园 RPC，森林/海洋等一律不入队
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ gManorPendingOps = [NSMutableArray array]; });
    @synchronized (gManorPendingOps) {
        while (gManorPendingOps.count >= 12) [gManorPendingOps removeObjectAtIndex:0];
        [gManorPendingOps addObject:op];
    }
}

static NSString *manorPopPendingOp(void) {
    if (!gManorPendingOps) return nil;
    @synchronized (gManorPendingOps) {
        if (!gManorPendingOps.count) return nil;
        NSString *op = gManorPendingOps[0];
        [gManorPendingOps removeObjectAtIndex:0];
        return op;
    }
}

static void manorRemovePendingOp(NSString *op) {
    if (!gManorPendingOps || !op.length) return;
    @synchronized (gManorPendingOps) {
        NSUInteger idx = [gManorPendingOps indexOfObject:op];
        if (idx != NSNotFound) [gManorPendingOps removeObjectAtIndex:idx];
    }
}

static void manorClearPendingOps(void) {
    if (!gManorPendingOps) return;
    @synchronized (gManorPendingOps) { [gManorPendingOps removeAllObjects]; }
}

static NSString *manorOpInArg(id arg) {
    if (![arg isKindOfClass:NSString.class]) return nil;
    NSString *text = (NSString *)arg;
    NSRange r = [text rangeOfString:@"\"operationType\":\""];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [text substringFromIndex:NSMaxRange(r)];
    NSRange end = [rest rangeOfString:@"\""];
    if (end.location == NSNotFound) return nil;
    return [rest substringToIndex:end.location];
}

static void manorSendRPC(id bridge, id arg, id url) {
    if (!bridge || !arg) return;
    manorPushPendingOp(manorOpInArg(arg));
    ((void (*)(id, SEL, id, id))objc_msgSend)(bridge, sel_registerName("_doFlushMessageQueue:url:"), arg, url);
}


@implementation AntForestManager

static AntForestManager *afm = nil;
static NSDate *lastCollectStartedAt = nil;
static NSString *lastScheduledMinute = nil;
static NSMutableSet<NSString *> *recordedCollectedBubbles = nil;
static NSMutableSet<NSString *> *pendingCollectBubbles = nil;
static NSMutableSet<NSString *> *takeLookVisitedFriends = nil;
static NSString *takeLookCurrentFriendId = nil;
static BOOL takeLookRunning = NO;
static BOOL takeLookWaitingForFriend = NO;
static NSUInteger takeLookRounds = 0;
static NSUInteger takeLookRequestToken = 0;
static NSUInteger takeLookPass = 0;
static NSUInteger takeLookTotalRounds = 0;
static const NSUInteger kTakeLookMaxRounds = 150;
static const NSUInteger kTakeLookMaxPasses = 3;
static BOOL rankScanPending = NO;
static NSUInteger collectionCycle = 0;
static BOOL selfPriorityPending = NO;
static NSUInteger selfPriorityCycle = 0;
static NSMutableArray<NSString *> *deferredFriendRankIds = nil;
static NSArray<NSString *> *deferredRankedFriendIds = nil;
static NSString *lastWaterScheduledMinute = nil;
static BOOL waterRunning = NO;
static BOOL waterAwaitingHome = NO;
static BOOL waterAwaitingLimit = NO;
static BOOL waterAwaitingTransfer = NO;
static NSUInteger waterRequestToken = 0;
static NSUInteger waterRetryCount = 0;
static NSUInteger waterTransferRetryCount = 0;
static const NSTimeInterval kWaterTransferCooldown = 1.5;
static NSUInteger waterTargetCount = 0;
static NSUInteger waterSucceededCount = 0;
static NSUInteger waterQueueIndex = 0;
static NSArray<NSString *> *waterQueue = nil;
static NSString *waterCurrentUserId = nil;
static NSString *waterCurrentBizNo = nil;
static NSString *waterRunReason = nil;
static BOOL waterFriendRefreshPending = NO;
static BOOL waterLaunchAttempted = NO;
static BOOL collectAfterLaunchWater = NO;
static NSMutableArray<NSString *> *reviveQueue = nil;
static NSMutableSet<NSString *> *reviveQueuedIds = nil;
static BOOL reviveRunning = NO;
static NSString *reviveCurrentUserId = nil;
static NSUInteger reviveRequestToken = 0;
static BOOL reviveRewardRefreshNeeded = NO;
static NSMutableSet<NSString *> *todayCollectedAnimalKeys = nil;
static NSMutableDictionary<NSString *, NSNumber *> *lastAnimalCollectAttemptTimes = nil;
static NSMutableSet<NSString *> *shieldReportedFriendsInRound = nil;

// 定义一个全局串行队列
dispatch_queue_t globalSerialQueueQuery;
dispatch_queue_t globalSerialQueueCollect;
dispatch_queue_t globalSerialQueueTest;

+(id)sharedInstance{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        afm=[[self alloc]init];
#if !ENABLE_PROBE_LOGS
        [afm clearProbeLogs];
#endif
        
        // 创建一个串行队列
        globalSerialQueueQuery = dispatch_queue_create("antforest_query", DISPATCH_QUEUE_SERIAL);
        globalSerialQueueCollect = dispatch_queue_create("antforest_collect", DISPATCH_QUEUE_SERIAL);
        globalSerialQueueTest = dispatch_queue_create("antforest_test", DISPATCH_QUEUE_SERIAL);
        recordedCollectedBubbles = [NSMutableSet set];
        pendingCollectBubbles = [NSMutableSet set];
        takeLookVisitedFriends = [NSMutableSet set];
        deferredFriendRankIds = [NSMutableArray array];
        reviveQueue = [NSMutableArray array];
        reviveQueuedIds = [NSMutableSet set];
        todayCollectedAnimalKeys = [NSMutableSet set];
        lastAnimalCollectAttemptTimes = [NSMutableDictionary dictionary];
        shieldReportedFriendsInRound = [NSMutableSet set];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [afm notifyActiveH5PageToRefresh];
                if (afm.enableAutoPatrolNew) {
                    [afm queryMonopolyTaskListWithForce:YES];
                    [afm claimAllVisibleMonopolyRewardsOnWebView];
                }
                if (afm.enableAutoAIFish) {
                    [afm queryAIFishTaskListWithForce:YES];
                    [afm claimAllVisibleAIFishRewardsOnWebView];
                }
                if (afm.enableAutoOceanTasks) {
                    [afm queryOceanTaskListWithForce:YES];
                }
                if (afm.enableAutoRewardTasks) {
                    [afm queryVitalityTaskListWithForce:YES];
                    [afm claimAllVisibleRewardTaskRewardsOnWebView];
                }
                if (afm.enableAutoFarmTasks) {
                    [afm queryFarmTaskListWithForce:YES];
                    [afm claimAllVisibleFarmRewardsOnWebView];
                }
            });
        }];
    });
    return afm;
}

- (NSInteger)waterGrams {
    switch (self.waterEnergyId) {
        case 40: return 18;
        case 41: return 33;
        case 42: return 66;
        default: return 10;
    }
}

+ (NSString *)extractNameFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[ @"displayName", @"userName", @"remarkName", @"name", @"nickName", @"userDisplayName", @"showName", @"realName", @"alias" ]) {
        id val = dict[key];
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) return (NSString *)val;
    }
    for (NSString *subKey in @[ @"userBaseInfo", @"userInfo", @"contact", @"extInfo" ]) {
        id subDict = dict[subKey];
        if ([subDict isKindOfClass:NSDictionary.class]) {
            NSString *nested = [self extractNameFromDictionary:subDict];
            if (nested.length > 0) return nested;
        }
    }
    return nil;
}

+ (NSString *)extractUserIdFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[ @"userId", @"userID", @"uid", @"id" ]) {
        id val = dict[key];
        if ([val isKindOfClass:NSString.class] && [(NSString *)val length] > 0) return (NSString *)val;
        if ([val isKindOfClass:NSNumber.class]) return [(NSNumber *)val stringValue];
    }
    for (NSString *subKey in @[ @"userBaseInfo", @"userInfo", @"contact" ]) {
        id subDict = dict[subKey];
        if ([subDict isKindOfClass:NSDictionary.class]) {
            NSString *nested = [self extractUserIdFromDictionary:subDict];
            if (nested.length > 0) return nested;
        }
    }
    return nil;
}

- (NSString *)waterDisplayNameForUser:(NSString *)uid {
    NSDictionary *contact = [self.friendsName[uid] isKindOfClass:NSDictionary.class] ? self.friendsName[uid] : nil;
    NSString *name = [AntForestManager extractNameFromDictionary:contact];
    if (!name.length) return @"好友";
    return name.length == 1 ? [name stringByAppendingString:@"***"] : [[name substringToIndex:MIN((NSUInteger)2, name.length)] stringByAppendingString:@"***"];
}

- (NSString *)friendDisplayNameForUser:(NSString *)uid {
    if (!uid.length) return @"好友";
    if ([uid isEqualToString:self.myUserId]) return @"自己";
    NSDictionary *contact = [self.friendsName[uid] isKindOfClass:NSDictionary.class] ? self.friendsName[uid] : nil;
    NSString *name = [contact[@"displayName"] isKindOfClass:NSString.class] ? contact[@"displayName"] : nil;
    if (!name.length) name = [contact[@"name"] isKindOfClass:NSString.class] ? contact[@"name"] : nil;
    if (!name.length) name = [AntForestManager extractNameFromDictionary:contact];
    return name.length ? name : @"好友";
}

static NSString *waterTodayKey(void) {
    return getCurrentDateString();
}

static NSMutableDictionary<NSString *, NSNumber *> *waterDailyCounts(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = waterTodayKey();
    if (![[defaults stringForKey:@"waterDailyDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"waterDailyDate"];
        [defaults setObject:@{} forKey:@"waterDailyCounts"];
    }
    NSDictionary *saved = [defaults dictionaryForKey:@"waterDailyCounts"] ?: @{};
    return [saved mutableCopy];
}

static void saveWaterDailyCounts(NSDictionary *counts) {
    [NSUserDefaults.standardUserDefaults setObject:counts forKey:@"waterDailyCounts"];
}

static NSString *waterJSONString(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static id waterFindValue(id value, NSString *key, NSUInteger depth) {
    if (depth > 8) return nil;
    if ([value isKindOfClass:NSDictionary.class]) {
        id direct = value[key];
        if (direct) return direct;
        for (id child in [(NSDictionary *)value allValues]) {
            id found = waterFindValue(child, key, depth + 1);
            if (found) return found;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)value) {
            id found = waterFindValue(child, key, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static BOOL waterResponseSucceeded(id value) {
    id success = waterFindValue(value, @"success", 0);
    if ([success respondsToSelector:@selector(boolValue)] && [success boolValue]) return YES;
    id result = waterFindValue(value, @"resultCode", 0);
    if ([result isKindOfClass:NSString.class] && [result caseInsensitiveCompare:@"SUCCESS"] == NSOrderedSame) return YES;
    result = waterFindValue(value, @"result", 0);
    return [result respondsToSelector:@selector(integerValue)] && [result integerValue] == 1;
}

static NSString *waterResponseCode(id value) {
    id code = waterFindValue(value, @"resultCode", 0);
    return [code isKindOfClass:NSString.class] ? [(NSString *)code uppercaseString] : @"";
}

static BOOL waterResponseInsufficient(id value) {
    for (NSString *key in @[ @"resultCode", @"resultDesc", @"resultMessage", @"errorCode", @"errorMsg", @"message", @"memo", @"desc" ]) {
        id candidate = waterFindValue(value, key, 0);
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *text = [(NSString *)candidate lowercaseString];
        if ([text containsString:@"insufficient"] || [text containsString:@"not enough"] || [text containsString:@"能量不足"] || [text containsString:@"能量不够"]) return YES;
    }
    return NO;
}

static NSString *waterResponseSummary(id value) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[ @"success", @"result", @"resultCode", @"resultDesc", @"resultMessage", @"errorCode", @"errorMsg", @"message", @"memo", @"desc", @"waterLimit" ]) {
        id candidate = waterFindValue(value, key, 0);
        if (!candidate || candidate == NSNull.null) continue;
        NSString *text = [candidate isKindOfClass:NSString.class] ? candidate : [candidate description];
        if (text.length > 80) text = [[text substringToIndex:80] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, text]];
    }
    return parts.count ? [parts componentsJoinedByString:@"，"] : @"未发现状态字段";
}

static BOOL canReviveFriendBubble(NSDictionary *dictRank) {
    if (![dictRank isKindOfClass:NSDictionary.class]) return NO;
    
    // 1. 检查 wateringBubbles 列表中的 fuhuo 气泡或 canProtect 气泡
    NSArray *wBubbles = dictRank[@"wateringBubbles"];
    if ([wBubbles isKindOfClass:NSArray.class]) {
        for (id b in wBubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                if (ext && (ext[@"notProtectReason"] || (ext[@"restTimes"] && [ext[@"restTimes"] integerValue] <= 0))) {
                    return NO;
                }
                if (b[@"canProtect"] != nil && ![b[@"canProtect"] boolValue]) {
                    return NO;
                }
                if ([b[@"canProtect"] boolValue] || [b[@"canRevive"] boolValue] || [b[@"bizType"] isEqualToString:@"fuhuo"]) {
                    return YES;
                }
            }
        }
    }
    
    // 2. 检查 userEnergy 中的 canProtectBubble
    NSDictionary *ue = [dictRank[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dictRank[@"userEnergy"] : nil;
    if (ue && ([ue[@"canProtectBubble"] boolValue] || [ue[@"canReviveBubble"] boolValue])) return YES;
    
    // 3. 检查常规字段
    for (NSString *key in @[ @"canProtectBubble", @"canProtect", @"protectBubble", @"canProtectEnergy", @"canRevive", @"canReviveBubble", @"giftingEnergy", @"giftEnergy", @"energyRevive", @"reviveBubble", @"hasProtectBubble" ]) {
        id val = dictRank[key];
        if (val && val != NSNull.null) {
            if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) return YES;
            if ([val isKindOfClass:NSString.class] && ([(NSString *)val length] > 0 && ![(NSString *)val isEqualToString:@"0"] && ([(NSString *)val caseInsensitiveCompare:@"false"] != NSOrderedSame))) return YES;
        }
    }
    id pStatus = dictRank[@"protectStatus"] ?: dictRank[@"reviveStatus"];
    if (pStatus && pStatus != NSNull.null) {
        if ([pStatus respondsToSelector:@selector(integerValue)] && [pStatus integerValue] == 1) return YES;
        if ([pStatus isKindOfClass:NSString.class] && ([(NSString *)pStatus containsString:@"PROTECT"] || [(NSString *)pStatus containsString:@"REVIVE"] || [(NSString *)pStatus containsString:@"CAN"])) return YES;
    }
    return NO;
}

static NSInteger extractRestTimesFromDict(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class]) return -1;
    NSArray *wBubbles = dict[@"wateringBubbles"];
    if ([wBubbles isKindOfClass:NSArray.class]) {
        for (id b in wBubbles) {
            if ([b isKindOfClass:NSDictionary.class]) {
                NSDictionary *ext = [b[@"extInfo"] isKindOfClass:NSDictionary.class] ? b[@"extInfo"] : nil;
                if (ext && ext[@"notProtectReason"]) {
                    return 0;
                }
                if (ext && ext[@"restTimes"] != nil) {
                    return [ext[@"restTimes"] integerValue];
                }
                if (b[@"canProtect"] != nil && ![b[@"canProtect"] boolValue]) {
                    return 0;
                }
            }
        }
    }
    return -1;
}

static NSInteger reviveDailyCount(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *today = getCurrentDateString();
    if (![[defaults stringForKey:@"autoReviveDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"autoReviveDate"];
        [defaults setInteger:0 forKey:@"autoReviveCount"];
        [reviveQueue removeAllObjects];
        [reviveQueuedIds removeAllObjects];
    }
    return [defaults integerForKey:@"autoReviveCount"];
}

- (void)reviveRefreshRewardIfNeeded {
    if (!reviveRewardRefreshNeeded || !self.enableSelfCollect || !self.jsBridge) return;
    reviveRewardRefreshNeeded = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.enableSelfCollect && self.jsBridge) {
            [self recordStage:@"复活奖励：请求本人首页"];
            [self queryMyBubbles];
        }
    });
}

- (void)reviveStopWithReason:(NSString *)reason {
    reviveRunning = NO;
    reviveCurrentUserId = nil;
    reviveRequestToken++;
    [reviveQueue removeAllObjects];
    if (reason.length) [self recordStage:[NSString stringWithFormat:@"复活 · %@", reason]];
    [self reviveRefreshRewardIfNeeded];
}

- (void)reviveSendNext {
    if (!self.enableAutoRevive || !self.jsBridge) {
        if (reviveRunning) [self reviveStopWithReason:@"任务已停止或桥接不可用"];
        return;
    }
    if (reviveDailyCount() >= 6) {
        [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
        [self recordStage:@"复活 · 帮复活能量已达支付宝官方上限（6/6 次）"];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        [reviveQueue removeAllObjects];
        return;
    }
    if (!reviveQueue.count) { reviveRunning = NO; reviveCurrentUserId = nil; [self reviveRefreshRewardIfNeeded]; return; }
    reviveRunning = YES;
    reviveCurrentUserId = reviveQueue.firstObject;
    [reviveQueue removeObjectAtIndex:0];
    NSUInteger token = ++reviveRequestToken;
    NSString *timestamp = [NSString stringWithFormat:@"%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    NSDictionary *body = @{ @"targetUserId": reviveCurrentUserId, @"version": @"20241025", @"source": @"chInfo_ch_appcenter__chsub_9patch" };
    NSDictionary *data = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": @"alipay.antforest.forest.h5.protectBubble", @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": [NSString stringWithFormat:@"revive_%@.%@", timestamp, [AntForestManager getNumberRandom:12]] };
    NSString *queue1 = waterJSONString(@[data]);
    if (!queue1.length) { [self reviveStopWithReason:@"请求编码失败"]; return; }
    NSString *url = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch", reviveCurrentUserId];
    [self recordStage:[NSString stringWithFormat:@"复活 · 请求帮助好友“%@”复活能量", name]];
    manorSendRPC(self.jsBridge, queue1, url);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (reviveRunning && token == reviveRequestToken) [self reviveStopWithReason:@"回包超时，已停止"];
    });
}

- (void)queueAutoReviveForUser:(NSString *)userId {
    if (!self.enableAutoRevive || !userId.length || [userId isEqualToString:self.myUserId]) return;
    if (reviveDailyCount() >= 6) return;
    if (reviveRunning && [reviveCurrentUserId isEqualToString:userId]) return;
    if ([reviveQueue containsObject:userId]) return;
    if ([reviveQueuedIds containsObject:userId]) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[userId]] ?: @"好友";
    [self recordStage:[NSString stringWithFormat:@"复活 · 发现好友“%@”有待复活能量，加入复活队列", name]];
    [reviveQueue addObject:userId];
    if (!reviveRunning) [self reviveSendNext];
}

- (void)handleAutoReviveResponse:(id)args {
    if (!reviveRunning || ![args isKindOfClass:NSDictionary.class]) return;
    NSDictionary *resData = [(NSDictionary *)args[@"resData"] isKindOfClass:NSDictionary.class] ? args[@"resData"] : ([args isKindOfClass:NSDictionary.class] ? args : nil);
    if (!resData) return;
    NSString *name = [AntForestManager extractNameFromDictionary:self.friendsName[reviveCurrentUserId]] ?: @"好友";
    if (waterResponseSucceeded(resData) || [resData[@"success"] boolValue] || [[resData[@"resultCode"] description] isEqualToString:@"SUCCESS"]) {
        NSInteger count = reviveDailyCount();
        if (reviveCurrentUserId.length && ![reviveQueuedIds containsObject:reviveCurrentUserId]) {
            [reviveQueuedIds addObject:reviveCurrentUserId];
            count++;
            [NSUserDefaults.standardUserDefaults setInteger:MIN((NSInteger)6, count) forKey:@"autoReviveCount"];
        }
        [self recordStage:[NSString stringWithFormat:@"复活 · 成功帮助好友“%@”复活能量（今日 %ld/6 次）", name, (long)MIN((NSInteger)6, count)]];
        reviveRewardRefreshNeeded = YES;
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.5 + (arc4random_uniform(1500) / 1000.0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.enableAutoRevive) [self reviveSendNext];
        });
    } else {
        NSString *code = waterResponseCode(resData);
        if ([code isEqualToString:@"TARGET_USER_PROTECT_BY_ENERGY_SHIELD"]) {
            if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
            [self recordStage:[NSString stringWithFormat:@"复活 · 好友“%@”已有能量保护罩，已跳过", name]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            double delaySec = 1.2 + (arc4random_uniform(1000) / 1000.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableAutoRevive) [self reviveSendNext];
            });
            return;
        }
        if ([code containsString:@"LIMIT"] || [code containsString:@"EXCEED"] || [code containsString:@"OVER"] || [code containsString:@"TIRED"] || [code isEqualToString:@"PROTECT_REBORN_TIRED"]) {
            [NSUserDefaults.standardUserDefaults setInteger:6 forKey:@"autoReviveCount"];
            [self recordStage:[NSString stringWithFormat:@"复活 · 帮复活能量已达支付宝官方上限（今天已用完，明天再继续吧）"]];
            reviveRunning = NO;
            reviveCurrentUserId = nil;
            reviveRequestToken++;
            [reviveQueue removeAllObjects];
            return;
        }
        if (reviveCurrentUserId.length) [reviveQueuedIds addObject:reviveCurrentUserId];
        [self recordStage:[NSString stringWithFormat:@"复活 · 帮助好友“%@”复活回包：%@，尝试下一位", name, waterResponseSummary(resData)]];
        reviveRunning = NO;
        reviveCurrentUserId = nil;
        reviveRequestToken++;
        double delaySec = 1.2 + (arc4random_uniform(1000) / 1000.0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.enableAutoRevive) [self reviveSendNext];
        });
    }
}

- (void)waterFinishCurrentFriendWithStatus:(NSString *)status {
    NSString *name = [self waterDisplayNameForUser:waterCurrentUserId];
    if (status.length) [self recordStage:[NSString stringWithFormat:@"浇水 · %@：%@", name, status]];
    waterQueueIndex++;
    waterCurrentUserId = nil;
    waterCurrentBizNo = nil;
    waterTargetCount = 0;
    waterSucceededCount = 0;
    waterRetryCount = 0;
    waterAwaitingHome = waterAwaitingLimit = waterAwaitingTransfer = NO;
    waterRequestToken++;
    [self performSelector:@selector(waterStartNextFriend) withObject:nil afterDelay:kWaterTransferCooldown];
}

- (void)waterStopWithReason:(NSString *)reason {
    if (!waterRunning) return;
    waterRunning = NO;
    waterAwaitingHome = waterAwaitingLimit = waterAwaitingTransfer = NO;
    waterRequestToken++;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 任务结束：%@", reason]];
    waterQueue = nil;
    waterCurrentUserId = nil;
    waterCurrentBizNo = nil;
    if (!collectAfterLaunchWater) return;
    collectAfterLaunchWater = NO;
    if (!self.enableAutoCollect || !self.jsBridge) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self recordStage:@"蚂蚁森林自动浇水结束，开始自动收取"];
        [self autoCollectBubbles];
    });
}

- (void)waterSendRPC:(NSString *)operation body:(NSDictionary *)body {
    if (!self.jsBridge) { [self waterStopWithReason:@"页面通道未连接"]; return; }
    NSString *timestamp = [NSString stringWithFormat:@"%ld", (long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSString *callback = [NSString stringWithFormat:@"water_%@.%@", timestamp, [AntForestManager getNumberRandom:12]];
    NSDictionary *data = @{ @"handlerName": @"rpc", @"data": @{ @"operationType": operation, @"headers": @{ @"source": @"chInfo_ch_appcenter__chsub_9patch", @"ags-source": @"chInfo_ch_appcenter__chsub_9patch" }, @"requestData": @[body], @"getResponse": @YES }, @"callbackId": callback };
    NSString *queue = waterJSONString(@[data]);
    if (!queue.length) { [self waterStopWithReason:@"请求编码失败"]; return; }
    NSString *url = waterCurrentUserId.length ? [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK", waterCurrentUserId] : @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    manorSendRPC(self.jsBridge, queue, url);
}

- (void)waterRequestFriendHome {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingHome = YES;
    waterAwaitingLimit = waterAwaitingTransfer = NO;
    NSDictionary *body = @{ @"userId": waterCurrentUserId, @"version": @"20241025", @"source": @"chInfo_ch_appcenter__chsub_9patch", @"fromAct": @"TAKE_LOOK", @"configVersionMap": @{ @"wateringBubbleConfig": @"0" }, @"skipWhackMole": @NO, @"activityParam": @{}, @"currentEnergy": @99999999, @"currentVitalityAmount": @8888888 };
    [self waterSendRPC:@"alipay.antforest.forest.h5.queryFriendHomePage" body:body];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingHome) return;
        if (waterRetryCount++ == 0) { [self waterRequestFriendHome]; return; }
        [self waterFinishCurrentFriendWithStatus:@"好友主页回包超时，已跳过"];
    });
}

- (void)waterRequestLimit {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingHome = NO;
    waterAwaitingLimit = YES;
    waterRetryCount = 0;
    [self waterSendRPC:@"alipay.antforest.forest.h5.queryMiscInfo" body:@{ @"queryBizType": @"waterLimit", @"source": @"SELF_HOME", @"targetUserId": waterCurrentUserId, @"version": @"20230501" }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingLimit) return;
        if (waterRetryCount++ == 0) { [self waterRequestLimit]; return; }
        [self waterFinishCurrentFriendWithStatus:@"浇水限额回包超时，已跳过"];
    });
}

- (void)waterTransferOnce {
    NSUInteger requestToken = ++waterRequestToken;
    waterAwaitingLimit = NO;
    waterAwaitingTransfer = YES;
    NSDictionary *extInfoDict = self.waterReminderEnabled ? @{
        @"sendChat": @"true",
        @"sendMsg": @"true",
        @"remind": @"true",
        @"remindCollect": @"true",
        @"notice": @"true",
        @"remindFriend": @"true",
        @"fillMsg": @"true",
        @"waterRemind": @"true",
        @"remindText": @"提醒TA来收（7天不收会退回）"
    } : @{
        @"sendChat": @"false",
        @"remind": @"false"
    };
    NSString *extInfoJson = waterJSONString(extInfoDict) ?: @"{}";
    
    NSDictionary *body = @{
        @"bizNo": waterCurrentBizNo,
        @"energyId": @(self.waterEnergyId),
        @"extInfo": extInfoDict,
        @"extInfoStr": extInfoJson,
        @"from": @"",
        @"source": @"chInfo_ch_appcenter__chsub_9patch",
        @"targetUser": waterCurrentUserId,
        @"transferType": @"WATERING",
        @"version": @"20241025"
    };
    [self recordStage:[NSString stringWithFormat:@"浇水 · 诊断：请求第 %lu/%lu 次浇水（提醒=%@）", (unsigned long)(waterSucceededCount + 1), (unsigned long)waterTargetCount, self.waterReminderEnabled ? @"开" : @"关"]];
    [self waterSendRPC:@"alipay.antforest.forest.h5.transferEnergy" body:body];
    [self waterSendRPC:@"alipay.antmember.forest.h5.transferEnergy" body:body];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!waterRunning || requestToken != waterRequestToken || !waterAwaitingTransfer) return;
        if (waterTransferRetryCount++ == 0) {
            waterAwaitingTransfer = NO;
            waterRetryCount = 0;
            [self recordStage:@"浇水 · 收取回包超时，重新获取好友凭据后重试"];
            [self waterRequestFriendHome];
            return;
        }
        [self waterFinishCurrentFriendWithStatus:[NSString stringWithFormat:@"第 %lu 次浇水未确认，已跳过", (unsigned long)(waterSucceededCount + 1)]];
    });
}

- (void)waterStartNextFriend {
    if (!waterRunning) return;
    if (waterQueueIndex >= waterQueue.count) { [self waterStopWithReason:[NSString stringWithFormat:@"%@完成", waterRunReason ?: @"浇水"]]; return; }
    waterCurrentUserId = waterQueue[waterQueueIndex];
    if (!waterCurrentUserId.length || [waterCurrentUserId isEqualToString:self.myUserId]) { [self waterFinishCurrentFriendWithStatus:@"无效好友，已跳过"]; return; }
    NSInteger done = [waterDailyCounts()[waterCurrentUserId] integerValue];
    NSInteger remaining = MAX(0, 3 - done);
    if (!remaining) { [self waterFinishCurrentFriendWithStatus:@"今日已浇满 3 次，已跳过"]; return; }
    waterTargetCount = (NSUInteger)remaining;
    waterSucceededCount = 0;
    waterRetryCount = 0;
    waterTransferRetryCount = 0;
    [self waterRequestFriendHome];
}

- (void)startWateringSelectedFriendsWithReason:(NSString *)reason {
    if (waterRunning) { [self recordStage:@"浇水 · 当前任务仍在执行"]; return; }
    NSArray *friends = [[NSOrderedSet orderedSetWithArray:self.waterFriendIds ?: @[]].array filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *uid, __unused NSDictionary *bindings) { return uid.length > 0; }]];
    if (!friends.count) { [self recordStage:@"浇水 · 未选择好友"]; return; }
    if (!self.jsBridge) { [self recordStage:@"浇水 · 页面通道未连接"]; return; }
    waterRunning = YES;
    waterQueue = friends;
    waterQueueIndex = 0;
    waterRunReason = reason ?: @"手动浇水";
    [self recordStage:[NSString stringWithFormat:@"浇水 · %@开始：%lu 位好友，%ld g，每人补足至每日 3 次", waterRunReason, (unsigned long)friends.count, (long)self.waterGrams]];
    [self waterStartNextFriend];
}

- (void)startLaunchWateringThenCollect {
    BOOL shouldCollect = self.enableAutoCollect;
    if (waterLaunchAttempted) {
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    waterLaunchAttempted = YES;
    if (waterRunning) {
        [self recordStage:@"蚂蚁森林自动浇水跳过：已有浇水任务运行中"];
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    if (!self.waterFriendIds.count) {
        [self recordStage:@"蚂蚁森林自动浇水跳过：未选择好友"];
        if (shouldCollect) [self autoCollectBubbles];
        return;
    }
    collectAfterLaunchWater = shouldCollect;
    [self startWateringSelectedFriendsWithReason:@"蚂蚁森林自动浇水"];
}

- (void)handleWaterResponse:(id)args {
    if (!waterRunning || ![args isKindOfClass:NSDictionary.class]) return;
    if (waterAwaitingHome) {
        NSString *bizNo = [waterFindValue(args, @"bizNo", 0) isKindOfClass:NSString.class] ? waterFindValue(args, @"bizNo", 0) : nil;
        if (!bizNo.length) return;
        waterCurrentBizNo = bizNo;
        [self recordStage:@"浇水 · 已获取好友主页凭据"];
        [self waterRequestLimit];
        return;
    }
    if (waterAwaitingLimit) {
        if (!waterFindValue(args, @"waterLimit", 0)) return;
        [self recordStage:@"浇水 · 已通过浇水限额校验"];
        [self waterTransferOnce];
        return;
    }
    if (!waterAwaitingTransfer) return;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 诊断：收取回包 %@", waterResponseSummary(args)]];
    if (!waterResponseSucceeded(args)) {
        NSString *code = waterResponseCode(args);
        if ([code isEqualToString:@"WATERING_TIMES_LIMIT"]) {
            NSMutableDictionary *counts = waterDailyCounts();
            counts[waterCurrentUserId] = @3;
            saveWaterDailyCounts(counts);
            [self waterFinishCurrentFriendWithStatus:@"服务端确认今日已浇满 3 次，已跳过"];
            return;
        }
        if ([code isEqualToString:@"WATER_NOT_GET_LOCK"] || [code isEqualToString:@"PARAM_ILLEGAL"]) {
            waterAwaitingTransfer = NO;
            waterRequestToken++;
            if (waterTransferRetryCount++ == 0) {
                NSTimeInterval delay = [code isEqualToString:@"WATER_NOT_GET_LOCK"] ? 2.0 : kWaterTransferCooldown;
                [self recordStage:[NSString stringWithFormat:@"浇水 · %@，%.0f 秒后重新获取凭据重试", [code isEqualToString:@"WATER_NOT_GET_LOCK"] ? @"服务端限流" : @"服务端参数异常", delay]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (waterRunning && !waterAwaitingHome && !waterAwaitingLimit && !waterAwaitingTransfer) [self waterRequestFriendHome];
                });
                return;
            }
            [self waterFinishCurrentFriendWithStatus:[NSString stringWithFormat:@"第 %lu 次浇水被服务端拒绝（%@），已跳过", (unsigned long)(waterSucceededCount + 1), code]];
            return;
        }
        if (waterResponseInsufficient(args)) [self waterStopWithReason:@"能量不足"];
        return;
    }
    waterAwaitingTransfer = NO;
    waterRetryCount = 0;
    waterTransferRetryCount = 0;
    waterSucceededCount++;
    NSMutableDictionary *counts = waterDailyCounts();
    counts[waterCurrentUserId] = @([counts[waterCurrentUserId] integerValue] + 1);
    saveWaterDailyCounts(counts);
    [self recordStage:[NSString stringWithFormat:@"浇水 · %@：成功 %lu/%lu，%ld g", [self waterDisplayNameForUser:waterCurrentUserId], (unsigned long)waterSucceededCount, (unsigned long)waterTargetCount, (long)self.waterGrams]];
    if (self.waterReminderEnabled && waterCurrentUserId.length) {
        NSDictionary *remindBody = @{
            @"targetUserId": waterCurrentUserId,
            @"bizType": @"WATERING",
            @"source": @"chInfo_ch_appcenter__chsub_9patch",
            @"version": @"20230501"
        };
        [self waterSendRPC:@"alipay.antmember.forest.h5.waterReminder" body:remindBody];
    }
    if (waterSucceededCount >= waterTargetCount) [self waterFinishCurrentFriendWithStatus:@"本次完成"];
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWaterTransferCooldown * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (waterRunning) [self waterRequestFriendHome]; });
}

- (void)refreshWaterFriends {
    // 好友浇水列表只认本次总能量榜快照，不能混入历史昵称缓存。
    [self.friendsRank removeAllObjects];
    waterFriendRefreshPending = YES;
    [self queryTotalRank];
    [self recordStage:@"浇水 · 已请求刷新好友列表"];
}

- (void)startScheduledWaterTimer {
    [self.scheduledWaterTimer invalidate];
    self.scheduledWaterTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(checkScheduledWater) userInfo:nil repeats:YES];
    [self checkScheduledWater];
}

- (void)checkScheduledWater {
    if (!self.enableAutoWater) return;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init]; formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];
    if (![self.waterScheduledTimes containsObject:time]) return;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *minute = [formatter stringFromDate:NSDate.date];
    if ([lastWaterScheduledMinute isEqualToString:minute]) return;
    lastWaterScheduledMinute = minute;
    [self startWateringSelectedFriendsWithReason:@"定时浇水"];
}

- (void)updateWaterFriendListFromResponse:(NSDictionary *)dict {
    if (!waterFriendRefreshPending) return;
    NSArray *contacts = [dict[@"contactsDicArray"] isKindOfClass:NSArray.class] ? dict[@"contactsDicArray"] : nil;
    if (contacts.count) {
        for (NSDictionary *contact in contacts) {
            NSString *uid = [AntForestManager extractUserIdFromDictionary:contact];
            if (uid.length) self.friendsName[uid] = contact;
        }
    }
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
    NSArray *rankings = [resData[@"totalDatas"] isKindOfClass:NSArray.class] ? resData[@"totalDatas"] : nil;
    if (!rankings.count) rankings = [resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : nil;
    if (!rankings.count) return;
    [self.friendsRank removeAllObjects];
    for (NSDictionary *ranking in rankings) {
        NSString *uid = [AntForestManager extractUserIdFromDictionary:ranking];
        if (uid.length) {
            self.friendsRank[uid] = ranking[@"rank"] ?: @0;
            NSString *name = [AntForestManager extractNameFromDictionary:ranking];
            if (name.length) {
                NSMutableDictionary *contact = [self.friendsName[uid] mutableCopy] ?: [NSMutableDictionary dictionary];
                contact[@"displayName"] = name;
                self.friendsName[uid] = contact;
            }
        }
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.friendsName requiringSecureCoding:NO error:nil];
    if (data) {
        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    waterFriendRefreshPending = NO;
    [self recordStage:[NSString stringWithFormat:@"浇水 · 好友列表刷新完成：%lu 位", (unsigned long)self.friendsRank.count]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WaterFriendListUpdated" object:nil];
}

- (void)releaseSelfPriorityForCycle:(NSUInteger)cycle reason:(NSString *)reason {
    if (!selfPriorityPending || selfPriorityCycle != cycle) return;
    selfPriorityPending = NO;
    NSArray<NSString *> *friendIds = deferredFriendRankIds.copy;
    NSArray<NSString *> *rankedIds = deferredRankedFriendIds;
    [deferredFriendRankIds removeAllObjects];
    deferredRankedFriendIds = nil;
    [self recordStage:[NSString stringWithFormat:@"本人优先完成，开始好友扫描（%@）", reason]];
    for (NSString *friendId in friendIds) {
        dispatch_async(globalSerialQueueQuery, ^{
            [self queryFriendsBubbles:friendId];
        });
    }
    if (rankedIds.count) [self scanRankedFriends:rankedIds cycle:cycle];
}

+ (NSLock*)sharedLock {
    static NSLock *sharedLock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedLock = [[NSLock alloc] init];
    });
    return sharedLock;
}

- (void)recordStage:(NSString *)stage {
    if (!stage.length) return;
    if ([stage hasPrefix:@"诊断 ·"]) {
        NSLog(@"[AntForestPort][Diag] %@", stage);
        return;
    }
    NSString *cleanStage = stage;
    if ([cleanStage hasPrefix:@"收取 · "]) {
        cleanStage = [cleanStage substringFromIndex:@"收取 · ".length];
    } else if ([cleanStage hasPrefix:@"收取 ·"]) {
        cleanStage = [cleanStage substringFromIndex:@"收取 ·".length];
    }
    if (self.logRecord) [self addLog:[NSString stringWithFormat:@"%@\n%@", getCurrentDateTimeString(), cleanStage]];
}

static NSMutableArray<NSString *> *patrolProbeLogs = nil;

static BOOL isNoiseProbeLog(NSString *log) {
    if (!log) return YES;
    if ([log containsString:@"deliverByPageId"] ||
        [log containsString:@"ANTFOREST_GAME_CENTER_FLOW"] ||
        [log containsString:@"offlineResources"] ||
        [log containsString:@"manifest.json"] ||
        [log containsString:@"runtime."] ||
        [log containsString:@"all_vendor."] ||
        [log containsString:@"galacean_downgrade"] ||
        [log containsString:@"signInWarmCopyConfig"] ||
        [log containsString:@"swiper.min"] ||
        [log containsString:@"dataPrefetch"] ||
        [log containsString:@"contactsDicArray"] ||
        [log containsString:@"recentApps"] ||
        [log containsString:@"systemMemoryLevel"] ||
        [log containsString:@"screenReaderEnabled"] ||
        [log containsString:@"SHOULDUSENEWTOUCHEVENT"] ||
        [log containsString:@"\"safeArea\""] ||
        [log containsString:@"queryFriendHomePage"] ||
        [log containsString:@"setAPDataStorage"] ||
        [log containsString:@"getAPDataStorage"] ||
        [log containsString:@"batchQuerySendTreeItems"] ||
        [log containsString:@"querySendTreeFriendList"]) {
        return YES;
    }
    return NO;
}

+ (BOOL)isManorURL:(NSURL *)url {
    if (!url) return NO;
    NSString *text = [url.absoluteString lowercaseString];
    if ([text containsString:@"180020010001247580"] || [text containsString:@"home.html"]) return NO; // 森林首页
    if ([text containsString:@"180020010001263018"] || [text containsString:@"68687599"] || [text containsString:@"babafarm"] || [text containsString:@"alipayfarm"]) return NO; // 芭芭农场
    if ([text containsString:@"2021003115672468"] || [text containsString:@"antocean"]) return NO; // 神奇海洋
    return [text containsString:@"66666674"] ||
           [text containsString:@"2017090512380701"] ||
           [text containsString:@"antfarm"] ||
           [text containsString:@"ant_farm"];
}

+ (BOOL)isManorResponse:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = (NSDictionary *)value;
    NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : dict;
    
    // 明确的森林与农场回包，绝不当做庄园处理！
    if (dict[@"bubbles"] || resData[@"bubbles"] ||
        dict[@"wateringBubbles"] || resData[@"wateringBubbles"] ||
        dict[@"totalDatas"] || resData[@"totalDatas"] ||
        dict[@"friendRanking"] || resData[@"friendRanking"] ||
        dict[@"combineHandlerVOMap"] || resData[@"combineHandlerVOMap"] ||
        dict[@"limitedTimeChallenge"] || resData[@"limitedTimeChallenge"] ||
        dict[@"manureFactory"] || resData[@"manureFactory"] ||
        dict[@"subplotsActivityList"] || resData[@"subplotsActivityList"]) {
        return NO;
    }
    
    NSString *opType = [NSString stringWithFormat:@"%@", (dict[@"operationType"] ?: resData[@"operationType"]) ?: @""];
    if ([opType containsString:@"com.alipay.antfarm"] || [opType containsString:@"antfarm."]) return YES;
    
    // 庄园进入主页核心结构：包含 subFarmVO 或 dynamicGlobalConfig 或 farmTaskList
    if (resData[@"subFarmVO"] || dict[@"subFarmVO"]) {
        return YES;
    }
    if (resData[@"dynamicGlobalConfig"] || dict[@"dynamicGlobalConfig"]) {
        return YES;
    }
    if (resData[@"farmTaskList"] || dict[@"farmTaskList"]) {
        return YES;
    }
    if (resData[@"antfarmP2POfflineTime"] || dict[@"antfarmP2POfflineTime"]) {
        return YES;
    }
    return NO;
}

- (void)recordProbeLog:(NSString *)log {
#if !ENABLE_PROBE_LOGS
    return;
#else
    if (!log.length) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        patrolProbeLogs = [NSMutableArray array];
    });
    NSString *timeStr = getCurrentDateTimeString();
    NSString *entry = [NSString stringWithFormat:@"[%@] %@", timeStr, log];
    @synchronized (patrolProbeLogs) {
        [patrolProbeLogs addObject:entry];
        if (patrolProbeLogs.count > 500) {
            [patrolProbeLogs removeObjectAtIndex:0];
        }
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @try {
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            if (!handle) {
                [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            }
            [handle seekToEndOfFile];
            [handle writeData:[[entry stringByAppendingString:@"\n\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } @catch (NSException *e) {}
    });
#endif
}

- (void)clearProbeLogs {
    @synchronized (patrolProbeLogs) {
        [patrolProbeLogs removeAllObjects];
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @try {
            NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        } @catch (NSException *e) {}
    });
}

- (NSArray<NSString *> *)probeRecords {
#if !ENABLE_PROBE_LOGS
    return @[];
#else
    @synchronized (patrolProbeLogs) {
        if (patrolProbeLogs.count > 0) {
            return [patrolProbeLogs copy];
        }
    }
    @try {
        NSString *docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *filePath = [docPath stringByAppendingPathComponent:@"AntForestPatrolProbe.log"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
            if (content.length) {
                NSArray *lines = [content componentsSeparatedByString:@"\n\n"];
                NSMutableArray *res = [NSMutableArray array];
                for (NSString *l in lines) {
                    NSString *trim = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trim.length) [res addObject:trim];
                }
                return res;
            }
        }
    } @catch (NSException *e) {}
    return @[];
#endif
}

-(void)startAutoCollectTimerWithInterval:(NSTimeInterval)interval{
    if (self.autoCollectTimer.isValid && self.collectInterval == interval) {
        return;
    }
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
    self.collectInterval = interval;
    self.failedTimes = 0; //每次重新启动定时器时 失败次数均要置 0
    [self recordStage:[NSString stringWithFormat:@"后台循环已启动（%ld 分钟）", (long)MAX(1, interval / 60)]];
    
    // 创建新的定时器
    self.autoCollectTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                             target:self
                                                           selector:@selector(autoCollectBubbles)
                                                           userInfo:nil
                                                            repeats:YES];
    [self.autoCollectTimer fire];
}

-(void)stopAutoCollectTimer {
    [self.autoCollectTimer invalidate];
    self.autoCollectTimer = nil;
}

-(void)startScheduledCollectTimer {
    [self.scheduledCollectTimer invalidate];
    self.scheduledCollectTimer = [NSTimer scheduledTimerWithTimeInterval:15
                                                                    target:self
                                                                  selector:@selector(checkScheduledCollect)
                                                                  userInfo:nil
                                                                   repeats:YES];
    [self checkScheduledCollect];
}

-(void)checkScheduledCollect {
    if (!self.enableAutoCollect || !self.enableScheduledCollect) return;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:NSDate.date];
    if (![self.scheduledTimes containsObject:time]) return;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *minute = [formatter stringFromDate:NSDate.date];
    if ([lastScheduledMinute isEqualToString:minute]) return;
    lastScheduledMinute = minute;
    [self recordStage:@"定时收取开始"];
    [self autoCollectBubbles];
}

NSString* getCurrentDateString() {
    // 获取当前日期
    NSDate *currentDate = [NSDate date];
    
    // 创建日期格式化器
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    
    // 设置日期格式
    [formatter setDateFormat:@"yyyy-MM-dd"];
    
    // 返回格式化后的日期字符串
    return [formatter stringFromDate:currentDate];
}

NSString* getCurrentDateTimeString() {
    // 获取当前日期
    NSDate *currentDate = [NSDate date];
    
    // 创建日期格式化器
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    
    // 设置日期格式
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    
    // 返回格式化后的日期字符串
    return [formatter stringFromDate:currentDate];
}


+(NSString*)getNumberRandom:(int)count
{
    NSString *strRandom = @"";
    
    for(int i=0; i<count; i++)
    {
        strRandom = [ strRandom stringByAppendingFormat:@"%i",(arc4random() % 9)];
    }
    return strRandom;
}

//随机一个有能量的好友
-(void)takeLook{
    NSString *version = @"20231208";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    __block NSArray<NSString *> *visitedFriends = nil;
    @synchronized (self) {
        visitedFriends = takeLookRunning ? takeLookVisitedFriends.allObjects : @[];
    }
    NSMutableDictionary *skipUsers = [NSMutableDictionary dictionaryWithCapacity:visitedFriends.count];
    for (NSString *friendId in visitedFriends) skipUsers[friendId] = @YES;
    NSData *skipUsersData = [NSJSONSerialization dataWithJSONObject:skipUsers options:0 error:nil];
    NSString *skipUsersJSON = [[NSString alloc] initWithData:skipUsersData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.takeLook\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"skipUsers\":%@,\"version\":\"%@\",\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",skipUsersJSON,version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求找能量续查：已跳过 %lu 位", (unsigned long)visitedFriends.count]];
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"anthook takeLook");
    }
}

// 按“找能量”的候选顺序补扫，避免首页排行榜只返回局部好友时遗漏成熟能量。
-(void)startTakeLookContinuation {
    @synchronized (self) {
        if (takeLookRunning) return;
        takeLookRunning = YES;
        takeLookWaitingForFriend = NO;
        takeLookCurrentFriendId = nil;
        takeLookRounds = 0;
        takeLookPass = 1;
        takeLookTotalRounds = 0;
        takeLookRequestToken++;
        [takeLookVisitedFriends removeAllObjects];
    }
    [self recordStage:@"诊断 · 排行榜扫描结束，开始找能量续查"];
    [self requestNextTakeLook];
}

-(void)requestNextTakeLook {
    __block NSUInteger requestToken = 0;
    @synchronized (self) {
        if (!takeLookRunning || !self.enableAutoCollect || !self.jsBridge || takeLookTotalRounds >= kTakeLookMaxRounds) {
            NSString *reason = takeLookTotalRounds >= kTakeLookMaxRounds ? @"达到安全上限" : @"任务已停止或桥接不可用";
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            takeLookCurrentFriendId = nil;
            self.isScanRunning = NO;
            [self recordStage:[NSString stringWithFormat:@"本轮扫描结束：%@", reason]];
            return;
        }
        takeLookRounds++;
        takeLookTotalRounds++;
        takeLookWaitingForFriend = YES;
        takeLookCurrentFriendId = nil;
        requestToken = ++takeLookRequestToken;
    }
    [self takeLook];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (!takeLookRunning || !takeLookWaitingForFriend || requestToken != takeLookRequestToken) return;
            takeLookRunning = NO;
            takeLookWaitingForFriend = NO;
            self.isScanRunning = NO;
            [self recordStage:@"本轮扫描完成"];
        }
    });
}

-(BOOL)consumeTakeLookFriend:(NSString *)friendId {
    @synchronized (self) {
        if (!takeLookRunning || !takeLookWaitingForFriend) return YES;
        takeLookWaitingForFriend = NO;
        if ([takeLookVisitedFriends containsObject:friendId]) {
            if (takeLookPass < kTakeLookMaxPasses && takeLookTotalRounds < kTakeLookMaxRounds) {
                takeLookPass++;
                takeLookRounds = 0;
                takeLookCurrentFriendId = nil;
                takeLookRequestToken++;
                [takeLookVisitedFriends removeAllObjects];
                [self recordStage:[NSString stringWithFormat:@"诊断 · 服务端重复候选，开始第 %lu 轮续查", (unsigned long)takeLookPass]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self requestNextTakeLook];
                });
                return NO;
            }
            takeLookRunning = NO;
            self.isScanRunning = NO;
            [self recordStage:@"本轮扫描完成"];
            return NO;
        }
        [takeLookVisitedFriends addObject:friendId];
        takeLookCurrentFriendId = friendId;
        [self recordStage:[NSString stringWithFormat:@"诊断 · 找能量候选：第 %lu 轮第 %lu 位（累计 %lu 位）", (unsigned long)takeLookPass, (unsigned long)takeLookRounds, (unsigned long)takeLookTotalRounds]];
        return YES;
    }
}

-(void)advanceTakeLookForFriend:(NSString *)friendId {
    @synchronized (self) {
        if (!takeLookRunning || ![takeLookCurrentFriendId isEqualToString:friendId]) return;
        takeLookCurrentFriendId = nil;
    }
    // 收取请求在全局串行队列中发送；以该队列的栅栏作为下一位候选的起点，避免与前一位的多颗气泡请求重叠。
    dispatch_async(globalSerialQueueCollect, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self recordStage:@"诊断 · 当前候选收取队列已完成，继续下一位"];
            [self requestNextTakeLook];
        });
    });
}

- (BOOL)isAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name {
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // 1. 全局单日已收标记
    NSString *savedAnimalDate = [defaults stringForKey:@"todayAnimalEnergyCollectedDate"];
    if ([today isEqualToString:savedAnimalDate]) {
        return YES;
    }
    
    // 2. 按动物名/Code 维度检查
    if (code.length) {
        NSString *kCode = [NSString stringWithFormat:@"animal_%@_%@", today, code];
        if ([todayCollectedAnimalKeys containsObject:kCode] || [defaults boolForKey:kCode]) {
            return YES;
        }
    }
    if (name.length) {
        NSString *kName = [NSString stringWithFormat:@"animal_%@_%@", today, name];
        if ([todayCollectedAnimalKeys containsObject:kName] || [defaults boolForKey:kName]) {
            return YES;
        }
    }
    return NO;
}

- (void)markAnimalEnergyCollectedTodayForCode:(NSString *)code name:(NSString *)name reason:(NSString *)reason {
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:today forKey:@"todayAnimalEnergyCollectedDate"];
    
    if (!todayCollectedAnimalKeys) todayCollectedAnimalKeys = [NSMutableSet set];
    if (code.length) {
        NSString *kCode = [NSString stringWithFormat:@"animal_%@_%@", today, code];
        [todayCollectedAnimalKeys addObject:kCode];
        [defaults setBool:YES forKey:kCode];
    }
    if (name.length) {
        NSString *kName = [NSString stringWithFormat:@"animal_%@_%@", today, name];
        [todayCollectedAnimalKeys addObject:kName];
        [defaults setBool:YES forKey:kName];
    }
    [defaults synchronize];
    
    static NSTimeInterval lastLockLogTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastLockLogTime > 300.0) {
        lastLockLogTime = now;
        NSString *aName = name.length ? name : (code.length ? code : @"巡护伙伴");
        [self recordStage:[NSString stringWithFormat:@"保护地巡护 · %@今日能量已确认收取/不可收（%@），锁定单日防重", aName, reason ?: @"防重生效"]];
    }
}

-(void)queryUsingCreatureInfo {
    if (!self.jsBridge) return;
    // 若今日巡护动物能量已确认收取，跳过轮询，避免无意义的网络开销
    if ([self isAnimalEnergyCollectedTodayForCode:nil name:nil]) return;
    
    static NSTimeInterval lastQueryCreatureTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastQueryCreatureTime < 3.0) return;
    lastQueryCreatureTime = now;
    
    NSString *effectiveUid = self.myUserId.length ? self.myUserId : ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"] ?: @"");
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
    NSString *rand = [AntForestManager getNumberRandom:15];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antisle.monopoly.h5.queryUsingCreatureInfo\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"uniqueId\":\"%@\",\"targetUserId\":\"%@\",\"version\":\"20260623\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uuid, effectiveUid ?: @"", timeStamp, rand];
    manorSendRPC(self.jsBridge, arg, arg2);
}

-(void)collectMonopolyCreatureEnergyWithCode:(NSString *)creatureCode shortDay:(NSString *)shortDay energy:(NSInteger)energy name:(NSString *)name {
    if (!self.jsBridge) return;
    NSString *code = creatureCode.length ? creatureCode : @"hongshandongwuyuan#dani";
    NSString *aName = name.length ? name : @"巡护伙伴";
    
    // 1. 核心防重：今日已锁定或已收过，严禁发送 RPC 并静默拦截
    if ([self isAnimalEnergyCollectedTodayForCode:code name:aName]) {
        static NSTimeInterval lastAnimalSkipLogTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastAnimalSkipLogTime > 300.0) {
            lastAnimalSkipLogTime = now;
            [self recordStage:[NSString stringWithFormat:@"保护地巡护：%@今日能量已收取（待明日产生）", aName]];
        }
        return;
    }
    
    NSString *sDay = shortDay;
    if (!sDay.length) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        [df setDateFormat:@"yyyyMMdd"];
        sDay = [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400]];
    }
    
    // 2. 频次节流：对同一动物+同一 shortDay，30 秒内最多尝试一次 RPC，避免并发与高频刷屏
    NSString *attemptKey = [NSString stringWithFormat:@"%@_%@", code, sDay];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *lastAttempt = lastAnimalCollectAttemptTimes[attemptKey];
    if (lastAttempt && (now - [lastAttempt doubleValue] < 30.0)) {
        return;
    }
    lastAnimalCollectAttemptTimes[attemptKey] = @(now);
    
    NSString *energyDesc = (energy > 0) ? [NSString stringWithFormat:@"（%ldg）", (long)energy] : @"";
    [self recordStage:[NSString stringWithFormat:@"保护地巡护：正在通过官方专有接口收取%@能量%@...", aName, energyDesc]];
    
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
    NSString *rand = [AntForestManager getNumberRandom:15];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
    
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antisle.monopoly.h5.collectMonopolyCreatureEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"uniqueId\":\"%@\",\"creatureCode\":\"%@\",\"shortDay\":\"%@\",\"version\":\"20260623\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", uuid, code, sDay, timeStamp, rand];
    manorSendRPC(self.jsBridge, arg, arg2);
}

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId energy:(NSInteger)energy name:(NSString *)name isCollected:(BOOL)isCollected {
    if ((!self.enableAutoCollect && !self.enableSelfCollect && !self.enableAutoPatrolNew) || !self.jsBridge) return;
    NSString *pType = propType ?: @"";
    NSString *aId = animalId ?: @"";
    NSString *pId = propId ?: @"";
    NSString *aName = name.length ? name : @"巡护伙伴";
    NSString *creatureCode = aId.length ? aId : (pType.length ? pType : @"hongshandongwuyuan#dani");
    
    // 如果今日已经确认成功收取完毕或入参标记已收，直接跳过并节流提示
    if (isCollected || [self isAnimalEnergyCollectedTodayForCode:creatureCode name:aName]) {
        [self markAnimalEnergyCollectedTodayForCode:creatureCode name:aName reason:@"入参或历史已收取"];
        static NSTimeInterval lastAnimalNoEnergyLogTime = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastAnimalNoEnergyLogTime > 300.0) { // 5分钟节流提示
            lastAnimalNoEnergyLogTime = now;
            [self recordStage:[NSString stringWithFormat:@"保护地巡护：%@今日能量已收取（待明日产生）", aName]];
        }
        return;
    }
    
    // 节流：两次尝试收取至少间隔 10 秒，避免高频并发
    static NSTimeInterval sLastAnimalAttemptTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - sLastAnimalAttemptTime < 10.0) return;
    sLastAnimalAttemptTime = now;
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyyMMdd"];
    NSString *yesterdayShortDay = [df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400]];
    NSString *todayShortDay = [df stringFromDate:[NSDate date]];
    
    // 1. 针对新版保护地巡护动物（如南京红山动物园小熊猫、大鲵），发送官方原版 alipay.antisle.monopoly.h5.collectMonopolyCreatureEnergy
    // 先发送昨日 shortDay（正常巡护结算为昨日产出）
    [self collectMonopolyCreatureEnergyWithCode:creatureCode shortDay:yesterdayShortDay energy:energy name:aName];
    
    // 延时 1000ms 发送今日 shortDay 容错（先二次检查是否已在第一发中收取锁定）
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf isAnimalEnergyCollectedTodayForCode:creatureCode name:aName]) return;
        [strongSelf collectMonopolyCreatureEnergyWithCode:creatureCode shortDay:todayShortDay energy:energy name:aName];
    });
    
    // 2. 针对经典动物背包道具，发送官方原版 alipay.antforest.forest.h5.collectAnimalRobEnergy
    if (pId.length && ![pId isEqualToString:creatureCode]) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970] * 1000];
        NSString *rand = [AntForestManager getNumberRandom:15];
        NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
        NSString *argClassic = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.collectAnimalRobEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"propId\":\"%@\",\"propType\":\"%@\",\"shortDay\":\"%@\",\"version\":\"20240322\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", pId, pType, yesterdayShortDay, timeStamp, rand];
        manorSendRPC(self.jsBridge, argClassic, arg2);
    }
}

-(void)receiveAnimalEnergyWithPropId:(NSString *)propId propType:(NSString *)propType animalId:(NSString *)animalId {
    [self receiveAnimalEnergyWithPropId:propId propType:propType animalId:animalId energy:0 name:@"" isCollected:NO];
}

-(void)receiveAnimalPartnerEnergy {
    [self queryUsingCreatureInfo];
}

static NSTimeInterval lastMyBubblesQueryTime = 0;

-(void)queryMyBubbles {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastMyBubblesQueryTime < 3.0) return;
    lastMyBubblesQueryTime = now;
    
    [self recordStage:@"请求本人首页（含赠能）"];
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{}}]},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    
    if([self jsBridge]) {
        manorSendRPC([self jsBridge], arg1, arg2);
        [self queryUsingCreatureInfo];
    }
    
    [NSThread sleepForTimeInterval:0.18];
    [[AntForestManager sharedLock] unlock];
}

//查询能量球
-(void)queryFriendsBubbles:(NSString*)friendId {
    [[AntForestManager sharedLock] lock];
    
    NSString *version = @"20241025";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryFriendHomePage\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"userId\":\"%@\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"fromAct\":\"TAKE_LOOK\",\"configVersionMap\":{\"wateringBubbleConfig\":\"0\"},\"skipWhackMole\":false,\"activityParam\":{},\"currentEnergy\":99999999,\"currentVitalityAmount\":8888888}]},\"callbackId\":\"rpc_%@.%@\"}]",friendId,version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK",friendId];
    
    if([self jsBridge]) {
        [self recordStage:@"诊断 · 请求好友气泡"];
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"anthook queryFriendsBubbles: %@",friendId);
    }
    
    double randomDelay = 0.18 + (arc4random_uniform(140) / 1000.0);
    [NSThread sleepForTimeInterval:randomDelay];
    [[AntForestManager sharedLock] unlock];
}

//收集能量球
-(void)collectBubbles:(NSString*)uid bubblesId:(NSString*)bids {
    NSString *userId = [uid isKindOfClass:NSString.class] ? uid : [uid description];
    NSString *bubbleIds = [bids isKindOfClass:NSString.class] ? bids : [bids description];
    if (!self.enableAutoCollect || !userId.length || !bubbleIds.length) return;
    if (!self.myUserId.length) {
        [self recordStage:@"诊断 · 收取跳过：本人账户尚未识别"];
        return;
    }
    if ([userId isEqualToString:self.myUserId] && !self.enableSelfCollect) {
        [self recordStage:@"已跳过本人能量"];
        return;
    }
    NSString *collectKey = [NSString stringWithFormat:@"%@:%@", userId, bubbleIds];
    @synchronized (self) {
        if ([pendingCollectBubbles containsObject:collectKey]) {
            [self recordStage:@"诊断 · 收取跳过：重复气泡请求"];
            return;
        }
        [pendingCollectBubbles addObject:collectKey];
    }
    [[AntForestManager sharedLock] lock];
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.collectEnergy\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userId\":\"%@\",\"bubbleIds\":[%@],\"bizType\":\"\",\"fromAct\":\"TAKE_LOOK\",\"version\":\"%@\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",userId,bubbleIds,version,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&userId=%@&__webview_options__=bc%%3D3194732&source=chInfo_ch_appcenter__chsub_9patch&fromAct=TAKE_LOOK", userId];
    if([self jsBridge]) {
        [self recordStage:[NSString stringWithFormat:@"诊断 · 请求收取能量：第 %lu 轮，待确认 %lu 笔", (unsigned long)collectionCycle, (unsigned long)pendingCollectBubbles.count]];
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"anthook collectBubbles: %@ | [%@] ",uid,bids);
    }
    double collectRandomDelay = 0.12 + (arc4random_uniform(100) / 1000.0);
    [NSThread sleepForTimeInterval:collectRandomDelay];
    [[AntForestManager sharedLock] unlock];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (![pendingCollectBubbles containsObject:collectKey]) return;
            [pendingCollectBubbles removeObject:collectKey];
        }
    });
}

-(void)reportClickTime{
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"reportClickTime\",\"data\":{},\"callbackId\":\"reportClickTime_%@.%@\"}]",timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    if([self jsBridge]) {
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"anthook reportClickTime");
    }
}

//复活能量 执行不成功 不知道是不是 检测了什么事件
-(void)reviveEnergy:(NSString*)uid signId:(NSString*)signId {
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_ENERGY_SIGN\",\"requestType\":\"rpc\",\"userId\":\"%@\",\"entityId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,signId,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%%3D3194732"];
    if([self jsBridge]) {
        [self reportClickTime];
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"anthook reviveEnergy: %@ | [%@] ",uid,signId);
    }
}

static NSInteger myOceanCleanCount = 0;
static NSMutableDictionary *friendOceanCleanCounts = nil;

-(void)cleanMyOceanThoroughly {
    if (!self.enableCleanOcean || !self.jsBridge) return;
    myOceanCleanCount = 0;
    [self cleanMyOcean];
}

//清理自己的海域
-(void)cleanMyOcean{
    if (!self.myUserId.length) return;
    self.lastCleanedOceanUserId = self.myUserId;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",self.myUserId,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html"];
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        manorSendRPC(bridge, arg1, arg2);
    }
}

//清理朋友的海域
-(void)cleanFriendsOcean:(NSString*)uid{
    if (!uid.length) return;
    self.lastCleanedOceanUserId = uid;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *randNum2=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.cleanFriendOcean\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"cleanedUserId\":\"%@\",\"source\":\"ANT_FOREST\",\"uniqueId\":\"%@%@\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"cleanFriendsOcean\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uid,timeStamp,randNum,timeStamp,randNum2];
    NSString *arg2 = [NSString stringWithFormat:@"https://2021003115672468.h5app.alipay.com/www/index.html?fromAct=SAIL_AWAY&userId=%@&interactFlags=&source=ANT_FOREST&__webview_options__=ttb%%3Dauto%%26pd%%3DNO%%26bc%%3D1324950",uid];
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        manorSendRPC(bridge, arg1, arg2);
    }
}

-(void)queryOceanFriendList {
    if (!self.enableCleanOcean) return;
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:15];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antocean.ocean.h5.queryFriendList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"ANT_FOREST\"}],\"appName\":\"antocean\",\"facadeName\":\"InteractController\",\"methodName\":\"queryFriendList\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    NSString *arg2 = @"https://2021003115672468.h5app.alipay.com/www/index.html";
    id bridge = self.oceanBridge ?: self.jsBridge;
    if(bridge) {
        [self recordStage:@"请求神奇海洋好友列表"];
        manorSendRPC(bridge, arg1, arg2);
        dispatch_async(globalSerialQueueQuery, ^{
            [self cleanMyOcean];
        });
    }
}

// ----------------------------------------------------
// 领奖励与森林寻宝（任务中心：签到、浏览任务、阶梯累计大奖）
// ----------------------------------------------------

static NSMutableArray<NSDictionary *> *vitalityTaskQueue = nil;
static BOOL vitalityTaskRunning = NO;
static NSMutableSet<NSString *> *gDailyCompletedTasks = nil;
static NSMutableSet<NSString *> *gDailyFailedTasks = nil;
static NSString *gDailyTaskDate = nil;
static NSString *gCurrentExecutingTaskKey = nil;
static BOOL gCurrentExecutingTaskIsMultiStage = NO;
static NSMutableDictionary<NSString *, NSNumber *> *gFarmTaskRetryCounts = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gVitalityTaskRetryCounts = nil;

static void initDailyTaskCache(void) {
    NSString *today = getCurrentDateString();
    if (![gDailyTaskDate isEqualToString:today] || !gDailyCompletedTasks || !gDailyFailedTasks) {
        gDailyTaskDate = today;
        if (!gFarmTaskRetryCounts) {
            gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
        } else {
            [gFarmTaskRetryCounts removeAllObjects];
        }
        if (!gVitalityTaskRetryCounts) {
            gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
        } else {
            [gVitalityTaskRetryCounts removeAllObjects];
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *savedDate = [defaults stringForKey:@"vitality_task_cache_date"];
        if ([savedDate isEqualToString:today]) {
            NSArray *completed = [defaults objectForKey:@"vitality_daily_completed"];
            gDailyCompletedTasks = [NSMutableSet setWithArray:completed ?: @[]];
            NSArray *failed = [defaults objectForKey:@"vitality_daily_failed"];
            NSMutableSet *clearedFailed = [NSMutableSet set];
            for (NSString *key in failed ?: @[]) {
                if (![key containsString:@"XIANYU"] &&
                    ![key containsString:@"xianyu"] &&
                    ![key containsString:@"taobao"] &&
                    ![key containsString:@"BUSINESS"] &&
                    ![key containsString:@"LIGHTS"] &&
                    ![key containsString:@"XLIGHT"] &&
                    ![key containsString:@"SQYT"] &&
                    ![key containsString:@"ANTOCEAN"] &&
                    ![key containsString:@"AIFISH"] &&
                    ![key containsString:@"aifish"] &&
                    ![key containsString:@"FLOATBALL"] &&
                    ![key containsString:@"floatball"] &&
                    ![key containsString:@"NCLY"] &&
                    ![key containsString:@"ncly"] &&
                    ![key containsString:@"BWXRK"] &&
                    ![key containsString:@"bwxrk"] &&
                    ![key containsString:@"ORCHARD"] &&
                    ![key containsString:@"orchard"] &&
                    ![key containsString:@"ANTFARM"] &&
                    ![key containsString:@"antfarm"] &&
                    ![key containsString:@"MONOPOLY"] &&
                    ![key containsString:@"HSDWY"]) {
                    [clearedFailed addObject:key];
                }
            }
            gDailyFailedTasks = clearedFailed;
        } else {
            gDailyCompletedTasks = [NSMutableSet set];
            gDailyFailedTasks = [NSMutableSet set];
            [defaults setObject:today forKey:@"vitality_task_cache_date"];
            [defaults setObject:@[] forKey:@"vitality_daily_completed"];
            [defaults setObject:@[] forKey:@"vitality_daily_failed"];
            [defaults synchronize];
        }
    }
}

static void saveDailyTaskCache(void) {
    if (!gDailyTaskDate.length) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:gDailyTaskDate forKey:@"vitality_task_cache_date"];
    [defaults setObject:[gDailyCompletedTasks allObjects] forKey:@"vitality_daily_completed"];
    [defaults setObject:[gDailyFailedTasks allObjects] forKey:@"vitality_daily_failed"];
    [defaults synchronize];
}

static BOOL isSafeRewardTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    if ([taskType isEqualToString:@"ZHRW_haoyibaomzx_202601"] ||
        [taskType isEqualToString:@"ZHRW_haoyibaoseyl_202512"] ||
        [taskType isEqualToString:@"FOREST_CONTINUOUS_COLLECT_ENERGY_7"] ||
        [taskType isEqualToString:@"ENERGYRAIN"] ||
        [taskType isEqualToString:@"ENERGY_XUANJIAO"] ||
        [taskType isEqualToString:@"TEST_LEAF_TASK"] ||
        [taskType isEqualToString:@"TEST_LEAF_CONVERT_TASK"] ||
        [taskType isEqualToString:@"widget_0511"] ||
        [taskType isEqualToString:@"ONE_CLICK_WATERING_V1"] ||
        [taskType containsString:@"10THjiaoshui"] ||
        [taskType containsString:@"10ZN_JS"]) {
        return NO;
    }
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 明确不做领奖励中的“进入新版保护地”跳转任务
    if ([lowerTitle containsString:@"新版保护地"] || [lowerTitle containsString:@"进入新版保护地"]) {
        return NO;
    }
    
    // 阶梯大奖类型安全可领
    if ([lowerType hasPrefix:@"acc_"] || [lowerType containsString:@"_acc_"] || [lowerType containsString:@"acc_"] || [lowerType containsString:@"stage_"] || [lowerType containsString:@"ladder"]) {
        return YES;
    }
    
    // AI摸鱼类任务安全可执行 (赠送每日摸鱼次数、看15s视频、去玩一玩森林小车车15s等)
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
        if ([lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
            [lowerType containsString:@"zhuanhua"] || [lowerType containsString:@"cnxdy"] ||
            [lowerTitle containsString:@"击败"] || [lowerTitle containsString:@"打怪"] || [lowerTitle containsString:@"玩一玩超"]) {
            return NO;
        }
        return YES;
    }
    
    // 公益林任务为纯浏览（去看看），安全可执行
    if ([lowerType containsString:@"zhongshugongyilin"] || [lowerTitle containsString:@"公益林"]) {
        return YES;
    }
    // 支付宝会员中心任务为纯浏览，安全可执行
    if ([lowerType containsString:@"huiyuan"] || [lowerTitle containsString:@"会员中心"]) {
        return YES;
    }
    
    // 严格过滤金融、保险、借贷、支付、好友随机浇水、游戏试玩通关等风险任务及无法通过RPC完成的任务
    if ([lowerType containsString:@"haoyibao"] ||
        [lowerType containsString:@"insure"] ||
        [lowerType containsString:@"baoxian"] ||
        [lowerType containsString:@"jiebei"] ||
        [lowerType containsString:@"huabei"] ||
        [lowerType containsString:@"jiaoshui"] ||
        [lowerType containsString:@"continuous_collect"] ||
        [lowerType containsString:@"energy_xuanjiao"] ||
        [lowerType containsString:@"widget_"] ||
        [lowerType containsString:@"mhjlr"] ||
        [lowerType containsString:@"xjskp"] ||
        [lowerType containsString:@"wdhysj"] ||
        [lowerType containsString:@"zhxf"] ||
        [lowerType containsString:@"yxzy"] ||
        [lowerType containsString:@"_zhwufu"]) {
        return NO;
    }
    
    // 带有导流前缀 DAOLIU_ 的即便是游戏也是纯跳转/浏览安全任务（如 DAOLIU_SLJYG_DJW_GAME）
    if ([lowerType hasPrefix:@"daoliu_"] || [lowerType containsString:@"daoliu"]) {
        return YES;
    }
    
    // 过滤真实付款与金融高危任务，注意避免误杀包含“支付宝”字样的安全浏览任务
    NSString *cleanTitle = [lowerTitle stringByReplacingOccurrencesOfString:@"支付宝" withString:@""];
    if ([cleanTitle containsString:@"保障"] ||
        [cleanTitle containsString:@"保险"] ||
        [cleanTitle containsString:@"好医保"] ||
        [cleanTitle containsString:@"借呗"] ||
        [cleanTitle containsString:@"花呗"] ||
        [cleanTitle containsString:@"信用卡"] ||
        [cleanTitle containsString:@"理财"] ||
        [cleanTitle containsString:@"基金"] ||
        [cleanTitle containsString:@"支付"] ||
        [cleanTitle containsString:@"付款"] ||
        [cleanTitle containsString:@"购买"] ||
        [cleanTitle containsString:@"下单"] ||
        [cleanTitle containsString:@"充值"] ||
        [cleanTitle containsString:@"浇水"] ||
        [cleanTitle containsString:@"一键浇水"] ||
        [cleanTitle containsString:@"添加组件"] ||
        [cleanTitle containsString:@"淘宝签到"] ||
        ([cleanTitle containsString:@"玩游戏得"] && ![cleanTitle containsString:@"机会"] && ![lowerType containsString:@"daoliu"] && ![lowerType containsString:@"draw"]) ||
        [cleanTitle containsString:@"居民订单"] ||
        [cleanTitle containsString:@"升级建筑"] ||
        [cleanTitle containsString:@"闯关"] ||
        [cleanTitle containsString:@"通过1关"] ||
        [cleanTitle containsString:@"向僵尸开炮"] ||
        [cleanTitle containsString:@"梦幻经理人"] ||
        [cleanTitle containsString:@"造化仙府"] ||
        [cleanTitle containsString:@"源星战域"] ||
        [cleanTitle containsString:@"我的花园"] ||
        [cleanTitle containsString:@"花园小镇"] ||
        [cleanTitle containsString:@"进入新版保护地"] ||
        [cleanTitle containsString:@"连续"] ||
        [cleanTitle containsString:@"垃圾"] ||
        [cleanTitle containsString:@"帮好友清理"] ||
        [cleanTitle containsString:@"给随机好友"]) {
        return NO;
    }
    return YES;
}

static BOOL isSafeOceanTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 明确不做神奇海洋“逛一逛惊喜市集”
    if ([lowerTitle containsString:@"惊喜市集"] || [lowerType containsString:@"jingxi"]) {
        return NO;
    }
    // 明确不做“进入新版保护地”与保护地跳转任务
    if ([lowerTitle containsString:@"进入新版保护地"]) {
        return NO;
    }
    // 明确不支持 finishTask RPC 的答题、捡垃圾、连续签到与外部小程序小游戏
    if ([lowerType containsString:@"dati"] || [lowerTitle containsString:@"答题"]) {
        return NO;
    }
    if ([lowerType containsString:@"rubbish"] || [lowerTitle containsString:@"垃圾"]) {
        return NO;
    }
    if ([lowerType containsString:@"visisit"] || [lowerType containsString:@"consecutive"] || [lowerTitle containsString:@"连续"] || [lowerTitle containsString:@"3天"]) {
        return NO;
    }
    if ([lowerType containsString:@"yxzy"] || [lowerTitle containsString:@"源星战域"]) {
        return NO;
    }
    if ([lowerType containsString:@"hydrw"] || [lowerTitle containsString:@"玩一玩得拼图"] || [lowerTitle containsString:@"专区游戏"]) {
        return NO;
    }
    
    // 带有导流前缀 DAOLIU_ 的即便是游戏也是纯跳转/浏览安全任务（如 DAOLIU_SLJYG_DJW_GAME）
    if ([lowerType hasPrefix:@"daoliu_"] || [lowerType containsString:@"daoliu"]) {
        return YES;
    }
    
    // 纯游戏类若无导流前缀则不支持 RPC
    if ([lowerType containsString:@"game"] && ![lowerType containsString:@"daoliu"]) {
        return NO;
    }
    
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeAIFishTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    if ([lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerType containsString:@"xianyu"] || [lowerTitle containsString:@"闲鱼"] ||
        [lowerTitle containsString:@"让闲置循环"] ||
        [lowerType containsString:@"zhuanhua"] || [lowerType containsString:@"cnxdy"] ||
        [lowerTitle containsString:@"击败"] || [lowerTitle containsString:@"打怪"] || [lowerTitle containsString:@"玩一玩超"] ||
        [lowerTitle containsString:@"安装"] || [lowerTitle containsString:@"下载"]) {
        return NO;
    }
    if ([lowerType containsString:@"aifish"] || [lowerType containsString:@"touch_fish"] || [lowerTitle containsString:@"摸鱼"]) {
        return YES;
    }
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeMonopolyTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 外部App跳转类（如闲鱼、淘宝、快手等）无法通过简单的 finishTask RPC 完成，由用户手动做，手动做完后自动领奖
    if ([lowerType containsString:@"xianyu"] || [lowerTitle containsString:@"闲鱼"] || [lowerTitle containsString:@"让闲置循环"] ||
        [lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerTitle containsString:@"安装"] || [lowerTitle containsString:@"下载"]) {
        return NO;
    }
    
    // 带有导流前缀 DAOLIU_ 的是纯跳转/浏览安全任务
    if ([lowerType hasPrefix:@"daoliu_"] || [lowerType containsString:@"daoliu"]) {
        return YES;
    }
    
    return isSafeRewardTask(taskType, title);
}

static BOOL isSafeManorTask(NSString *taskType, NSString *title, NSDictionary *task) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 1. 真实付款、充值、捐款、闪购下单
    if ([lowerType containsString:@"pay"] ||
        [lowerType containsString:@"donate"] ||
        [lowerType containsString:@"czrwz"] ||
        [lowerType containsString:@"shangou"] ||
        [lowerTitle containsString:@"付款"] ||
        [lowerTitle containsString:@"支付"] ||
        [lowerTitle containsString:@"捐"] ||
        [lowerTitle containsString:@"充值"] ||
        [lowerTitle containsString:@"实付"]) {
        return NO;
    }
    
    // 2. 外部第三方独立 App（美团、今日头条、快手、饿了么、一淘、淘宝视频等）
    if ([lowerType containsString:@"meituan"] ||
        [lowerType containsString:@"toutiao"] ||
        [lowerType containsString:@"kuaishou"] ||
        [lowerType containsString:@"elm"] ||
        [lowerType containsString:@"eleme"] ||
        [lowerType containsString:@"yitao"] ||
        [lowerType containsString:@"taobao"] ||
        [lowerTitle containsString:@"美团"] ||
        [lowerTitle containsString:@"头条"] ||
        [lowerTitle containsString:@"快手"] ||
        [lowerTitle containsString:@"饿了么"] ||
        [lowerTitle containsString:@"一淘"] ||
        [lowerTitle containsString:@"淘宝视频"]) {
        return NO;
    }
    
    // 3. 系统组件/首页宫格/挨饿提醒
    if ([lowerType containsString:@"widget"] ||
        [lowerType containsString:@"push"] ||
        [lowerType containsString:@"gongge"] ||
        [lowerType containsString:@"add_app"] ||
        [lowerTitle containsString:@"小组件"] ||
        [lowerTitle containsString:@"提醒"] ||
        [lowerTitle containsString:@"首页"]) {
        return NO;
    }
    
    // 4. 外部游戏与关卡打怪
    if ([lowerType containsString:@"game"] ||
        [lowerType containsString:@"wfzy"] ||
        [lowerType containsString:@"wfyx"] ||
        [lowerType containsString:@"ljzc"] ||
        [lowerType containsString:@"sgbhsd"] ||
        [lowerType containsString:@"guandan"] ||
        [lowerType containsString:@"xjskp"] ||
        [lowerTitle containsString:@"小游戏"] ||
        [lowerTitle containsString:@"新游"] ||
        [lowerTitle containsString:@"玩一玩"] ||
        [lowerTitle containsString:@"击杀"] ||
        [lowerTitle containsString:@"招募"] ||
        [lowerTitle containsString:@"关卡"]) {
        return NO;
    }
    
    // 5. 消耗饲料或雇佣
    if ([lowerType containsString:@"fish"] ||
        [lowerType containsString:@"hire"] ||
        [lowerTitle containsString:@"喂鱼"] ||
        [lowerTitle containsString:@"雇佣"]) {
        return NO;
    }
    
    if (task && [task isKindOfClass:NSDictionary.class]) {
        NSString *playType = task[@"taskPlayType"] ?: @"";
        if ([playType isEqualToString:@"CALL_APP_OUT_TASK"]) return NO;
    }
    
    return YES;
}

static BOOL isSafeFarmTask(NSString *taskType, NSString *title) {
    if (!taskType.length) return NO;
    NSString *lowerType = taskType.lowercaseString;
    NSString *lowerTitle = title ? title.lowercaseString : @"";
    
    // 1. 鸡粪收取与纯施肥动作已在专属流程处理，严禁作为待办浏览任务入队
    if ([lowerType containsString:@"collect_manure"] || [lowerType containsString:@"spread_manure"] ||
        [lowerType isEqualToString:@"antfarm_collect_manure"]) {
        return NO;
    }
    
    // 2. 弹窗导流与迁移类伪任务（如 ORCHARD_POP_MIGRATE_XLIGHT 引导弹窗），严禁自动执行
    if ([lowerType containsString:@"pop"] || [lowerType containsString:@"migrate"] ||
        [lowerType containsString:@"guide"] || [lowerType containsString:@"daoliu"] ||
        [lowerType containsString:@"dialog"] || [lowerTitle containsString:@"轻量"] ||
        [lowerTitle containsString:@"迁移"]) {
        return NO;
    }
    
    // 3. 严禁自动执行的非浏览/高风险/社交类/下单类/第三方评价类/小游戏关卡/外部App唤醒类任务
    // （服务端对此类任务明确不支持前端通用 RPC finishTask，必须由端内小游戏业务回调、userGrowth 外部 Scheme 唤醒或手动交互完成）
    if ([lowerType containsString:@"zhifu"] || [lowerType containsString:@"pay"] || [lowerTitle containsString:@"支付"] || [lowerTitle containsString:@"付款"] ||
        [lowerType containsString:@"insure"] || [lowerType containsString:@"baoxian"] || [lowerTitle containsString:@"保险"] ||
        [lowerType containsString:@"loan"] || [lowerTitle containsString:@"借呗"] || [lowerTitle containsString:@"花呗"] ||
        [lowerType containsString:@"order"] || [lowerType containsString:@"xiadan"] || [lowerTitle containsString:@"下单"] || [lowerTitle containsString:@"购买"] || [lowerTitle containsString:@"订单"] || [lowerType containsString:@"lmct"] ||
        [lowerType containsString:@"gaode"] || [lowerTitle containsString:@"高德"] || [lowerTitle containsString:@"评价"] ||
        [lowerTitle containsString:@"分享"] || [lowerType containsString:@"sharer"] || [lowerType containsString:@"p2p"] ||
        [lowerTitle containsString:@"组队"] || [lowerTitle containsString:@"合种"] || [lowerTitle containsString:@"帮帮种"] || [lowerType containsString:@"team"] ||
        [lowerTitle containsString:@"下载"] || [lowerType containsString:@"caifu"] || [lowerType containsString:@"download"] ||
        [lowerTitle containsString:@"砍树"] || [lowerTitle containsString:@"关卡"] || [lowerTitle containsString:@"闯关"] || [lowerTitle containsString:@"闯5关"] || [lowerTitle containsString:@"通过"] || [lowerType containsString:@"zh_nlgj"] || [lowerType containsString:@"fkssj"] ||
        [lowerTitle containsString:@"倒水"] || [lowerTitle containsString:@"砸蛋"] || [lowerTitle containsString:@"击杀"] ||
        [lowerTitle containsString:@"玩一玩"] || [lowerType containsString:@"floatball_app"] || [lowerTitle containsString:@"消除战"] || [lowerTitle containsString:@"花园世界"] || [lowerTitle containsString:@"寻道大千"] || [lowerTitle containsString:@"消消消"] || [lowerTitle containsString:@"小游戏"] ||
        [lowerType containsString:@"kuaishou"] || [lowerTitle containsString:@"快手"] ||
        [lowerType containsString:@"meituan"] || [lowerTitle containsString:@"美团"] ||
        [lowerType containsString:@"taobaochengjiu"] || [lowerTitle containsString:@"淘宝成就"] || [lowerTitle containsString:@"周边"] ||
        [lowerType containsString:@"jindouduobao"] || [lowerTitle containsString:@"夺宝"] || [lowerTitle containsString:@"新手引导"] ||
        [lowerType containsString:@"group_1_step"]) {
        // 网商银行 / 网商贷看额度等官方安全浏览任务，予以放行（砍树、砸蛋等端内游戏内部动作严禁放行）
        if (!([lowerTitle containsString:@"网商"] || [lowerType containsString:@"wangshang"] || [lowerType containsString:@"wsyh"])) {
            return NO;
        }
    }
    
    // 4. 淘系商品导流任务（70000、104322等）在 antiep 网关无RPC配置，需在 Web 页面交互，禁止 RPC 直调
    if ([lowerType isEqualToString:@"70000"] || [lowerType isEqualToString:@"104322"]) {
        return NO;
    }
    
    // 5. 明确支持的白名单浏览特征（探针验证 100% 可通过 RPC 浏览完成并领奖）
    if (([lowerType containsString:@"floatball"] && ![lowerType containsString:@"floatball_app"] && ![lowerTitle containsString:@"玩一玩"]) ||
        [lowerType containsString:@"star30s"] ||
        [lowerType containsString:@"denghuo"] ||
        [lowerType containsString:@"chouchoule"] ||
        [lowerType containsString:@"jdly"] ||
        [lowerType containsString:@"qutoutiao"] ||
        [lowerType isEqualToString:@"58298"] || [lowerType containsString:@"defoliation"] ||
        [lowerType containsString:@"huiyuan"] ||
        [lowerType containsString:@"wsyh"] || [lowerType containsString:@"wangshang"] ||
        [lowerTitle containsString:@"网商"] || [lowerTitle containsString:@"会员"] ||
        [lowerTitle containsString:@"金豆乐园"] || [lowerTitle containsString:@"抽抽乐"] ||
        [lowerTitle containsString:@"精选商品"]) {
        return YES;
    }
    
    // 6. 其他常规纯浏览任务（排除上述黑名单后，标题带浏览/看等特征）
    if ([lowerTitle containsString:@"看精选"] || [lowerTitle containsString:@"浏览"]) {
        return YES;
    }
    
    return NO;
}

- (NSString *)manorRPCUrlString {
    if (self.manorH5Url.length) return self.manorH5Url;
    NSString *learned = [self effectiveUrlForBridge:self.manorBridge];
    if (learned.length) {
        self.manorH5Url = learned;   // 现场从庄园 Bridge 学到真实地址，之后一直用它
        return learned;
    }
    return kManorH5FallbackUrl;
}

- (NSString *)effectiveUrlForSceneCode:(NSString *)sceneCode {
    if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"ANTOCEAN"] || [sceneCode containsString:@"OCEAN"]) {
        return self.oceanH5Url ?: @"https://2021003115672468.h5app.alipay.com/www/index.html?source=ANT_FOREST&showTaskPanel=yes";
    }
    if ([sceneCode containsString:@"AIFISH"] || [sceneCode containsString:@"ANTAIFISH"]) {
        return self.aiFishH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001290531/index.html?caprMode=sync&source=ANT_OCEAN";
    }
    if ([sceneCode containsString:@"ANTFARM_FOOD"] || [sceneCode containsString:@"MANOR"]) {
        return [self manorRPCUrlString];
    }
    if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
        return self.farmH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001263018/game.html?caprMode=sync";
    }
    if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
        return self.monopolyH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001293606/index.html?caprMode=sync";
    }
    if ([sceneCode containsString:@"ACTIVITY_DRAW"]) {
        return self.lotteryH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_ACTIVITY_DRAW&source=task_entry&chInfo=task_entry";
    }
    if ([sceneCode containsString:@"DRAW"] || [sceneCode containsString:@"LOTTERY"] || [sceneCode containsString:@"VITALITY_EXCHANGE"]) {
        return self.lotteryH5Url ?: @"https://render.alipay.com/p/yuyan/180020010001279274/lotteryMachine.html?caprMode=sync&sceneCode=ANTFOREST_NORMAL_DRAW&source=task_entry&chInfo=task_entry";
    }
    return @"https://render.alipay.com/p/yuyan/180020010001247580/home.html?caprMode=sync&__webview_options__=bc%3D3194732";
}

- (NSString *)effectiveUrlForBridge:(PSDJsBridge *)bridge {
    if (bridge) {
        @try {
            id cv = [bridge respondsToSelector:@selector(contentView)] ? ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(contentView)) : nil;
            if ([cv respondsToSelector:@selector(url)]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(url));
                if ([u isKindOfClass:NSURL.class] && [(NSURL *)u absoluteString].length) return [(NSURL *)u absoluteString];
                if ([u isKindOfClass:NSString.class] && [(NSString *)u length]) return (NSString *)u;
            }
            if ([cv respondsToSelector:@selector(URL)]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(URL));
                if ([u isKindOfClass:NSURL.class] && [(NSURL *)u absoluteString].length) return [(NSURL *)u absoluteString];
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

- (void)registerBridge:(id)bridge withUrl:(NSString *)url {
    if (!bridge) return;
    self.jsBridge = bridge;
    
    NSString *effectiveUrl = url.length ? url : [self effectiveUrlForBridge:bridge];
    NSString *lowerUrl = effectiveUrl.lowercaseString;
    
    if (lowerUrl.length) {
        if ([lowerUrl containsString:@"180020010001293606"] || [lowerUrl containsString:@"monopoly"] || [lowerUrl containsString:@"hsdwy"] || [lowerUrl containsString:@"patrol"] || [lowerUrl containsString:@"guardian"]) {
            self.monopolyBridge = bridge;
            self.monopolyH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleMonopolyRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"180020010001290531"] || [lowerUrl containsString:@"aifish"] || [lowerUrl containsString:@"antaifish"]) {
            self.aiFishBridge = bridge;
            self.aiFishH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleAIFishRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"180020010001247569"] || [lowerUrl containsString:@"antfarm"]) {
            self.manorBridge = bridge;
            self.manorH5Url = effectiveUrl;
        } else if ([lowerUrl containsString:@"180020010001263018"] || [lowerUrl containsString:@"farm"] || [lowerUrl containsString:@"orchard"]) {
            self.farmBridge = bridge;
            self.farmH5Url = effectiveUrl;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleFarmRewardsOnWebView];
            });
        } else if ([lowerUrl containsString:@"2021003115672468"] || [lowerUrl containsString:@"ocean"]) {
            self.oceanBridge = bridge;
            self.oceanH5Url = effectiveUrl;
        } else if ([lowerUrl containsString:@"180020010001279274"] || [lowerUrl containsString:@"lotterymachine"] || [lowerUrl containsString:@"draw"]) {
            self.lotteryBridge = bridge;
            self.lotteryH5Url = effectiveUrl;
        }
    }
}

- (void)checkAndTriggerPageActionsForUrl:(NSString *)urlStr {
    if (!urlStr.length) return;
    NSString *lowerUrl = urlStr.lowercaseString;
    
    if ([lowerUrl containsString:@"180020010001293606"] || [lowerUrl containsString:@"monopoly"] || [lowerUrl containsString:@"hsdwy"] || [lowerUrl containsString:@"patrol"] || [lowerUrl containsString:@"guardian"]) {
        if (self.enableAutoPatrolNew) {
            [self queryMonopolyTaskListWithForce:YES];
            [self claimAllVisibleMonopolyRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"180020010001290531"] || [lowerUrl containsString:@"aifish"] || [lowerUrl containsString:@"antaifish"]) {
        if (self.enableAutoAIFish) {
            [self queryAIFishTaskListWithForce:YES];
            [self claimAllVisibleAIFishRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"180020010001263018"] || [lowerUrl containsString:@"farm"] || [lowerUrl containsString:@"orchard"]) {
        if (self.enableAutoFarmTasks) {
            [self queryFarmTaskListWithForce:YES];
            [self claimAllVisibleFarmRewardsOnWebView];
        }
    } else if ([lowerUrl containsString:@"2021003115672468"] || [lowerUrl containsString:@"ocean"]) {
        if (self.enableAutoOceanTasks) {
            [self queryOceanTaskListWithForce:YES];
        }
    } else if ([lowerUrl containsString:@"180020010001247580"] || [lowerUrl containsString:@"vitality"] || [lowerUrl containsString:@"reward"]) {
        if (self.enableAutoRewardTasks) {
            [self queryVitalityTaskListWithForce:YES];
            [self claimAllVisibleRewardTaskRewardsOnWebView];
        }
    }
}

- (NSString *)urlForSceneCode:(NSString *)scene bridge:(PSDJsBridge *)bridge {
    NSString *bridgeUrl = [self effectiveUrlForBridge:bridge];
    BOOL isBridgeOnLottery = bridgeUrl && ([bridgeUrl containsString:@"180020010001279274"] || [bridgeUrl.lowercaseString containsString:@"lotterymachine"]);
    if ([scene containsString:@"ACTIVITY_DRAW"]) {
        if (isBridgeOnLottery) {
            return bridgeUrl;
        }
        return self.lotteryH5Url ?: [self effectiveUrlForSceneCode:@"ANTFOREST_ACTIVITY_DRAW_TASK"];
    }
    if ([scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"]) {
        if (isBridgeOnLottery) {
            return bridgeUrl;
        }
        return self.lotteryH5Url ?: [self effectiveUrlForSceneCode:@"ANTFOREST_NORMAL_DRAW_TASK"];
    }
    if ([scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"]) {
        return self.monopolyH5Url ?: bridgeUrl ?: [self effectiveUrlForSceneCode:@"ANTFOREST_MONOPOLY_TASK_HSDWY"];
    }
    return bridgeUrl ?: [self effectiveUrlForSceneCode:scene];
}

-(void)queryVitalityTaskList {
    [self queryVitalityTaskListWithForce:NO];
}

-(void)queryVitalityTaskListWithForce:(BOOL)force {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!self.enableAutoRewardTasks || !bridge) {
        if (self.enableAutoRewardTasks) [self recordStage:@"首页后台：等待领奖励任务桥接"];
        return;
    }
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryVitalityTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryVitalityTaskListTime < 2.0)) return;
    lastQueryVitalityTaskListTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum2 = [AntForestManager getNumberRandom:15];
    NSString *urlDynamic = [self effectiveUrlForBridge:bridge];
    NSString *urlVitality = urlDynamic ?: [self effectiveUrlForSceneCode:@"ANTFOREST_VITALITY_TASK"];
    
    NSLog(@"[AntForestPort] 任务中心：正在拉取最新任务列表与阶段奖励...");
    
    BOOL isForestHomeUrl = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001247580"] || [urlVitality containsString:@"home.html"]) && ![urlVitality containsString:@"180020010001293606"]);
    BOOL isLotteryPage = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001279274"] || [urlVitality.lowercaseString containsString:@"lotterymachine"] || [urlVitality.lowercaseString containsString:@"draw"]));
    BOOL isMonopolyPage = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001293606"] || [urlVitality.lowercaseString containsString:@"monopoly"]));
    BOOL isFarmPage = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001263018"] || [urlVitality.lowercaseString containsString:@"farm"] || [urlVitality.lowercaseString containsString:@"orchard"]));
    BOOL isOceanPage = (urlVitality.length > 0 && ([urlVitality containsString:@"2021003115672468"] || [urlVitality.lowercaseString containsString:@"ocean"]));
    BOOL isAIFishPage = (urlVitality.length > 0 && ([urlVitality containsString:@"180020010001290531"] || [urlVitality.lowercaseString containsString:@"aifish"]));
    
    if (isMonopolyPage || isFarmPage || isOceanPage || isAIFishPage) {
        // 当前桥接处于其他独立子页面，严禁向其发送森林主线日常任务与领奖励 RPC，避免 3000/跨 AppId 非法调用报错
        return;
    }
    
    if (isLotteryPage) {
        // 当前桥接处于寻宝机页面，直接派发至寻宝专属查询通道
        [self queryLotteryTaskListWithForce:force];
        return;
    }
    
    // 1. 主线日常任务列表 (仅在森林主页有效，保护地或其他页面严禁调用避免 100000008 非法请求报错)
    if (isForestHomeUrl) {
        NSString *forestArg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.queryTaskList\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"version\":\"20241025\",\"source\":\"ANTFOREST\"}],\"appName\":\"antforest\",\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum2];
        manorSendRPC(bridge, forestArg1, urlVitality);
    }
    
    // 2. 现代任务中心领奖励任务 (ANTFOREST_VITALITY_TASK，在森林主页或领奖励专区执行)
    NSString *argVitality1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_VITALITY_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argVitality1, urlVitality);
}

-(void)queryLotteryTaskList {
    [self queryLotteryTaskListWithForce:NO];
}

-(void)queryLotteryTaskListWithForce:(BOOL)force {
    if (!self.enableAutoRewardTasks) return;
    PSDJsBridge *bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) {
        [self recordStage:@"森林寻宝：等待寻宝界面桥接就绪..."];
        return;
    }
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryLotteryTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryLotteryTime < 2.0)) return;
    lastQueryLotteryTime = now;
    
    sLastQueriedSceneCode = @"ANTFOREST_NORMAL_DRAW_TASK";
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlDraw1 = self.lotteryH5Url ?: [self urlForSceneCode:@"ANTFOREST_NORMAL_DRAW_TASK" bridge:bridge];
    NSString *urlDraw2 = self.lotteryH5Url ?: [self urlForSceneCode:@"ANTFOREST_ACTIVITY_DRAW_TASK" bridge:bridge];
    
    NSLog(@"[AntForestPort] 森林寻宝：已进入寻宝界面，正在拉取寻宝日常与活动任务列表...");
    
    NSString *argDraw1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_NORMAL_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argDraw1, urlDraw1);

    NSString *argDraw2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFOREST_ACTIVITY_DRAW_TASK\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argDraw2, urlDraw2);
}

-(void)queryMonopolyTaskList {
    [self queryMonopolyTaskListWithForce:NO];
}

-(void)queryMonopolyTaskListWithForce:(BOOL)force {
    if (!self.enableAutoPatrolNew) return;
    PSDJsBridge *bridge = self.monopolyBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryMonopolyTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryMonopolyTime < 2.0)) return;
    lastQueryMonopolyTime = now;
    
    sLastQueriedSceneCode = @"ANTFOREST_MONOPOLY_TASK_HSDWY";
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *monopolyScene = @"ANTFOREST_MONOPOLY_TASK_HSDWY";
    NSString *urlMonopoly = self.monopolyH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:monopolyScene];
    NSString *argMonopoly1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"source\":\"ANTFOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", monopolyScene, timeStamp, [AntForestManager getNumberRandom:15]];
    NSLog(@"[AntForestPort] 新版保护地：已进入保护地界面，读取保护地巡护任务列表");
    manorSendRPC(bridge, argMonopoly1, urlMonopoly);
}

-(void)queryOceanTaskList {
    [self queryOceanTaskListWithForce:NO];
}

-(void)queryOceanTaskListWithForce:(BOOL)force {
    if (!self.enableAutoOceanTasks) return;
    PSDJsBridge *bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryOceanTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryOceanTaskListTime < 2.0)) return;
    lastQueryOceanTaskListTime = now;
    
    // 主动让 WebView 触发 pullRefresh 事件，刷新前端页面与抽屉组件
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlOcean = self.oceanH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTOCEAN_TASK"];
    
    // 1. ANTOCEAN_TASK (海洋主任务与拼图)
    NSString *argOcean = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTOCEAN_TASK\",\"source\":\"ANT_FOREST\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    NSLog(@"[AntForestPort] 神奇海洋：正在拉取最新海洋任务与拼图奖励...");
    manorSendRPC(bridge, argOcean, urlOcean);
    
    // 2. ANTAIFISH_RESCUE_AND_RESTORE (海洋救助动物任务，如逛一逛惊喜市集等，属于神奇海洋专属场景)
    NSString *argOceanRescue = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH_RESCUE_AND_RESTORE\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argOceanRescue, urlOcean);
}

static NSString *sLastQueriedSceneCode = nil;

-(void)queryAIFishTaskList {
    [self queryAIFishTaskListWithForce:NO];
}

-(void)queryAIFishTaskListWithForce:(BOOL)force {
    if (!self.enableAutoAIFish) return;
    PSDJsBridge *bridge = self.aiFishBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    if (!bridge) return;
    initDailyTaskCache();
    sLastQueriedSceneCode = @"ANTAIFISH";
    
    static NSTimeInterval lastQueryAIFishTaskListTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && (now - lastQueryAIFishTaskListTime < 2.0)) return;
    lastQueryAIFishTaskListTime = now;
    
    [self notifyActiveH5PageToRefresh];
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *urlAIFish = self.aiFishH5Url ?: [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTAIFISH"];
    
    NSLog(@"[AntForestPort] AI摸鱼：正在拉取摸鱼任务与涂鸦机会...");
    
    // ANTAIFISH (每日赠送摸鱼次数、看15s视频等真实摸鱼任务)
    NSString *argFish1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTAIFISH\",\"source\":\"ANT_OCEAN\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argFish1, urlAIFish);
}

-(void)queryFarmTaskList {
    [self queryFarmTaskListWithForce:NO];
}

-(void)queryFarmTaskListWithForce:(BOOL)force {
    if (!self.enableAutoFarmTasks) return;
    PSDJsBridge *bridge = self.farmBridge;
    if (!bridge) return;
    initDailyTaskCache();
    
    static NSTimeInterval lastQueryFarmTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval minInterval = force ? 3.0 : 6.0;
    if (now - lastQueryFarmTime < minInterval) return;
    lastQueryFarmTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *urlDynamic = [self effectiveUrlForBridge:bridge];
    NSString *urlFarm = urlDynamic ?: [self effectiveUrlForSceneCode:@"ANTFARM_ORCHARD_TASK_V2"];
    
    NSLog(@"[AntForestPort] 芭芭农场：正在拉取最新肥料任务...");
    
    // 查询农场主任务列表 (ANTFARM_ORCHARD_TASK_V2)
    NSString *argFarm1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.listTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"source\":\"BABA_FARM\",\"requestType\":\"RPC\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    manorSendRPC(bridge, argFarm1, urlFarm);
    
    // 同时触发 Web 页面自动化呼出“领肥料”面板并领奖
    [self openFarmTaskPanelOnWebView];
    [self claimAllVisibleFarmRewardsOnWebView];
}

-(void)signVitalityTask:(NSString *)signId {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!signId.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"ANTFOREST_VITALITY_TASK"];
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.sign\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"source\":\"ANTFOREST\",\"sceneCode\":\"ANTFOREST_ENERGY_TASK_SIGN\",\"requestType\":\"RPC\",\"userId\":\"%@\",\"entityId\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", self.myUserId ?: @"", signId, timeStamp, randNum];
    manorSendRPC(bridge, arg1, url);
}

-(void)applyVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isFarmScene = [scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"];
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isFarmScene || isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = (isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST"));
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关申请
    if (isOpenGreenScene) {
        if (isFarmScene) {
            // 芭芭农场全场景任务在服务端不支持 applyTask（调用必报 3000 系统出错），直接跳过申请
            return;
        }
        NSString *argOg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.applyTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
        manorSendRPC(bridge, argOg, url);
        return;
    }
    
    // 1. 标准 antiep.applyTask
    NSString *arg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.applyTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    manorSendRPC(bridge, arg, url);
    
    // 2. OpenGreen 任务网关同步申请
    if ([scene containsString:@"VITALITY"] || [scene containsString:@"FOREST"]) {
        NSString *argOg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.applyTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, argOg, url);
    }
}

-(void)applyOceanTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    [self applyVitalityTask:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK"];
}

-(void)exchangeVitalityTaskAsset:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title caQuotaId:(NSString *)caQuotaId {
    if (!self.rewardTaskBridge && self.jsBridge) {
        self.rewardTaskBridge = self.jsBridge;
    }
    PSDJsBridge *bridge = self.rewardTaskBridge;
    if (!taskType.length || !bridge) return;
    NSString *quota = caQuotaId.length ? caQuotaId : @"ANT_FOREST_VITALITY_TO_LOTTERY";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    
    NSString *argForest = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.exchangeVitality\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"caQuotaId\":\"%@\",\"exchangeType\":\"LOTTERY_DRAW\",\"exchangeCount\":1,\"source\":\"ANTFOREST\",\"version\":\"20241025\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", quota, timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argForest, url);
}

-(void)finishVitalityTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isManorScene = [scene containsString:@"ANTFARM_FOOD"] || [scene containsString:@"MANOR"];
    BOOL isFarmScene = !isManorScene && ([scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"]);
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isManorScene) {
        bridge = [self activeManorBridge];
    } else if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *outBizNo = [NSString stringWithFormat:@"%@_%@_%@", taskType, timeStamp, [AntForestManager getNumberRandom:6]];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = isManorScene ? @"antfarm" : ((isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST")));
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关完成（避免向不支持的旧版 antiep 发送导致 3000 / 400000040 报错）
    if (isOpenGreenScene) {
        NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.finishTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@_og\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, randNum];
        manorSendRPC(bridge, argOpenGreen, url);
        return;
    }
    
    // 1. 标准 antiep.finishTask
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, randNum];
    manorSendRPC(bridge, argGreen, url);
    
    // 2. 农场非主场景（如 10021、BABA_FARM_TASK）同时补充主场景 ANTFARM_ORCHARD_TASK_V2 双向确认
    if (isFarmScene && ![scene isEqualToString:@"ANTFARM_ORCHARD_TASK_V2"] && ![scene isEqualToString:@"ORCHARD_LIMITED_TIME_CHALLENGE"]) {
        NSString *argGreenV2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"taskType\":\"%@\",\"outBizNo\":\"%@_v2\",\"requestType\":\"RPC\",\"source\":\"BABA_FARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskType, outBizNo, timeStamp, [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, argGreenV2, url);
    }
    
    // 3. 补充 antieptask.finishTaskopengreen 兼容 OpenGreen 任务网关（全场景支持）
    NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.finishTaskopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"outBizNo\":\"%@_og\",\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, outBizNo, source, timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argOpenGreen, url);
}

-(void)receiveVitalityTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    NSString *scene = sceneCode.length ? sceneCode : @"ANTFOREST_VITALITY_TASK";
    BOOL isManorScene = [scene containsString:@"ANTFARM_FOOD"] || [scene containsString:@"MANOR"];
    BOOL isFarmScene = !isManorScene && ([scene containsString:@"FARM"] || [scene containsString:@"ORCHARD"] || [scene isEqualToString:@"10021"] || [scene isEqualToString:@"3646"] || [scene hasPrefix:@"BABA_"]);
    BOOL isMonopolyScene = [scene containsString:@"MONOPOLY"] || [scene containsString:@"HSDWY"];
    BOOL isLotteryScene = [scene containsString:@"DRAW"] || [scene containsString:@"LOTTERY"];
    BOOL isRescueScene = [scene containsString:@"RESCUE"];
    BOOL isOceanScene = [scene containsString:@"OCEAN"] || isRescueScene;
    BOOL isAIFishScene = [scene containsString:@"AIFISH"] && !isRescueScene;
    BOOL isOpenGreenScene = isLotteryScene || isMonopolyScene || isOceanScene || isAIFishScene;
    PSDJsBridge *bridge = nil;
    if (isManorScene) {
        bridge = [self activeManorBridge];
    } else if (isAIFishScene) {
        bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isOceanScene) {
        bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else if (isFarmScene) {
        bridge = self.farmBridge;
    } else if (isMonopolyScene) {
        bridge = self.monopolyBridge;
    } else if (isLotteryScene) {
        bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
    } else {
        bridge = self.rewardTaskBridge ?: self.jsBridge;
    }
    if (!taskType.length || !bridge) return;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self urlForSceneCode:scene bridge:bridge];
    NSString *source = isManorScene ? @"antfarm" : ((isRescueScene || isAIFishScene) ? @"ANT_OCEAN" : (isOceanScene ? @"ANT_FOREST" : (isFarmScene ? @"BABA_FARM" : @"ANTFOREST")));
    
    // 寻宝、保护地、神奇海洋、AI摸鱼与芭芭农场专属 OpenGreen 任务网关领奖（避免向不支持的旧版 antiep 发送导致 3000 / 400000040 报错）
    if (isOpenGreenScene) {
        NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
        manorSendRPC(bridge, argOpenGreen, url);
        return;
    }
    
    // 1. 标准 antiep.receiveTaskAward
    NSString *argGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, randNum];
    manorSendRPC(bridge, argGreen, url);
    
    // 2. 农场非主场景同时发送主场景领奖确认
    if (isFarmScene && ![scene isEqualToString:@"ANTFARM_ORCHARD_TASK_V2"]) {
        NSString *argGreenV2 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.receiveTaskAward\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"ANTFARM_ORCHARD_TASK_V2\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"BABA_FARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskType, timeStamp, [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, argGreenV2, url);
    }
    
    // 3. 补充 antieptask.receiveTaskAwardopengreen（全场景支持）
    NSString *argOpenGreen = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antieptask.receiveTaskAwardopengreen\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"sceneCode\":\"%@\",\"taskType\":\"%@\",\"ignoreLimit\":false,\"requestType\":\"RPC\",\"source\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, taskType, source, timeStamp, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, argOpenGreen, url);
}

-(void)receiveOceanTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    [self receiveVitalityTaskAward:taskType sceneCode:sceneCode.length ? sceneCode : @"ANTOCEAN_TASK" taskTitle:title awardName:awardName];
}

-(void)claimVitalityStageAwardsIfNeeded {
    // 阶段累计奖励已在 handleVitalityTaskListResponse 中由服务端数据驱动精准加入队列并领取
    // 彻底停用无差别全量盲发 34 笔 RPC，杜绝网关堵塞、系统出错（3000）与 remoteLog（999）超限
}

- (void)notifyActiveH5PageToRefresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        for (PSDJsBridge *b in @[self.farmBridge ?: (id)[NSNull null], self.oceanBridge ?: (id)[NSNull null], self.aiFishBridge ?: (id)[NSNull null], self.rewardTaskBridge ?: (id)[NSNull null], self.lotteryBridge ?: (id)[NSNull null], self.monopolyBridge ?: (id)[NSNull null]]) {
            if (b != (id)[NSNull null] && b != self.jsBridge && [b respondsToSelector:@selector(contentView)]) {
                id cv = [b contentView];
                if (cv) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv) [targets addObject:wv];
                }
            }
        }
        if (!targets.count) return;
        
        NSString *js = @"(()=>{try{const evs=['pullRefresh','resume','pageResume','pageshow','visibilitychange'];evs.forEach(t=>{try{document.dispatchEvent(new CustomEvent(t,{bubbles:true,cancelable:true,data:{}}));}catch(_){try{const e=document.createEvent('HTMLEvents');e.initEvent(t,true,true);document.dispatchEvent(e);}catch(__){}}try{window.dispatchEvent(new Event(t));}catch(_){}});}catch(_){}try{if(window.AlipayJSBridge){if(window.AlipayJSBridge.fireEvent){try{window.AlipayJSBridge.fireEvent('pullRefresh');}catch(_){}try{window.AlipayJSBridge.fireEvent('resume');}catch(_){}try{window.AlipayJSBridge.fireEvent('pageResume');}catch(_){}}if(window.AlipayJSBridge.call){try{window.AlipayJSBridge.call('pullRefresh');}catch(_){}try{window.AlipayJSBridge.call('pageResume');}catch(_){}}}}catch(_){}try{const els=Array.from(document.querySelectorAll('button,div,span,a,img,svg'));for(const el of els){const txt=(el.innerText||el.textContent||'').trim();const aria=el.getAttribute('aria-label')||el.getAttribute('title')||'';const cls=String(el.className||'');if(txt==='刷新'||txt==='换一换'||txt==='换一批'||aria.includes('刷新')||cls.includes('refresh')||cls.includes('Refresh')){try{const evt=new MouseEvent('click',{bubbles:true,cancelable:true,view:window});el.dispatchEvent(evt);}catch(_){}}}}catch(_){}})();";
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        SEL resumeSel = NSSelectorFromString(@"contentViewDidResume");
        for (id target in targets) {
            if ([target respondsToSelector:resumeSel]) {
                @try { ((void (*)(id, SEL))objc_msgSend)(target, resumeSel); } @catch (NSException *e) {}
            }
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

static BOOL sHasPerformedWorkInCurrentVitalityRound = NO;
static NSInteger sVitalityAutoRefreshRounds = 0;

- (void)executeNextVitalityTask {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!self.rewardTaskBridge && self.jsBridge) {
                self.rewardTaskBridge = self.jsBridge;
            }
            BOOL anyTaskEnabled = self.enableAutoRewardTasks || self.enableAutoOceanTasks || self.enableAutoAIFish || self.enableAutoFarmTasks || self.enableAutoPatrolNew;
            PSDJsBridge *anyBridge = self.rewardTaskBridge ?: self.oceanBridge ?: self.aiFishBridge ?: self.farmBridge ?: self.monopolyBridge ?: self.jsBridge;
            if (!anyTaskEnabled || !anyBridge) {
                @synchronized(self) {
                    vitalityTaskRunning = NO;
                    gCurrentExecutingTaskKey = nil;
                    gCurrentExecutingTaskIsMultiStage = NO;
                }
                return;
            }
            
            static NSMutableSet<NSString *> *sExecutedScenesInCurrentRound = nil;
            static NSString *sLastExecutedSceneCode = nil;
            NSDictionary *item = nil;
            @synchronized(self) {
                if (!vitalityTaskQueue.count) {
                    vitalityTaskRunning = NO;
                    gCurrentExecutingTaskKey = nil;
                    gCurrentExecutingTaskIsMultiStage = NO;
                    NSSet<NSString *> *executedScenes = [sExecutedScenesInCurrentRound copy];
                    [sExecutedScenesInCurrentRound removeAllObjects];
                    
                    if (sHasPerformedWorkInCurrentVitalityRound && sVitalityAutoRefreshRounds < 2) {
                        sHasPerformedWorkInCurrentVitalityRound = NO;
                        sVitalityAutoRefreshRounds++;
                        
                        if ([executedScenes containsObject:@"FARM"]) {
                            [self recordStage:@"芭芭农场：本批次任务已执行完毕，2.5秒后刷新拉取农场任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryFarmTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"MONOPOLY"]) {
                            [self recordStage:@"新版保护地：本批次任务已执行完毕，2.5秒后刷新保护地任务列表..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryMonopolyTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"OCEAN"] || [sLastExecutedSceneCode containsString:@"OCEAN"]) {
                            [self recordStage:@"神奇海洋：本批次任务已执行完毕，2.5秒后刷新拉取海洋任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryOceanTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"AIFISH"]) {
                            [self recordStage:@"AI摸鱼：本批次任务已执行完毕，2.5秒后刷新拉取摸鱼任务最新进度..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryAIFishTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"DRAW"]) {
                            [self recordStage:@"森林寻宝：本批次任务已执行完毕，2.5秒后自动刷新寻宝与大奖..."];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self queryLotteryTaskListWithForce:YES];
                                [self notifyActiveH5PageToRefresh];
                            });
                        }
                        if ([executedScenes containsObject:@"VITALITY"] || !executedScenes.count) {
                            if (self.enableAutoRewardTasks) {
                                [self claimVitalityStageAwardsIfNeeded];
                                [self recordStage:@"领奖励：本批次任务已执行完毕，2.5秒后自动刷新拉取新解锁任务与阶梯大奖..."];
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    [self queryVitalityTaskListWithForce:YES];
                                    [self notifyActiveH5PageToRefresh];
                                });
                            }
                        }
                    } else {
                        BOOL didWork = sHasPerformedWorkInCurrentVitalityRound;
                        sHasPerformedWorkInCurrentVitalityRound = NO;
                        sVitalityAutoRefreshRounds = 0;
                        if (didWork) {
                            if ([executedScenes containsObject:@"FARM"]) {
                                [self recordStage:@"芭芭农场：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"OCEAN"]) {
                                [self recordStage:@"神奇海洋：当前所有有效海洋任务与拼图已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"AIFISH"]) {
                                [self recordStage:@"AI摸鱼：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"MONOPOLY"]) {
                                [self recordStage:@"新版保护地：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"DRAW"]) {
                                [self recordStage:@"森林寻宝：当前所有任务奖励已全部领取完毕"];
                            }
                            if ([executedScenes containsObject:@"VITALITY"] || !executedScenes.count) {
                                if (self.enableAutoRewardTasks) {
                                    [self claimVitalityStageAwardsIfNeeded];
                                    [self recordStage:@"领奖励：所有常规任务与阶梯大奖已全部处理完毕"];
                                }
                            }
                        }
                        [self notifyActiveH5PageToRefresh];
                    }
                    return;
                }
                vitalityTaskRunning = YES;
                item = [vitalityTaskQueue firstObject];
                if (item) {
                    [vitalityTaskQueue removeObjectAtIndex:0];
                }
            }
            
            if (![item isKindOfClass:NSDictionary.class]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self executeNextVitalityTask];
                });
                return;
            }
            
            PSDJsBridge *bridge = self.rewardTaskBridge;
            NSString *sceneCode = [item[@"sceneCode"] isKindOfClass:NSString.class] ? [item[@"sceneCode"] copy] : @"ANTFOREST_VITALITY_TASK";
            NSString *itemPrefix = [item[@"scenePrefix"] isKindOfClass:NSString.class] ? [item[@"scenePrefix"] copy] : nil;
            BOOL isFarmScene = [itemPrefix isEqualToString:@"芭芭农场"] || [sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"];
            BOOL isMonopolyScene = [sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"];
            BOOL isLotteryScene = [sceneCode containsString:@"NORMAL_DRAW"] || [sceneCode containsString:@"ACTIVITY_DRAW"] || [sceneCode containsString:@"DRAW"] || [sceneCode containsString:@"LOTTERY"];
            BOOL isOceanScene = [itemPrefix isEqualToString:@"神奇海洋"] || [sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"];
            if (isOceanScene) {
                bridge = self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if ([sceneCode containsString:@"AIFISH"]) {
                bridge = self.aiFishBridge ?: self.oceanBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if (isFarmScene) {
                bridge = self.farmBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            } else if (isMonopolyScene) {
                bridge = self.monopolyBridge;
            } else if (isLotteryScene) {
                bridge = self.lotteryBridge ?: self.rewardTaskBridge ?: self.jsBridge;
            }
            if (!bridge) {
                NSString *modTag = isMonopolyScene ? @"新版保护地" : (isLotteryScene ? @"森林寻宝" : (isOceanScene ? @"神奇海洋" : (isFarmScene ? @"芭芭农场" : ([sceneCode containsString:@"AIFISH"] ? @"AI摸鱼" : @"领奖励"))));
                [self recordStage:[NSString stringWithFormat:@"%@：当前未处于对应界面，跳过本任务调度", modTag]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self executeNextVitalityTask];
                });
                return;
            }
            
            NSString *action = [item[@"action"] isKindOfClass:NSString.class] ? [item[@"action"] copy] : @"";
            NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? [item[@"title"] copy] : @"任务";
            NSString *awardName = [item[@"awardName"] isKindOfClass:NSString.class] ? [item[@"awardName"] copy] : @"奖励";
            NSString *taskType = [item[@"taskType"] isKindOfClass:NSString.class] ? [item[@"taskType"] copy] : @"";
            NSString *sceneTag = isFarmScene ? @"FARM" :
                                (isMonopolyScene ? @"MONOPOLY" :
                                (isOceanScene ? @"OCEAN" :
                                ([sceneCode containsString:@"AIFISH"] ? @"AIFISH" :
                                (isLotteryScene ? @"DRAW" : @"VITALITY"))));
            sLastExecutedSceneCode = isFarmScene ? @"ANTFARM_ORCHARD_TASK_V2" : [sceneCode copy];
            @synchronized(self) {
                if (!sExecutedScenesInCurrentRound) {
                    sExecutedScenesInCurrentRound = [NSMutableSet set];
                }
                [sExecutedScenesInCurrentRound addObject:sceneTag];
            }
            BOOL isAcc = [item[@"isAcc"] respondsToSelector:@selector(boolValue)] ? [item[@"isAcc"] boolValue] : NO;
            
            NSString *taskKey = taskType.length ? [NSString stringWithFormat:@"%@:%@", sceneCode, taskType] : nil;
            gCurrentExecutingTaskKey = taskKey;
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(title, 0, 0) || [item[@"isMultiStage"] boolValue];
            gCurrentExecutingTaskIsMultiStage = isMultiIncomplete;
            
            if (taskKey.length) {
                BOOL isDone = NO;
                @synchronized(self) {
                    if (!isMultiIncomplete) {
                        if (![action isEqualToString:@"receive"] && [gDailyFailedTasks containsObject:taskKey]) {
                            isDone = YES;
                        } else if (![action isEqualToString:@"receive"] && [gDailyCompletedTasks containsObject:taskKey] && !isFarmScene) {
                            // 农场任务在服务端确认已领取前不以本地缓存阻断
                            isDone = YES;
                        }
                    }
                }
                if (isDone) {
                    // 今日已完成或已确认不可做，异步出队处理下一个，彻底杜绝同步栈深递归与主线程假死
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self executeNextVitalityTask];
                    });
                    return;
                }
            }
            
            NSString *scenePrefix = itemPrefix ?: @"领奖励";
            if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"]) {
                scenePrefix = @"神奇海洋";
            } else if ([sceneCode containsString:@"AIFISH"]) {
                scenePrefix = @"AI摸鱼";
            } else if (isFarmScene) {
                scenePrefix = @"芭芭农场";
            } else if ([sceneCode containsString:@"MONOPOLY"]) {
                scenePrefix = @"新版保护地";
            } else if ([sceneCode containsString:@"NORMAL_DRAW"] || [sceneCode containsString:@"ACTIVITY_DRAW"] || [sceneCode containsString:@"DRAW"]) {
                scenePrefix = @"森林寻宝";
            } else if (isAcc || [taskType hasPrefix:@"acc_task_energy_"]) {
                scenePrefix = @"阶梯大奖";
            }
            
            sHasPerformedWorkInCurrentVitalityRound = YES;
            
            if ([action isEqualToString:@"sign"]) {
                NSString *signId = [item[@"signId"] isKindOfClass:NSString.class] ? [item[@"signId"] copy] : @"";
                [self recordStage:[NSString stringWithFormat:@"%@：正在完成每日签到...", scenePrefix]];
                [self signVitalityTask:signId];
                if (taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks addObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            } else if ([action isEqualToString:@"exchange"]) {
                NSString *caQuotaId = [item[@"caQuotaId"] isKindOfClass:NSString.class] ? [item[@"caQuotaId"] copy] : @"";
                [self recordStage:[NSString stringWithFormat:@"%@：正在兑换“%@”...", scenePrefix, title]];
                if (taskKey.length) {
                    @synchronized(self) {
                        if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                        NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                        gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                    }
                }
                [self exchangeVitalityTaskAsset:taskType sceneCode:sceneCode taskTitle:title caQuotaId:caQuotaId];
                if (taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks addObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            } else if ([action isEqualToString:@"browse"]) {
                NSString *jumpUrl = [item[@"jumpUrl"] isKindOfClass:NSString.class] ? [item[@"jumpUrl"] copy] : @"";
                NSInteger seconds = [item[@"browseSeconds"] respondsToSelector:@selector(integerValue)] ? [item[@"browseSeconds"] integerValue] : 15;
                if (seconds <= 0) seconds = 15;
                [self recordStage:[NSString stringWithFormat:@"%@：正在后台自动执行“%@”（保持运行 %ld 秒）...", scenePrefix, title, (long)seconds]];
                
                if (taskKey.length) {
                    @synchronized(self) {
                        if (isFarmScene) {
                            if (!gFarmTaskRetryCounts) gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger stage = [item[@"stageIndex"] respondsToSelector:@selector(integerValue)] ? [item[@"stageIndex"] integerValue] : 0;
                            NSString *retryKey = isMultiIncomplete ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)stage] : taskKey;
                            NSInteger curr = [gFarmTaskRetryCounts[retryKey] integerValue];
                            gFarmTaskRetryCounts[retryKey] = @(curr + 1);
                        } else {
                            if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                            gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                        }
                    }
                }
                
                // 1. 优先调用 applyTask 注册“去完成”激活状态（仅限非农场场景，农场场景不支持该 RPC）
                if (!isFarmScene) {
                    [self applyVitalityTask:taskType sceneCode:sceneCode];
                }
                
                // 2. 如果有 jumpUrl，进行后台真实预取以满足服务端激活校验
                if (jumpUrl.length) {
                    NSString *cleanUrl = jumpUrl;
                    if ([jumpUrl containsString:@"url="]) {
                        NSRange r = [jumpUrl rangeOfString:@"url="];
                        NSString *sub = [jumpUrl substringFromIndex:r.location + 4];
                        NSRange amp = [sub rangeOfString:@"&"];
                        if (amp.location != NSNotFound) {
                            NSString *candidate = [sub substringToIndex:amp.location];
                            NSString *dec = [candidate stringByRemovingPercentEncoding] ?: candidate;
                            if ([dec hasPrefix:@"http://"] || [dec hasPrefix:@"https://"]) {
                                cleanUrl = dec;
                            } else {
                                cleanUrl = [sub stringByRemovingPercentEncoding] ?: sub;
                            }
                        } else {
                            cleanUrl = [sub stringByRemovingPercentEncoding] ?: sub;
                        }
                    }
                    if ([cleanUrl hasPrefix:@"http://"] || [cleanUrl hasPrefix:@"https://"]) {
                        NSURL *reqUrl = [NSURL URLWithString:cleanUrl];
                        if (reqUrl) {
                            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:reqUrl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
                            [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Nebula AlipayDefined(nt:WIFI,ws:393|759,fx:393|852) AliApp(AP/12.12.16.6000) AlipayClient/12.12.16.6000 Language/zh-Hans" forHTTPHeaderField:@"User-Agent"];
                            [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(__unused NSData *d, __unused NSURLResponse *res, __unused NSError *err){}] resume];
                        }
                    }
                }
                
                NSString *capturedTaskType = [taskType copy];
                NSString *capturedSceneCode = [sceneCode copy];
                NSString *capturedTitle = [title copy];
                NSString *capturedAwardName = [awardName copy];
                NSString *capturedScenePrefix = [scenePrefix copy];
                BOOL isMulti = [item[@"isMultiStage"] boolValue];
                
                // 停留指定时长后完成任务，并等待 finishTask 写入后再提交领奖
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        [self finishVitalityTask:capturedTaskType sceneCode:capturedSceneCode taskTitle:capturedTitle];
                    } @catch (NSException *e) {}
                    
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        BOOL isFailed = NO;
                        @synchronized(self) {
                            if (!isMulti && taskKey.length && [gDailyFailedTasks containsObject:taskKey]) {
                                isFailed = YES;
                            }
                        }
                        if (isFailed) {
                            // 服务端已明确不支持 RPC 完成或失败，取消后续虚假领奖，直接进入下一个任务
                            [self executeNextVitalityTask];
                            return;
                        }
                        @try {
                            [self receiveVitalityTaskAward:capturedTaskType sceneCode:capturedSceneCode taskTitle:capturedTitle awardName:capturedAwardName];
                            [self recordStage:[NSString stringWithFormat:@"%@：浏览“%@”完成，正在提交领奖...", capturedScenePrefix, capturedTitle]];
                        } @catch (NSException *e) {}
                        
                        double delayAfter = 1.2 + (arc4random_uniform(500) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (isMulti && taskKey.length) {
                                @synchronized(self) {
                                    [gDailyCompletedTasks removeObject:taskKey];
                                    [gDailyFailedTasks removeObject:taskKey];
                                    saveDailyTaskCache();
                                }
                            }
                            [self executeNextVitalityTask];
                        });
                    });
                });
                return;
            } else if ([action isEqualToString:@"finish"]) {
                [self recordStage:[NSString stringWithFormat:@"%@：正在完成“%@”...", scenePrefix, title]];
                if (taskKey.length) {
                    @synchronized(self) {
                        if (isFarmScene) {
                            if (!gFarmTaskRetryCounts) gFarmTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger stage = [item[@"stageIndex"] respondsToSelector:@selector(integerValue)] ? [item[@"stageIndex"] integerValue] : 0;
                            NSString *retryKey = isMultiIncomplete ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)stage] : taskKey;
                            NSInteger curr = [gFarmTaskRetryCounts[retryKey] integerValue];
                            gFarmTaskRetryCounts[retryKey] = @(curr + 1);
                        } else {
                            if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                            NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                            gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                        }
                    }
                }
                if (!isFarmScene) {
                    [self applyVitalityTask:taskType sceneCode:sceneCode];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self finishVitalityTask:taskType sceneCode:sceneCode taskTitle:title];
                });
            } else if ([action isEqualToString:@"receive"]) {
                [self recordStage:[NSString stringWithFormat:@"%@：正在提交领取“%@”（%@）...", scenePrefix, title, awardName]];
                if (taskKey.length) {
                    @synchronized(self) {
                        if (!gVitalityTaskRetryCounts) gVitalityTaskRetryCounts = [NSMutableDictionary dictionary];
                        NSInteger curr = [gVitalityTaskRetryCounts[taskKey] integerValue];
                        gVitalityTaskRetryCounts[taskKey] = @(curr + 1);
                    }
                }
                [self receiveVitalityTaskAward:taskType sceneCode:sceneCode taskTitle:title awardName:awardName];
            }
            
            double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
            if ([action isEqualToString:@"finish"]) {
                delaySec = 2.5 + (arc4random_uniform(500) / 1000.0);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (isMultiIncomplete && taskKey.length) {
                    @synchronized(self) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        [gDailyFailedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
                [self executeNextVitalityTask];
            });
        } @catch (NSException *e) {
            NSLog(@"[AntForestPort][VitalityTask] Exception in executeNextVitalityTask: %@", e);
            @synchronized(self) { vitalityTaskRunning = NO; }
        }
    });
}

static BOOL isMultiStageIncompleteTask(NSString *title, NSInteger progress, NSInteger require) {
    if (require > 1 && progress < require) return YES;
    if (!title.length) return NO;
    static NSRegularExpression *stageRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stageRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:\\(|（)?(\\d+)\\s*/\\s*(\\d+)(?:\\)|）)?" options:0 error:nil];
    });
    NSTextCheckingResult *match = [stageRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
    if (match && match.numberOfRanges > 2) {
        NSInteger cur = [[title substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger total = [[title substringWithRange:[match rangeAtIndex:2]] integerValue];
        if (total > 1 && cur < total) {
            return YES;
        }
    }
    return NO;
}

static BOOL isMultiStageTaskFromDict(NSDictionary *taskDict, NSDictionary *baseInfo, NSDictionary *bizInfo) {
    if (![taskDict isKindOfClass:NSDictionary.class] && ![baseInfo isKindOfClass:NSDictionary.class]) return NO;
    
    // 1. 结构化 rightsTimesLimit 与已领/已完成次数判断
    NSDictionary *rights = [taskDict[@"taskRights"] isKindOfClass:NSDictionary.class] ? taskDict[@"taskRights"] : ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskRights"] : nil);
    NSInteger limit = [rights[@"rightsTimesLimit"] integerValue];
    NSInteger received = [rights[@"alreadyReceiveAwardCount"] integerValue];
    NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
    if (limit <= 0) limit = [taskDict[@"rightsTimesLimit"] integerValue];
    if (limit <= 0) limit = [baseInfo[@"rightsTimesLimit"] integerValue];
    if (received <= 0) received = [taskDict[@"alreadyReceiveAwardCount"] integerValue];
    if (received <= 0) received = [baseInfo[@"alreadyReceiveAwardCount"] integerValue];
    if (rightsTimes <= 0) rightsTimes = [taskDict[@"rightsTimes"] integerValue];
    if (rightsTimes <= 0) rightsTimes = [baseInfo[@"rightsTimes"] integerValue];
    
    // 从 extend 解析 alreadyReceiveAwardCount
    if (received <= 0) {
        id extendVal = taskDict[@"extend"] ?: baseInfo[@"extend"];
        NSDictionary *extendDict = nil;
        if ([extendVal isKindOfClass:NSDictionary.class]) {
            extendDict = extendVal;
        } else if ([extendVal isKindOfClass:NSString.class]) {
            extendDict = [NSJSONSerialization JSONObjectWithData:[extendVal dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
        if (extendDict[@"alreadyReceiveAwardCount"]) {
            received = [extendDict[@"alreadyReceiveAwardCount"] integerValue];
        }
    }
    
    // 从 bizInfo 解析 canDoTaskTimesLimit 和 doneTimes
    id bizVal = taskDict[@"bizInfo"] ?: baseInfo[@"bizInfo"];
    NSDictionary *bDict = [bizInfo isKindOfClass:NSDictionary.class] ? bizInfo : nil;
    if (!bDict && [bizVal isKindOfClass:NSString.class]) {
        NSData *bd = [(NSString *)bizVal dataUsingEncoding:NSUTF8StringEncoding];
        if (bd) bDict = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
    }
    if ([bDict isKindOfClass:NSDictionary.class]) {
        if (limit <= 0 && bDict[@"canDoTaskTimesLimit"]) {
            limit = [bDict[@"canDoTaskTimesLimit"] integerValue];
        }
        if (bDict[@"doneTimes"]) {
            NSInteger dt = [bDict[@"doneTimes"] integerValue];
            if (dt > rightsTimes) rightsTimes = dt;
        }
        if (bDict[@"taskDoneTimes"]) {
            NSInteger tdt = [bDict[@"taskDoneTimes"] integerValue];
            if (tdt > rightsTimes) rightsTimes = tdt;
        }
    }
    NSString *bizStr = [bizVal isKindOfClass:NSString.class] ? (NSString *)bizVal : @"";
    if (bizStr.length > 0) {
        if (limit <= 0 && [bizStr containsString:@"canDoTaskTimesLimit="]) {
            static NSRegularExpression *limitRegex = nil;
            static dispatch_once_t onceLimit;
            dispatch_once(&onceLimit, ^{
                limitRegex = [NSRegularExpression regularExpressionWithPattern:@"canDoTaskTimesLimit=(\\d+)" options:0 error:nil];
            });
            NSTextCheckingResult *m = [limitRegex firstMatchInString:bizStr options:0 range:NSMakeRange(0, bizStr.length)];
            if (m && m.numberOfRanges > 1) {
                limit = [[bizStr substringWithRange:[m rangeAtIndex:1]] integerValue];
            }
        }
        if ([bizStr containsString:@"doneTimes="] || [bizStr containsString:@"taskDoneTimes="]) {
            static NSRegularExpression *doneRegex = nil;
            static dispatch_once_t onceDone;
            dispatch_once(&onceDone, ^{
                doneRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:taskDoneTimes|doneTimes)=(\\d+)" options:0 error:nil];
            });
            NSTextCheckingResult *m = [doneRegex firstMatchInString:bizStr options:0 range:NSMakeRange(0, bizStr.length)];
            if (m && m.numberOfRanges > 1) {
                NSInteger dt = [[bizStr substringWithRange:[m rangeAtIndex:1]] integerValue];
                if (dt > rightsTimes) rightsTimes = dt;
            }
        }
    }
    
    NSInteger awardCount = [rights[@"awardCount"] integerValue];
    if (awardCount <= 0) awardCount = [taskDict[@"awardCount"] integerValue];
    if (awardCount <= 0) awardCount = [baseInfo[@"awardCount"] integerValue];
    
    if (limit > 1 && rightsTimes < limit) {
        return YES;
    }
    
    NSInteger taskRequire = [baseInfo[@"taskRequire"] integerValue];
    NSInteger taskProgress = [baseInfo[@"taskProgress"] integerValue];
    if (taskRequire > 1 && taskProgress < taskRequire) {
        return YES;
    }
    
    // 芭芭农场“逛好物”类多阶段连续浏览任务判断（副标题通常包含“多次”，单次500最高1500）
    NSDictionary *disp = [taskDict[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? taskDict[@"taskDisplayConfig"] : nil;
    NSString *tTitle = [disp[@"title"] isKindOfClass:NSString.class] ? disp[@"title"] : @"";
    NSString *subTitle = [disp[@"subTitle"] isKindOfClass:NSString.class] ? disp[@"subTitle"] : @"";
    id taskIdVal = taskDict[@"taskId"] ?: taskDict[@"taskType"];
    NSString *tId = [taskIdVal respondsToSelector:@selector(stringValue)] ? [taskIdVal stringValue] : (NSString *)taskIdVal;
    if ([tId isEqualToString:@"70000"] || [tTitle containsString:@"逛好物"] || [subTitle containsString:@"多次"]) {
        return YES;
    }
    
    return NO;
}

static NSInteger extractTaskBrowseSeconds(NSDictionary *baseInfo, NSDictionary *bizInfo, NSString *taskTitle) {
    NSString *title = taskTitle ?: @"";
    NSString *taskType = [baseInfo[@"taskType"] isKindOfClass:NSString.class] ? baseInfo[@"taskType"] : @"";
    
    // 1. 优先从文案中动态正则扫描明确秒数要求 (如 "15s", "15秒", "30秒", "5秒", "10秒" 等)
    NSMutableArray<NSString *> *textCandidates = [NSMutableArray array];
    if (taskTitle.length) [textCandidates addObject:taskTitle];
    if ([bizInfo isKindOfClass:NSDictionary.class]) {
        if ([bizInfo[@"taskContent"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"taskContent"]];
        if ([bizInfo[@"taskDesc"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"taskDesc"]];
        if ([bizInfo[@"subTitle"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"subTitle"]];
        if ([bizInfo[@"desc"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"desc"]];
        if ([bizInfo[@"awardTitle"] isKindOfClass:NSString.class]) [textCandidates addObject:bizInfo[@"awardTitle"]];
    }
    if ([baseInfo isKindOfClass:NSDictionary.class] && [baseInfo[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *disp = baseInfo[@"taskDisplayConfig"];
        if ([disp[@"desc"] isKindOfClass:NSString.class]) [textCandidates addObject:disp[@"desc"]];
        if ([disp[@"title"] isKindOfClass:NSString.class]) [textCandidates addObject:disp[@"title"]];
    }
    
    static NSRegularExpression *timeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timeRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,3})\\s*(?:秒|s|S)" options:0 error:nil];
    });
    
    for (NSString *text in textCandidates) {
        if (!text.length) continue;
        NSTextCheckingResult *match = [timeRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *numStr = [text substringWithRange:[match rangeAtIndex:1]];
            NSInteger sec = [numStr integerValue];
            if (sec > 0 && sec <= 120) {
                return sec;
            }
        }
        if ([text containsString:@"1分钟"] || [text containsString:@"一分钟"]) {
            return 60;
        }
    }
    
    // 2. 检查结构化秒数字段
    if ([bizInfo isKindOfClass:NSDictionary.class]) {
        if (bizInfo[@"browseSeconds"] && [bizInfo[@"browseSeconds"] integerValue] > 0) {
            return [bizInfo[@"browseSeconds"] integerValue];
        }
        if (bizInfo[@"browseTime"] && [bizInfo[@"browseTime"] integerValue] > 0) {
            return [bizInfo[@"browseTime"] integerValue];
        }
        if (bizInfo[@"staySeconds"] && [bizInfo[@"staySeconds"] integerValue] > 0) {
            return [bizInfo[@"staySeconds"] integerValue];
        }
        if (bizInfo[@"stayTime"] && [bizInfo[@"stayTime"] integerValue] > 0) {
            return [bizInfo[@"stayTime"] integerValue];
        }
        if (bizInfo[@"duration"] && [bizInfo[@"duration"] integerValue] > 0) {
            return [bizInfo[@"duration"] integerValue];
        }
    }
    if ([baseInfo isKindOfClass:NSDictionary.class]) {
        if (baseInfo[@"browseSeconds"] && [baseInfo[@"browseSeconds"] integerValue] > 0) {
            return [baseInfo[@"browseSeconds"] integerValue];
        }
    }
    
    // 3. 检查小游戏多阶段浮球配置 miniGameMultiVisitFloatBallConfigList (如保卫向日葵、寻道大千等多阶段浮球)
    id prodParam = baseInfo[@"prodPlayParam"] ?: bizInfo[@"prodPlayParam"];
    NSDictionary *prodDict = nil;
    if ([prodParam isKindOfClass:NSString.class]) {
        prodDict = [NSJSONSerialization JSONObjectWithData:[(NSString *)prodParam dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    } else if ([prodParam isKindOfClass:NSDictionary.class]) {
        prodDict = prodParam;
    }
    
    NSInteger rTimes = 0;
    if ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class]) {
        rTimes = [baseInfo[@"taskRights"][@"rightsTimes"] integerValue];
    }
    if (rTimes <= 0 && baseInfo[@"rightsTimes"]) {
        rTimes = [baseInfo[@"rightsTimes"] integerValue];
    }
    
    if ([prodDict isKindOfClass:NSDictionary.class]) {
        NSArray *configList = prodDict[@"miniGameMultiVisitFloatBallConfigList"];
        if ([configList isKindOfClass:NSArray.class] && configList.count > 0) {
            NSInteger idx = rTimes;
            if (idx < 0) idx = 0;
            if (idx >= configList.count) idx = configList.count - 1;
            NSDictionary *stageConfig = configList[idx];
            if ([stageConfig isKindOfClass:NSDictionary.class] && stageConfig[@"timeCount"]) {
                NSInteger sec = [stageConfig[@"timeCount"] integerValue];
                if (sec > 0) {
                    return (sec > 65) ? 65 : sec;
                }
            }
        }
    }
    
    // 4. 检查常规浮球 floatBallConfig 中的 floatBallDuration
    id fbCfg = bizInfo[@"floatBallConfig"] ?: baseInfo[@"floatBallConfig"];
    if ([fbCfg isKindOfClass:NSDictionary.class]) {
        NSInteger dur = [fbCfg[@"floatBallDuration"] integerValue];
        if (dur > 0) {
            return (dur > 65) ? 65 : dur;
        }
    }
    
    // 5. 农场乐园小游戏多阶段浮球任务（如保卫向日葵、寻道大千等）按轮次默认阶梯倒计时
    NSString *upperType = taskType.uppercaseString;
    BOOL isFloatBallGame = [upperType containsString:@"FLOATBALL"] || [upperType containsString:@"NCLY"] ||
                           [title containsString:@"玩一玩"] ||
                           [[baseInfo objectForKey:@"actionType"] isEqualToString:@"MULTI_STAGE"];
    if (isFloatBallGame) {
        if (rTimes <= 2) {
            return 15;
        } else if (rTimes == 3) {
            return 30;
        } else if (rTimes >= 4 && rTimes <= 6) {
            return 60;
        } else if (rTimes >= 7) {
            return 65;
        }
        return 15;
    }
    
    // 3. 无明确倒计时要求时，外链任务需保持运行 2 秒以满足外部服务端的唤起与有效激活校验
    if ([taskType containsString:@"XIANYU"] || [taskType containsString:@"BBNC"] || [taskType containsString:@"shenqiyutang"] || [taskType containsString:@"SQYT"] || [taskType containsString:@"XLIGHT"] || [taskType containsString:@"JSKP"] || [title containsString:@"UC"] || [title containsString:@"芭芭农场"] || [title containsString:@"施肥"] || [title containsString:@"闲置"] || [title containsString:@"闲鱼"] || [title containsString:@"循环"] || [title containsString:@"市集"] || [title containsString:@"集市"] || [title containsString:@"鱼塘"]) {
        return 2;
    }
    
    // 4. 常规即时任务（如打开快手/淘宝、逛一逛各类专区等）：直接 0 秒秒做
    return 0;
}

-(void)handleVitalityTaskListResponse:(id)args {
    if ((!self.enableAutoRewardTasks && !self.enableAutoOceanTasks && !self.enableAutoAIFish && !self.enableAutoFarmTasks && !self.enableAutoPatrolNew) || ![args isKindOfClass:NSDictionary.class]) return;
    if ([AntForestManager isManorResponse:args]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = args;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        
        // 检查是否有任务执行结果回包：只有在领取奖励（receiveTaskAward）成功或任务已完结时才记为已完成
        NSString *resCode = [NSString stringWithFormat:@"%@", data[@"code"] ?: (data[@"resultCode"] ?: @"")];
        NSString *resDesc = [NSString stringWithFormat:@"%@", data[@"desc"] ?: (data[@"resultDesc"] ?: @"")];
        NSString *errMsg = [NSString stringWithFormat:@"%@", data[@"errorMessage"] ?: @""];
        NSString *opType = [NSString stringWithFormat:@"%@", (args[@"operationType"] ?: data[@"operationType"]) ?: @""];
        NSDictionary *finishVO = [data[@"finishAwardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"finishAwardResultVO"] : ([data[@"finishVO"] isKindOfClass:NSDictionary.class] ? data[@"finishVO"] : nil);
        NSDictionary *receiveVO = [data[@"receiveAwardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"receiveAwardResultVO"] : ([data[@"awardResultVO"] isKindOfClass:NSDictionary.class] ? data[@"awardResultVO"] : nil);
        BOOL finishHasNoNextStage = ([finishVO isKindOfClass:NSDictionary.class] && finishVO[@"hasNextStage"] && ![finishVO[@"hasNextStage"] boolValue]);
        NSString *respTaskType = [NSString stringWithFormat:@"%@", finishVO[@"taskType"] ?: (receiveVO[@"taskType"] ?: (data[@"taskType"] ?: (args[@"taskType"] ?: @"")))];
        NSString *respSceneCode = [NSString stringWithFormat:@"%@", finishVO[@"sceneCode"] ?: (receiveVO[@"sceneCode"] ?: (data[@"sceneCode"] ?: (args[@"sceneCode"] ?: @"")))];
        NSString *resolvedKey = (respTaskType.length && respSceneCode.length) ? [NSString stringWithFormat:@"%@:%@", respSceneCode, respTaskType] : gCurrentExecutingTaskKey;
        if (receiveVO != nil || [opType containsString:@"receiveTaskAward"] || [opType containsString:@"receive"] || [resDesc containsString:@"任务已完结"] || [resDesc containsString:@"已完结"] || [resDesc containsString:@"已领取"] || [resDesc containsString:@"无法重复领取"] || finishHasNoNextStage) {
            if ([resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"400000030"] || [resCode isEqualToString:@"400000005"] || [resCode isEqualToString:@"400000012"] || [resCode isEqualToString:@"B000000008"] || [resCode isEqualToString:@"SUCCESS"] || [data[@"success"] boolValue] || [args[@"success"] boolValue] ||
                [resDesc containsString:@"处理成功"] || [resDesc containsString:@"成功"] || [resDesc containsString:@"超过上限"] || [resDesc containsString:@"无法重复领取"] || [resDesc containsString:@"已完结"] || [resDesc containsString:@"已领取"]) {
                if (resolvedKey.length) {
                    @synchronized(self) {
                        if (gCurrentExecutingTaskIsMultiStage && ![resDesc containsString:@"已完结"] && ![resDesc containsString:@"超过上限"] && !finishHasNoNextStage) {
                            // 多阶段任务本轮领奖成功，但未彻底做满全部次数，严禁锁入今日完成缓存，并主动移除
                            [gDailyCompletedTasks removeObject:resolvedKey];
                        } else {
                            [gDailyCompletedTasks addObject:resolvedKey];
                        }
                        [gVitalityTaskRetryCounts removeObjectForKey:resolvedKey];
                        saveDailyTaskCache();
                    }
                    NSString *moduleTag = ([resolvedKey containsString:@"FARM"] || [resolvedKey containsString:@"ORCHARD"]) ? @"芭芭农场" : (([resolvedKey containsString:@"DRAW"] || [resolvedKey containsString:@"LOTTERY"]) ? @"森林寻宝" : (([resolvedKey containsString:@"MONOPOLY"] || [resolvedKey containsString:@"HSDWY"]) ? @"新版保护地" : (([resolvedKey containsString:@"RESCUE"] || [resolvedKey containsString:@"OCEAN"]) ? @"神奇海洋" : ([resolvedKey containsString:@"AIFISH"] ? @"AI摸鱼" : @"领奖励"))));
                    [self recordStage:[NSString stringWithFormat:@"%@：服务端已确认领取成功", moduleTag]];
                }
            }
        } else if ([opType containsString:@"antiep.sign"] || [opType isEqualToString:@"com.alipay.antiep.sign"]) {
            if ([resCode isEqualToString:@"100000000"] || [resCode isEqualToString:@"SUCCESS"] || [data[@"success"] boolValue] || [resDesc containsString:@"成功"] || [resDesc containsString:@"已签到"]) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:@"SIGN_TODAY"];
                    saveDailyTaskCache();
                }
                [self recordStage:@"领奖励：今日能量签到成功，已重置并激活今日累计阶梯奖励"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self queryVitalityTaskListWithForce:YES];
                });
            }
        } else if ([resCode isEqualToString:@"3000"] || [args[@"error"] integerValue] == 3000 || [data[@"error"] integerValue] == 3000 || [args[@"error"] integerValue] == 999) {
            BOOL isLegacyAntiepRpc = [opType hasPrefix:@"com.alipay.antiep."] && ![opType containsString:@"antieptask"];
            if (!isLegacyAntiepRpc) {
                static NSTimeInterval lastErrLogTime = 0;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - lastErrLogTime > 4.0) {
                    lastErrLogTime = now;
                    NSLog(@"[AntForestPort] 任务中心：服务端提示开小差/繁忙（3000/999），已自动暂停当前重试防风控");
                }
            }
        } else if ([resCode isEqualToString:@"400000040"] || [resDesc containsString:@"不支持rpc调用"] || [resCode isEqualToString:@"400000001"] || [resDesc containsString:@"任务全局配置不存在"]) {
            NSString *moduleTag = ([resolvedKey containsString:@"FARM"] || [resolvedKey containsString:@"ORCHARD"]) ? @"芭芭农场" : (([resolvedKey containsString:@"DRAW"] || [resolvedKey containsString:@"LOTTERY"]) ? @"森林寻宝" : (([resolvedKey containsString:@"MONOPOLY"] || [resolvedKey containsString:@"HSDWY"]) ? @"新版保护地" : (([resolvedKey containsString:@"RESCUE"] || [resolvedKey containsString:@"OCEAN"]) ? @"神奇海洋" : ([resolvedKey containsString:@"AIFISH"] ? @"AI摸鱼" : @"任务中心"))));
            BOOL alreadyFailed = NO;
            if (resolvedKey.length) {
                @synchronized(self) {
                    alreadyFailed = [gDailyFailedTasks containsObject:resolvedKey];
                    [gDailyFailedTasks addObject:resolvedKey];
                    [gVitalityTaskRetryCounts removeObjectForKey:resolvedKey];
                    [gFarmTaskRetryCounts removeObjectForKey:resolvedKey];
                    saveDailyTaskCache();
                }
            }
            if (!alreadyFailed) {
                [self recordStage:[NSString stringWithFormat:@"%@ · 当前任务需在对应界面手动操作完成（服务端不支持直接调用）", moduleTag]];
            }
        }
        
        @synchronized(self) {
            if (!vitalityTaskQueue) {
                vitalityTaskQueue = [NSMutableArray array];
            }
        }
        
        // 1. 签到处理 (仅在开启领奖励与寻宝时处理)
        NSDictionary *signVO = [data[@"energySignVO"] isKindOfClass:NSDictionary.class] ? data[@"energySignVO"] : nil;
        if (self.enableAutoRewardTasks && signVO) {
            NSString *signId = [signVO[@"signId"] isKindOfClass:NSString.class] ? signVO[@"signId"] : @"";
            NSString *currKey = [signVO[@"currentSignKey"] isKindOfClass:NSString.class] ? signVO[@"currentSignKey"] : @"";
            NSArray *records = [signVO[@"signRecords"] isKindOfClass:NSArray.class] ? signVO[@"signRecords"] : nil;
            BOOL isSignedToday = NO;
            for (id r in records) {
                if ([r isKindOfClass:NSDictionary.class] && [r[@"signKey"] isEqualToString:currKey]) {
                    isSignedToday = [r[@"signed"] boolValue];
                    break;
                }
            }
            NSString *signTaskKey = @"SIGN_TODAY";
            if (isSignedToday) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:signTaskKey];
                }
            } else if (signId.length) {
                // 核心业务依赖：每日零点后必须先完成签到，服务端才会重置并激活今日累计任务阶梯（40g/60g/100g）。
                // 若未签到就执行普通任务，任务完成次数不会被计入今日累计进度，导致阶梯奖励无法生效领取！
                // 因此未签到时强制优先执行签到，并彻底阻断后续普通任务解析入队，待签到成功并刷新列表后再执行。
                @synchronized(self) {
                    [gDailyCompletedTasks removeObject:signTaskKey];
                }
                [self recordStage:@"领奖励：检测到今日尚未签到，正在优先执行能量签到以激活今日累计阶梯奖励..."];
                [self signVitalityTask:signId];
                
                // 延时 1.8 秒后主动刷新任务列表，此时服务端已完成签到处理与今日阶梯重置，届时再正常执行常规任务
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self queryVitalityTaskListWithForce:YES];
                });
                return;
            }
        }
        
        // 2. 收集任务列表
        NSMutableArray<NSDictionary *> *allTaskList = [NSMutableArray array];
        NSArray *candidateGroupKeys = @[@"forestTasksNew", @"stageTaskList", @"stageInfoList", @"stagePrizeList", @"stageAwards", @"accumulateTasks", @"ladderTasks", @"taskGroupList", @"forestTasks", @"taskList"];
        for (NSString *key in candidateGroupKeys) {
            NSArray *arr = [data[key] isKindOfClass:NSArray.class] ? data[key] : nil;
            if (arr.count > 0) {
                for (id g in arr) {
                    if ([g isKindOfClass:NSDictionary.class]) {
                        NSArray *subList = g[@"taskInfoList"] ?: g[@"taskList"] ?: g[@"subTaskList"];
                        if ([subList isKindOfClass:NSArray.class]) [allTaskList addObjectsFromArray:subList];
                        else if (g[@"taskBaseInfo"] || g[@"taskType"] || g[@"taskId"]) [allTaskList addObject:g];
                    }
                }
            }
        }
        NSArray *topList = [data[@"taskInfoList"] isKindOfClass:NSArray.class] ? data[@"taskInfoList"] : ([data[@"taskList"] isKindOfClass:NSArray.class] ? data[@"taskList"] : nil);
        if (topList.count > 0) {
            [allTaskList addObjectsFromArray:topList];
        }
        
        if (!respSceneCode.length || [respSceneCode isEqualToString:@"(null)"]) {
            for (id t in allTaskList) {
                if ([t isKindOfClass:NSDictionary.class]) {
                    NSDictionary *bi = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : t;
                    NSString *sc = bi[@"sceneCode"] ?: t[@"sceneCode"] ?: t[@"iepSceneCode"];
                    if (sc.length) {
                        respSceneCode = sc;
                        break;
                    }
                }
            }
        }
        
        NSMutableArray<NSDictionary *> *newlyParsedTasks = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *accTasks = [NSMutableArray array];
        
        for (id t in allTaskList) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *baseInfo = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : t;
            NSString *taskType = [baseInfo[@"taskType"] isKindOfClass:NSString.class] ? baseInfo[@"taskType"] : ([t[@"taskId"] isKindOfClass:NSString.class] ? t[@"taskId"] : ([t[@"deliveryId"] isKindOfClass:NSString.class] ? t[@"deliveryId"] : @""));
            if (!taskType.length) continue;
            NSString *sceneCode = [baseInfo[@"sceneCode"] isKindOfClass:NSString.class] ? baseInfo[@"sceneCode"] : ([t[@"sceneCode"] isKindOfClass:NSString.class] ? t[@"sceneCode"] : ([t[@"iepSceneCode"] isKindOfClass:NSString.class] ? t[@"iepSceneCode"] : @"ANTFOREST_VITALITY_TASK"));
            NSString *taskStatus = [baseInfo[@"taskStatus"] isKindOfClass:NSString.class] ? baseInfo[@"taskStatus"] : ([t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : ([t[@"status"] isKindOfClass:NSString.class] ? t[@"status"] : @"")); // TODO, FINISHED, RECEIVED
            NSString *bizInfoStr = baseInfo[@"bizInfo"] ?: t[@"bizInfo"];
            
            NSDictionary *bizInfo = nil;
            if ([bizInfoStr isKindOfClass:NSString.class]) {
                NSData *bd = [bizInfoStr dataUsingEncoding:NSUTF8StringEncoding];
                if (bd) bizInfo = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            } else if ([bizInfoStr isKindOfClass:NSDictionary.class]) {
                bizInfo = (NSDictionary *)bizInfoStr;
            }
            
            id rawTitle = bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: t[@"title"] ?: t[@"taskTitle"] ?: baseInfo[@"taskTitle"] ?: taskType;
            NSString *taskTitle = [rawTitle isKindOfClass:NSString.class] ? (NSString *)rawTitle : ([rawTitle respondsToSelector:@selector(stringValue)] ? [rawTitle stringValue] : taskType);
            if (![taskTitle isKindOfClass:NSString.class]) taskTitle = taskType;
            BOOL autoCompleteTask = [bizInfo[@"autoCompleteTask"] boolValue];
            NSString *awardName = bizInfo[@"energy"] ?: bizInfo[@"vitality"] ?: ([taskTitle containsString:@"机会"] ? @"抽奖机会" : @"奖励");
            if (![awardName isKindOfClass:NSString.class]) awardName = @"奖励";
            
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [baseInfo[@"rightsTimesLimit"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [t[@"rightsTimesLimit"] integerValue];
            if (alreadyReceive <= 0) alreadyReceive = [baseInfo[@"alreadyReceiveAwardCount"] integerValue];
            if (alreadyReceive <= 0) alreadyReceive = [t[@"alreadyReceiveAwardCount"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [baseInfo[@"rightsTimes"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [t[@"rightsTimes"] integerValue];
            
            id extVal = t[@"extend"] ?: baseInfo[@"extend"];
            if ([extVal isKindOfClass:NSString.class] && [extVal containsString:@"alreadyReceiveAwardCount"]) {
                NSDictionary *ed = [NSJSONSerialization JSONObjectWithData:[extVal dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (ed[@"alreadyReceiveAwardCount"]) alreadyReceive = [ed[@"alreadyReceiveAwardCount"] integerValue];
            } else if ([extVal isKindOfClass:NSDictionary.class] && extVal[@"alreadyReceiveAwardCount"]) {
                alreadyReceive = [extVal[@"alreadyReceiveAwardCount"] integerValue];
            }
            if ([bizInfo isKindOfClass:NSDictionary.class]) {
                if (rightsTimesLimit <= 0 && bizInfo[@"canDoTaskTimesLimit"]) {
                    rightsTimesLimit = [bizInfo[@"canDoTaskTimesLimit"] integerValue];
                }
                if (bizInfo[@"doneTimes"]) {
                    NSInteger dt = [bizInfo[@"doneTimes"] integerValue];
                    if (dt > rightsTimes) rightsTimes = dt;
                }
                if (bizInfo[@"taskDoneTimes"]) {
                    NSInteger tdt = [bizInfo[@"taskDoneTimes"] integerValue];
                    if (tdt > rightsTimes) rightsTimes = tdt;
                }
            }
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            NSInteger taskRequire = [baseInfo[@"taskRequire"] integerValue];
            NSInteger taskProgress = [baseInfo[@"taskProgress"] integerValue];
            NSInteger awardCount = [rights[@"awardCount"] integerValue];
            if (awardCount <= 0) awardCount = [t[@"awardCount"] integerValue];
            if (awardCount <= 0) awardCount = [baseInfo[@"awardCount"] integerValue];
            
            // 优先评估多阶段任务未完成状态
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, taskProgress, taskRequire) || isMultiStageTaskFromDict(t, baseInfo, bizInfo);
            
            // 待领取状态判定：
            // 1. 服务端 taskStatus 明确为 FINISHED, CAN_RECEIVE, WAIT_AWARD, WAIT_RECEIVE 等；
            // 2. 进度已达标且未领完：taskRequire > 0 && taskProgress >= taskRequire && (rightsTimesLimit <= 0 || alreadyReceive < rightsTimesLimit)；
            // 3. 按钮文案明确带有“领”（如“领取”、“立即领取”），且绝对不含“去”，且 taskStatus 不为 TODO；
            // 4. doneTimes > alreadyReceive 仅在明确非 TODO 状态下有效（严禁将 TODO 任务误判为待领奖）。
            NSString *finishedBtnText = bizInfo[@"finishedBtnText"] ?: @"";
            NSString *btnText = bizInfo[@"btnText"] ?: bizInfo[@"buttonText"] ?: baseInfo[@"btnText"] ?: t[@"btnText"] ?: @"";
            if (!btnText.length && [t[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class]) {
                btnText = t[@"taskDisplayConfig"][@"buttonText"] ?: t[@"taskDisplayConfig"][@"btnText"] ?: @"";
            }
            BOOL isClaimBtn = ([btnText containsString:@"领"] && ![btnText containsString:@"去"]) ||
                              ([finishedBtnText containsString:@"领"] && ![finishedBtnText containsString:@"去"]) ||
                              [btnText isEqualToString:@"领取"] || [btnText isEqualToString:@"领奖"] ||
                              [btnText isEqualToString:@"领步数"] || [btnText isEqualToString:@"立即领取"] ||
                              [btnText isEqualToString:@"领取奖励"] || [btnText isEqualToString:@"领饲料"] ||
                              [btnText isEqualToString:@"领机会"] || [btnText isEqualToString:@"领摸鱼次数"] ||
                              [btnText isEqualToString:@"领能量"] || [btnText isEqualToString:@"领取能量"] ||
                              [btnText isEqualToString:@"收下"] || [btnText isEqualToString:@"开心收下"];
            BOOL isStatusCanReceive = [taskStatus isEqualToString:@"FINISHED"] ||
                                      [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"WAIT_AWARD"] ||
                                      [taskStatus isEqualToString:@"WAIT_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"TO_RECEIVE"] ||
                                      [taskStatus isEqualToString:@"SUCCESS"];
            BOOL isProgressMet = (![taskStatus isEqualToString:@"TODO"] && taskRequire > 0 && taskProgress >= taskRequire && (rightsTimesLimit <= 0 || alreadyReceive < rightsTimesLimit));
            BOOL isDoneTimesMet = (![taskStatus isEqualToString:@"TODO"] && [bizInfo isKindOfClass:NSDictionary.class] && [bizInfo[@"doneTimes"] integerValue] > alreadyReceive && [bizInfo[@"doneTimes"] integerValue] > 0);
            
            BOOL hasPendingAward = NO;
            if (isStatusCanReceive || isProgressMet || isDoneTimesMet) {
                hasPendingAward = YES;
            } else if (![taskStatus isEqualToString:@"TODO"] && isClaimBtn && ![btnText containsString:@"去"]) {
                hasPendingAward = YES;
            }
            
            // 严禁将累积肥料数量（如1400肥）与次数限制（如8次）错误比较！
            // 只要存在未领取的奖励（hasPendingAward），或者属于多阶段未完结任务，绝不视为全部完成！
            // 仅在明确已领完（RECEIVED且已领>=限制，或alreadyReceive>=rightsTimesLimit且无未领奖）时才判定为全部完成
            BOOL isAllFinished = !hasPendingAward && !isMultiIncomplete && (
                ([taskStatus isEqualToString:@"RECEIVED"] && (rightsTimesLimit <= 0 || alreadyReceive >= rightsTimesLimit)) ||
                (rightsTimesLimit > 0 && alreadyReceive >= rightsTimesLimit)
            );
            if (isAllFinished) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            
            // 如果存在待领奖且之前在失败列表中，撤销失败并重置重试计数
            if (hasPendingAward) {
                @synchronized(self) {
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                        gVitalityTaskRetryCounts[taskKey] = @0;
                    }
                    saveDailyTaskCache();
                }
            } else if (isMultiIncomplete) {
                // 服务端仍为 TODO 时必须撤销旧版留下的误缓存：只要任务未彻底完结，必须立即从已完成缓存中主动撤销移除
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                        saveDailyTaskCache();
                    }
                }
            }
            
            // 如果今日已完成且非多阶段未完成任务，坚决跳过，绝不重复排队
            if ([gDailyCompletedTasks containsObject:taskKey] && !isMultiIncomplete) {
                continue;
            }
            
            // 针对失败任务，只要非待领奖则坚决跳过，杜绝重复排队重试导致死循环
            if ([gDailyFailedTasks containsObject:taskKey] && !hasPendingAward) {
                continue;
            }

            // 防死循环熔断：如果该任务已连续尝试 2 次以上未成功，立即熔断加入失败缓存
            NSInteger vRetries = [gVitalityTaskRetryCounts[taskKey] integerValue];
            if (vRetries >= 2) {
                @synchronized(self) {
                    [gDailyFailedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                NSString *moduleTag = @"森林寻宝/任务中心";
                if ([sceneCode containsString:@"OCEAN"] || [sceneCode containsString:@"RESCUE"]) {
                    moduleTag = @"神奇海洋";
                } else if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
                    moduleTag = @"芭芭农场";
                } else if ([sceneCode containsString:@"AIFISH"]) {
                    moduleTag = @"AI摸鱼";
                } else if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
                    moduleTag = @"新版保护地";
                }
                [self recordStage:[NSString stringWithFormat:@"%@：任务 [%@] 连续尝试未成功，触发熔断跳过", moduleTag, taskTitle]];
                continue;
            }
            
            NSString *taskNode = baseInfo[@"taskNode"] ?: @"";
            if ([taskNode isEqualToString:@"PARENT"] && !hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"]) {
                continue;
            }
            
            // 仅拦截未完成的高风险任务与不可通过RPC自动完成的任务（已完成待领奖的任务绝不拦截，允许自动领奖）
            if ([sceneCode containsString:@"FARM"] || [sceneCode containsString:@"ORCHARD"] || [sceneCode isEqualToString:@"10021"] || [sceneCode isEqualToString:@"3646"] || [sceneCode hasPrefix:@"BABA_"]) {
                if (!self.enableAutoFarmTasks || !self.farmBridge) continue;
                if ([taskType containsString:@"ORCHARD_POP"] || [taskType containsString:@"MIGRATE"] || [taskType containsString:@"POP_MIGRATE"]) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeFarmTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"RESCUE"] || [sceneCode containsString:@"OCEAN"]) {
                if (!self.enableAutoOceanTasks) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeOceanTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"AIFISH"]) {
                if (!self.enableAutoAIFish) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeAIFishTask(taskType, taskTitle)) continue;
            } else if ([sceneCode containsString:@"MONOPOLY"] || [sceneCode containsString:@"HSDWY"]) {
                if (!self.enableAutoPatrolNew) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"FINISHED"] && ![taskStatus isEqualToString:@"CAN_RECEIVE"] && !isSafeMonopolyTask(taskType, taskTitle)) continue;
            } else {
                if (!self.enableAutoRewardTasks) continue;
                if (!hasPendingAward && ![taskStatus isEqualToString:@"CAN_RECEIVE"]) {
                    if (![taskStatus isEqualToString:@"FINISHED"] && !isSafeRewardTask(taskType, taskTitle)) continue;
                }
            }
            
            // 阶梯大奖 (阶段宝箱 / 额外累计奖励)
            NSDictionary *groupInfo = [t[@"taskGroupInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskGroupInfo"] : nil;
            NSString *groupType = groupInfo[@"taskGroupType"] ?: @"";
            BOOL isAccTask = ([groupType containsString:@"ACC"] || [groupType containsString:@"STAGE"] || [groupType containsString:@"LADDER"] ||
                              [taskType hasPrefix:@"acc_"] || [taskType containsString:@"_acc_"] || [taskType containsString:@"ACC_"] || [taskType containsString:@"_ACC_"] ||
                              [taskType containsString:@"stage_"] || [taskType containsString:@"STAGE_"]);
            
            if (isAccTask) {
                NSInteger awardCount = [rights[@"awardCount"] integerValue];
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"awardCount"] integerValue];
                }
                if (awardCount <= 0) {
                    awardCount = [bizInfo[@"energy"] integerValue];
                }
                
                BOOL canClaim = (![taskStatus isEqualToString:@"RECEIVED"] &&
                                 ([taskStatus isEqualToString:@"FINISHED"] ||
                                  [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                  (rightsTimesLimit > 0 && alreadyReceive < rightsTimesLimit && rightsTimes > alreadyReceive) ||
                                  (alreadyReceive == 0 && rightsTimes > 0)));
                
                if (canClaim) {
                    [accTasks addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle.length ? taskTitle : [NSString stringWithFormat:@"阶段累计额外奖励（%ldg）", (long)awardCount],
                        @"awardName": (awardCount > 0) ? [NSString stringWithFormat:@"%ldg 能量", (long)awardCount] : @"额外奖励",
                        @"isAcc": @YES
                    }];
                }
                continue;
            }
            
            NSString *prodPlayType = baseInfo[@"taskProdPlayType"] ?: @"";
            NSString *prodParamStr = baseInfo[@"prodPlayParam"];
            NSString *caQuotaId = nil;
            if ([prodParamStr isKindOfClass:NSString.class]) {
                NSData *pd = [prodParamStr dataUsingEncoding:NSUTF8StringEncoding];
                if (pd) {
                    NSDictionary *pObj = [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil];
                    if (pObj[@"caQuotaId"]) caQuotaId = pObj[@"caQuotaId"];
                }
            }
            
            // 检查队列中是否已经排队
            BOOL alreadyQueued = NO;
            @synchronized(self) {
                for (NSDictionary *q in vitalityTaskQueue) {
                    if ([q[@"taskType"] isEqualToString:taskType] && [q[@"sceneCode"] isEqualToString:sceneCode]) {
                        alreadyQueued = YES;
                        break;
                    }
                }
            }
            if (alreadyQueued) continue;
            
            NSString *jumpUrl = baseInfo[@"taskJumpUrl"] ?: bizInfo[@"taskJumpUrl"] ?: bizInfo[@"targetUrl"] ?: t[@"taskJumpUrl"] ?: bizInfo[@"url"] ?: @"";
            if (![jumpUrl isKindOfClass:NSString.class]) jumpUrl = @"";
            
            NSInteger explicitBrowseSec = extractTaskBrowseSeconds(t ?: baseInfo, bizInfo, taskTitle);
            BOOL requiresTimedBrowse = (explicitBrowseSec > 0);
            
            if ([prodPlayType isEqualToString:@"EXCHANGE_ASSET"] || [taskType containsString:@"VITALITY_EXCHANGE"] || [taskType isEqualToString:@"NORMAL_DRAW_EXCHANGE_VITALITY"]) {
                [newlyParsedTasks addObject:@{
                    @"action": @"exchange",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"caQuotaId": caQuotaId ?: @""
                }];
            } else if (hasPendingAward) {
                [newlyParsedTasks addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": awardName,
                    @"isMultiStage": @(isMultiIncomplete)
                }];
            } else if ([taskStatus isEqualToString:@"TODO"] || (rightsTimesLimit > 0 && rightsTimes < rightsTimesLimit) || isMultiIncomplete) {
                if (requiresTimedBrowse) {
                    // 仅对明确要求倒计时/停留指定时长的任务进行定时停留
                    [newlyParsedTasks addObject:@{
                        @"action": @"browse",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardName,
                        @"jumpUrl": jumpUrl,
                        @"browseSeconds": @(explicitBrowseSec),
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                } else {
                    // 常规逛一逛/浏览/去完成等即时任务，直接提交完成并领奖，无需停留15秒
                    [newlyParsedTasks addObject:@{
                        @"action": @"finish",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                    [newlyParsedTasks addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardName,
                        @"isMultiStage": @(isMultiIncomplete)
                    }];
                }
            }
        }
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueuedCount = 0;
        @synchronized(self) {
            if (newlyParsedTasks.count > 0) {
                BOOL isMainVitality = [newlyParsedTasks.firstObject[@"sceneCode"] isEqualToString:@"ANTFOREST_VITALITY_TASK"];
                if (isMainVitality && vitalityTaskQueue.count > 0) {
                    // 主线领奖励任务优先插入队列前方执行（若队首为每日签到，保持签到在第 0 位优先执行）
                    NSInteger insertIdx = 0;
                    if ([vitalityTaskQueue.firstObject[@"action"] isEqualToString:@"sign"]) {
                        insertIdx = 1;
                    }
                    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIdx, newlyParsedTasks.count)];
                    [vitalityTaskQueue insertObjects:newlyParsedTasks atIndexes:indexes];
                } else {
                    [vitalityTaskQueue addObjectsFromArray:newlyParsedTasks];
                }
            }
            if (accTasks.count > 0) {
                [vitalityTaskQueue addObjectsFromArray:accTasks];
            }
            totalQueuedCount = vitalityTaskQueue.count;
            if (totalQueuedCount > 0 && !vitalityTaskRunning) {
                shouldStartLoop = YES;
                vitalityTaskRunning = YES;
            }
        }
        
        if (shouldStartLoop) {
            NSString *targetScene = newlyParsedTasks.firstObject[@"sceneCode"] ?: (accTasks.firstObject[@"sceneCode"] ?: respSceneCode);
            NSString *planningPrefix = @"领奖励与森林寻宝";
            if ([targetScene containsString:@"RESCUE"] || [targetScene containsString:@"OCEAN"]) {
                planningPrefix = @"神奇海洋";
            } else if ([targetScene containsString:@"AIFISH"]) {
                planningPrefix = @"AI摸鱼";
            } else if ([targetScene containsString:@"FARM"] || [targetScene containsString:@"ORCHARD"]) {
                planningPrefix = @"芭芭农场";
            } else if ([targetScene containsString:@"MONOPOLY"] || [targetScene containsString:@"HSDWY"]) {
                planningPrefix = @"新版保护地";
            } else if ([targetScene containsString:@"DRAW"] || [targetScene containsString:@"LOTTERY"]) {
                planningPrefix = @"森林寻宝";
            }
            [self recordStage:[NSString stringWithFormat:@"%@：规划 %lu 项待完成与领奖操作", planningPrefix, (unsigned long)totalQueuedCount]];
            [self executeNextVitalityTask];
        } else if (totalQueuedCount == 0 && !vitalityTaskRunning && allTaskList.count > 0) {
            NSLog(@"[AntForestPort] %@：当前无待领待做任务", respSceneCode);
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][VitalityTask] Exception in handleVitalityTaskListResponse: %@", e);
    }
}

-(void)handleOceanTaskListResponse:(id)args {
    if (![args isKindOfClass:NSDictionary.class]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = args;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        NSArray *oceanList = [data[@"antOceanTaskVOList"] isKindOfClass:NSArray.class] ? data[@"antOceanTaskVOList"] : nil;
        if (!oceanList.count) return;
        
        NSLog(@"\n🌊 [神奇海洋·任务探测] ══════════════ 共发现 %lu 个海洋任务 ══════════════", (unsigned long)oceanList.count);
        [self recordStage:[NSString stringWithFormat:@"神奇海洋：探测到 %lu 个任务，正在解析列表...", (unsigned long)oceanList.count]];
        
        NSMutableArray<NSDictionary *> *tasksToQueue = [NSMutableArray array];
        
        for (NSUInteger idx = 0; idx < oceanList.count; idx++) {
            id t = oceanList[idx];
            if (![t isKindOfClass:NSDictionary.class]) continue;
            
            NSString *taskType = [t[@"taskType"] isKindOfClass:NSString.class] ? t[@"taskType"] : @"";
            NSString *sceneCode = [t[@"sceneCode"] isKindOfClass:NSString.class] ? t[@"sceneCode"] : @"ANTOCEAN_TASK";
            NSString *taskStatus = [t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : @"";
            NSString *awardType = [t[@"awardType"] isKindOfClass:NSString.class] ? t[@"awardType"] : @"";
            NSString *awardCount = [NSString stringWithFormat:@"%@", t[@"awardCount"] ?: @"1"];
            
            NSDictionary *bizInfo = nil;
            id rawBiz = t[@"bizInfo"];
            if ([rawBiz isKindOfClass:NSDictionary.class]) {
                bizInfo = rawBiz;
            } else if ([rawBiz isKindOfClass:NSString.class]) {
                NSData *bd = [(NSString *)rawBiz dataUsingEncoding:NSUTF8StringEncoding];
                if (bd) bizInfo = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            }
            
            NSString *taskTitle = bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: taskType;
            NSString *taskDesc = bizInfo[@"taskDesc"] ?: bizInfo[@"desc"] ?: @"";
            NSString *taskJumpBtn = bizInfo[@"taskJumpBtn"] ?: @"";
            
            NSString *awardDesc = [awardType isEqualToString:@"RIGHTS"] ? [NSString stringWithFormat:@"拼图碎片x%@", awardCount] : [NSString stringWithFormat:@"%@x%@", awardType, awardCount];
            
            // 逐条控制台格式化打印，杜绝系统底层单行超长截断
            NSLog(@"🌊 [海洋任务 %lu/%lu] 标题:【%@】| 标识: %@ | 状态: %@ | 按钮:【%@】| 奖励: %@ | 描述: %@",
                  (unsigned long)(idx + 1), (unsigned long)oceanList.count,
                  taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc, taskDesc);
            
            [self recordProbeLog:[NSString stringWithFormat:@"[神奇海洋 %lu/%lu] 标题:%@ | 标识:%@ | 状态:%@ | 按钮:%@ | 奖励:%@",
                                  (unsigned long)(idx + 1), (unsigned long)oceanList.count,
                                  taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc]];
            
            if (!self.enableAutoOceanTasks) continue;
            
            NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
            BOOL isMultiIncomplete = isMultiStageIncompleteTask(taskTitle, 0, 0) || isMultiStageTaskFromDict(t, nil, bizInfo);
            
            BOOL canClaim = [taskStatus isEqualToString:@"FINISHED"] ||
                            [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                            ([taskJumpBtn containsString:@"领"] && ![taskStatus isEqualToString:@"RECEIVED"]);
            
            if (canClaim) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                    }
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                    }
                    saveDailyTaskCache();
                }
                [tasksToQueue addObject:@{
                    @"action": @"receive",
                    @"taskType": taskType,
                    @"sceneCode": sceneCode,
                    @"title": taskTitle,
                    @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                    @"scenePrefix": @"神奇海洋",
                    @"isMultiStage": @(isMultiIncomplete)
                }];
                continue;
            }
            
            NSDictionary *rights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : nil;
            NSInteger alreadyReceive = [rights[@"alreadyReceiveAwardCount"] integerValue];
            NSInteger rightsTimesLimit = [rights[@"rightsTimesLimit"] integerValue];
            NSInteger rightsTimes = [rights[@"rightsTimes"] integerValue];
            if (rightsTimesLimit <= 0) rightsTimesLimit = [t[@"rightsTimesLimit"] integerValue];
            if (rightsTimes <= 0) rightsTimes = [t[@"rightsTimes"] integerValue];
            if (alreadyReceive <= 0) {
                id ext = t[@"extend"];
                if ([ext isKindOfClass:NSString.class] && [ext containsString:@"alreadyReceiveAwardCount"]) {
                    NSDictionary *ed = [NSJSONSerialization JSONObjectWithData:[ext dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    alreadyReceive = [ed[@"alreadyReceiveAwardCount"] integerValue];
                }
            }
            BOOL isDoneAll = !isMultiIncomplete && ([taskStatus isEqualToString:@"RECEIVED"] || (rightsTimesLimit > 0 && rightsTimes >= rightsTimesLimit));
            if (isDoneAll) {
                @synchronized(self) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                }
                continue;
            }
            
            if ([taskStatus isEqualToString:@"TODO"] || isMultiIncomplete) {
                @synchronized(self) {
                    if ([gDailyCompletedTasks containsObject:taskKey]) {
                        [gDailyCompletedTasks removeObject:taskKey];
                    }
                    if ([gDailyFailedTasks containsObject:taskKey]) {
                        [gDailyFailedTasks removeObject:taskKey];
                    }
                    saveDailyTaskCache();
                }
            }
            if ([gDailyFailedTasks containsObject:taskKey]) {
                continue;
            }
            if ([gDailyCompletedTasks containsObject:taskKey] && !isMultiIncomplete) {
                continue;
            }
            
            if ([taskStatus isEqualToString:@"TODO"]) {
                if (isSafeOceanTask(taskType, taskTitle)) {
                    NSInteger browseSec = extractTaskBrowseSeconds(t, bizInfo, taskTitle);
                    if (browseSec > 0) {
                        NSString *jumpUrl = bizInfo[@"targetUrl"] ?: bizInfo[@"jumpUrl"] ?: @"";
                        [tasksToQueue addObject:@{
                            @"action": @"browse",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                            @"scenePrefix": @"神奇海洋",
                            @"browseSeconds": @(browseSec),
                            @"jumpUrl": jumpUrl,
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                    } else {
                        [tasksToQueue addObject:@{
                            @"action": @"finish",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                        [tasksToQueue addObject:@{
                            @"action": @"receive",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": [awardType isEqualToString:@"RIGHTS"] ? @"拼图碎片" : @"海洋奖励",
                            @"scenePrefix": @"神奇海洋",
                            @"isMultiStage": @(isMultiIncomplete)
                        }];
                    }
                } else {
                    NSLog(@"🌊 [神奇海洋] 任务【%@】属于互动型/答题/连续签到/外部游戏任务，不支持直接RPC完成，已自动跳过", taskTitle);
                }
            }
        }
        NSLog(@"🌊 [神奇海洋·任务探测] ══════════════════════════════════════════════\n");
        
        if (!self.enableAutoOceanTasks) return;
        if (!tasksToQueue.count) {
            [self recordStage:@"神奇海洋：当前所有有效海洋任务与拼图已全部领取完毕"];
            return;
        }
        
        BOOL shouldStartLoop = NO;
        NSUInteger totalQueued = 0;
        @synchronized(self) {
            if (!vitalityTaskQueue) vitalityTaskQueue = [NSMutableArray array];
            for (NSDictionary *task in tasksToQueue) {
                NSString *tk = [NSString stringWithFormat:@"%@:%@:%@", task[@"sceneCode"], task[@"taskType"], task[@"action"]];
                BOOL alreadyInQueue = NO;
                for (NSDictionary *q in vitalityTaskQueue) {
                    NSString *qk = [NSString stringWithFormat:@"%@:%@:%@", q[@"sceneCode"], q[@"taskType"], q[@"action"]];
                    if ([qk isEqualToString:tk]) { alreadyInQueue = YES; break; }
                }
                if (!alreadyInQueue) {
                    [vitalityTaskQueue addObject:task];
                }
            }
            totalQueued = vitalityTaskQueue.count;
            if (!vitalityTaskRunning && totalQueued > 0) {
                vitalityTaskRunning = YES;
                shouldStartLoop = YES;
            }
        }
        if (shouldStartLoop) {
            [self recordStage:[NSString stringWithFormat:@"神奇海洋：规划 %lu 项待完成与领拼图操作", (unsigned long)tasksToQueue.count]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self executeNextVitalityTask];
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][OceanTask] Exception in handleOceanTaskListResponse: %@", e);
    }
}

- (void)executeFarmScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 farmBridge，且不是森林主页 bridge，提取其 webView
        id fb = self.farmBridge;
        if (fb && fb != self.jsBridge) {
            if ([fb respondsToSelector:@selector(contentView)]) {
                id cv = [fb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([fb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(fb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，仅扫描当前显示中的农场 WKWebView（严禁扫描任何森林主页或包含 60000002/home.html 的 WebView）
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            // 严格核查 URL：如果是森林主页，坚决排除
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"] || [us containsString:@"66666674"] || [us containsString:@"antfarm"] || [us containsString:@"manor"] || [us containsString:@"2017090512380701"]) {
                                        continue;
                                    }
                                }
                            }
                            [targets addObject:v];
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)openFarmTaskPanelOnWebView {
    [self executeFarmScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(curUrl.includes('66666674')||curUrl.includes('antfarm')||curUrl.includes('manor')||curUrl.includes('2017090512380701'))return;"
     "if(!curUrl.includes('babafarm')&&!curUrl.includes('alipayfarm')&&!curUrl.includes('tmfarm')&&!curUrl.includes('orchard')&&!curUrl.includes('180020010001263018')&&!curUrl.includes('68687599'))return;"
     "if(curUrl.includes('60000002')||curUrl.includes('180020010001247580')||curUrl.includes('home.html'))return;"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const href=(el.getAttribute('href')||el.getAttribute('data-href')||el.getAttribute('data-url')||'').toLowerCase();"
     "    if(href.includes('60000002')||href.includes('forest')||href.includes('home.html'))return;"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function findAndOpenPanel(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  for(const el of all){"
     "    const txt=(el.innerText||el.textContent||'').trim().replace(/\\s+/g,'');"
     "    if(txt.length>0&&txt.length<=10){"
     "      if(txt.includes('森林')||txt.includes('能量')||txt.includes('去森林')||txt.includes('蚂蚁森林'))continue;"
     "      if(txt==='集肥料'||txt==='领肥料'||txt==='赚肥料'||txt==='去集肥'||txt==='去领肥'||txt==='施肥得肥料'||txt==='领肥'||txt==='集肥'||"
     "         txt==='做任务集肥'||txt==='做任务集肥料'||txt==='做任务得肥料'||(txt.includes('肥料')&&(txt.includes('集')||txt.includes('领')||txt.includes('赚')))){"
     "        const target=el.closest('button,[role=button],div[class*=btn],div[class*=button],div[class*=jifei],div[class*=feiliao]')||el;"
     "        triggerClick(target);"
     "        triggerClick(el);"
     "        console.log('[AntForestPort] Auto-opened farm task panel by text: '+txt);"
     "        return true;"
     "      }"
     "    }"
     "  }"
     "  const imgs=Array.from(document.querySelectorAll('img'));"
     "  for(const img of imgs){"
     "    const src=img.src||'';"
     "    const alt=img.alt||img.title||'';"
     "    if(src.includes('TB1Zbsk')||src.includes('O1CN01JYnXvW')||src.includes('TB1Sqcy')||src.includes('O1CN01vQgu2d')||src.includes('jifei')||src.includes('feiliao')||src.includes('manure')||src.includes('fertilizer')||alt.includes('集肥')||alt.includes('领肥')||alt.includes('肥料')){"
     "      const target=img.closest('button,[role=button],div[class*=btn],div[class*=button],div')||img;"
     "      triggerClick(target);"
     "      triggerClick(img);"
     "      console.log('[AntForestPort] Auto-opened farm task panel by img');"
     "      return true;"
     "    }"
     "  }"
     "  const sels=['[data-spm*=\"jifei\"]','[data-spm*=\"feiliao\"]','[class*=\"jifei\"]','[class*=\"feiliao\"]','[aria-label*=\"集肥\"]','[aria-label*=\"领肥\"]','[aria-label*=\"肥料\"]'];"
     "  for(const s of sels){"
     "    const el=document.querySelector(s);"
     "    if(el){"
     "      const txt=(el.innerText||'').trim();"
     "      if(txt.includes('森林')||txt.includes('能量'))continue;"
     "      triggerClick(el);"
     "      console.log('[AntForestPort] Auto-opened farm task panel by selector: '+s);"
     "      return true;"
     "    }"
     "  }"
     "  return false;"
     "}"
     "findAndOpenPanel();"
     "setTimeout(findAndOpenPanel, 400);"
     "setTimeout(findAndOpenPanel, 1200);"
     "setTimeout(findAndOpenPanel, 2500);"
     "}catch(e){console.error('[AntForestPort] openFarmTaskPanel error: ',e);}})();"];
}

- (void)claimAllVisibleFarmRewardsOnWebView {
    [self executeFarmScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(curUrl.includes('66666674')||curUrl.includes('antfarm')||curUrl.includes('manor')||curUrl.includes('2017090512380701'))return;"
     "if(!curUrl.includes('babafarm')&&!curUrl.includes('alipayfarm')&&!curUrl.includes('tmfarm')&&!curUrl.includes('orchard')&&!curUrl.includes('180020010001263018')&&!curUrl.includes('68687599'))return;"
     "if(curUrl.includes('60000002')||curUrl.includes('180020010001247580')||curUrl.includes('home.html'))return;"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const href=(el.getAttribute('href')||el.getAttribute('data-href')||'').toLowerCase();"
     "    if(href.includes('60000002')||href.includes('forest')||href.includes('home.html'))return;"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function scanAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  let claimCnt=0;"
     "  const clickedSet=new Set();"
     "  for(const el of all){"
     "    if(el.children.length===0&&el.innerText){"
     "      const txt=el.innerText.trim().replace(/\\s+/g,'');"
     "      if(txt.includes('森林')||txt.includes('能量'))continue;"
     "      if(txt==='领取'||txt==='点击领取'||txt==='立即领取'||txt==='领奖'||txt==='点击领奖'||txt==='立即领奖'||txt==='收下继续施肥'||txt==='收下肥料'||txt==='开心收下'||txt==='我知道了'||txt==='收下'){"
     "        const target=el.closest('button,[role=button],div[class*=btn],div[class*=button]')||el;"
     "        if(!clickedSet.has(target)){"
     "          clickedSet.add(target);"
     "          triggerClick(target);"
     "          triggerClick(el);"
     "          claimCnt++;"
     "        }"
     "      }"
     "    }"
     "  }"
     "  if(claimCnt>0)console.log('[AntForestPort] Auto-claimed '+claimCnt+' farm reward buttons');"
     "}"
     "scanAndClick();"
     "setTimeout(scanAndClick, 500);"
     "setTimeout(scanAndClick, 1200);"
     "setTimeout(scanAndClick, 2500);"
     "setTimeout(scanAndClick, 4500);"
     "if(!window.__afFarmObserverInstalled){"
     "  window.__afFarmObserverInstalled=true;"
     "  let debounceTimer=null;"
     "  const obs=new MutationObserver(()=>{if(debounceTimer)return;debounceTimer=setTimeout(()=>{debounceTimer=null;scanAndClick();},300);});"
     "  obs.observe(document.body||document.documentElement,{childList:true,subtree:true});"
     "  setTimeout(()=>{try{obs.disconnect();window.__afFarmObserverInstalled=false;}catch(e){}},30000);"
     "}"
     "}catch(e){console.error('[AntForestPort] claimAllVisibleFarmRewards error: ',e);}})();"];
}

- (void)executeMonopolyScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 monopolyBridge，且不是森林主页 bridge，提取其 webView
        id mb = self.monopolyBridge;
        if (mb && mb != self.jsBridge) {
            if ([mb respondsToSelector:@selector(contentView)]) {
                id cv = [mb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([mb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(mb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，仅扫描当前显示中的保护地大富翁 WKWebView（排除任何森林主页或包含 60000002/home.html 的 WebView）
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"]) {
                                        continue;
                                    }
                                    if ([us containsString:@"180020010001293606"] || [us containsString:@"2060090000398301"] || [us containsString:@"monopoly"] || [us containsString:@"hsdwy"] || [us containsString:@"patrol"] || [us containsString:@"guardian"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)openMonopolyTaskPanelOnWebView {
    if (self.monopolyDrawerOpened) return;
    [self executeMonopolyScriptOnWebView:@"(()=>{try{"
     "if(window.__afMonopolyDrawerEverOpened)return;"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(!curUrl.includes('180020010001293606')&&!curUrl.includes('2060090000398301')&&!curUrl.includes('monopoly')&&!curUrl.includes('hsdwy')&&!curUrl.includes('patrol')&&!curUrl.includes('guardian'))return;"
     "if(curUrl.includes('60000002')||curUrl.includes('180020010001247580')||curUrl.includes('home.html'))return;"
     "const isDrawerOpen=Array.from(document.querySelectorAll('*')).some(el=>{"
     "  const t=(el.innerText||el.textContent||'').trim();"
     "  return t==='做任务领骰子'||t==='做任务得机会'||t==='更多巡护步数'||t==='巡护任务'||t==='做任务领步数'||t.includes('做任务领骰子')||t.includes('更多巡护步数');"
     "});"
     "if(isDrawerOpen){window.__afMonopolyDrawerEverOpened=true;return;}"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function findAndOpenPanel(){"
     "  if(window.__afMonopolyDrawerEverOpened)return true;"
     "  const all=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],[class*=\"button\"],div,span,p'));"
     "  const keywords=['更多步数','更多巡护步数','领步数','赚步数','做任务领步数','做任务领骰子','做任务得机会','领骰子','做任务','巡护步数','巡护任务','步数'];"
     "  for(const kw of keywords){"
     "    for(const el of all){"
     "      const rect=el.getBoundingClientRect();"
     "      if(rect.width<=0||rect.height<=0||rect.width>280||rect.height>140)continue;"
     "      const txt=(el.innerText||el.textContent||'').trim().replace(/\\s+/g,'');"
     "      const aria=(el.getAttribute('aria-label')||'').trim();"
     "      if(txt===kw||aria===kw||(kw.length>=3&&(txt.includes(kw)||aria.includes(kw)))){"
     "        window.__afMonopolyDrawerEverOpened=true;"
     "        const target=el.closest('button,a,[role=\"button\"],[class*=\"btn\"],[class*=\"button\"]')||el;"
     "        triggerClick(target);"
     "        triggerClick(el);"
     "        try{console.log('PATROL_LOG:'+JSON.stringify({type:'STATUS',msg:'保护地大富翁：已自动点击【'+kw+'】展开步数任务抽屉'}));}catch(e){}"
     "        return true;"
     "      }"
     "    }"
     "  }"
     "  return false;"
     "}"
     "if(!findAndOpenPanel()){"
     "  setTimeout(findAndOpenPanel, 500);"
     "}"
     "}catch(e){console.error('[AntForestPort] openMonopolyTaskPanel error: ',e);}})();"];
    
    // 打开面板后，顺便扫描并自动领取已完成的步数奖励
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self claimAllVisibleMonopolyRewardsOnWebView];
    });
}

- (void)claimAllVisibleMonopolyRewardsOnWebView {
    [self executeMonopolyScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(!curUrl.includes('180020010001293606')&&!curUrl.includes('2060090000398301')&&!curUrl.includes('monopoly')&&!curUrl.includes('hsdwy')&&!curUrl.includes('patrol')&&!curUrl.includes('guardian'))return;"
     "if(curUrl.includes('60000002')||curUrl.includes('180020010001247580')||curUrl.includes('home.html'))return;"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function scanAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  let claimCnt=0;"
"  const all=Array.from(document.querySelectorAll('*'));"
     "  let claimCnt=0;"
     "  const clickedSet=new Set();"
     "  for(const el of all){"
     "    if(el.children.length===0&&el.innerText){"
     "      const txt=el.innerText.trim().replace(/\\s+/g,'');"
     "      if(txt.includes('森林'))continue;"
     "      if(txt==='领取'||txt==='点击领取'||txt==='立即领取'||txt==='领奖'||txt==='点击领奖'||txt==='立即领奖'||txt==='收下'||txt==='开心收下'||txt==='我知道了'||txt==='领步数'||txt==='领骰子'||txt==='领能量'||txt==='领取能量'||txt.includes('领取')||txt.includes('领奖')){"
     "        const target=el.closest('button,[role=button],div[class*=btn],div[class*=button]')||el;"
     "        if(!clickedSet.has(target)){"
     "          clickedSet.add(target);"
     "          triggerClick(target);"
     "          triggerClick(el);"
     "          claimCnt++;"
     "        }"
     "      }"
     "    }"
     "  }"
     "  if(claimCnt>0)console.log('[AntForestPort] Auto-claimed '+claimCnt+' monopoly reward buttons');"
     "}"
     "scanAndClick();"
     "if(!window.__afMonopolyRewardObserverInstalled){"
     "  window.__afMonopolyRewardObserverInstalled=true;"
     "  const obs=new MutationObserver(()=>{scanAndClick();});"
     "  obs.observe(document.body||document.documentElement,{childList:true,subtree:true});"
     "  setTimeout(()=>{try{obs.disconnect();window.__afMonopolyRewardObserverInstalled=false;}catch(e){}},30000);"
     "}"
     "}catch(e){console.error('[AntForestPort] claimAllVisibleMonopolyRewards error: ',e);}})();"];
}

- (void)executeAIFishScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        id bridge = self.aiFishBridge;
        if (bridge && bridge != self.jsBridge) {
            if ([bridge respondsToSelector:@selector(contentView)]) {
                id cv = [bridge contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([bridge respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"home.html"]) continue;
                                    if ([us containsString:@"180020010001290531"] || [us containsString:@"aifish"] || [us containsString:@"antaifish"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)claimAllVisibleAIFishRewardsOnWebView {
    [self executeAIFishScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(!curUrl.includes('180020010001290531')&&!curUrl.includes('aifish')&&!curUrl.includes('antaifish'))return;"
     "if(curUrl.includes('60000002')||curUrl.includes('home.html'))return;"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function scanAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  let claimCnt=0;"
     "  const clickedSet=new Set();"
     "  for(const el of all){"
     "    if(el.children.length===0&&el.innerText){"
     "      const txt=el.innerText.trim().replace(/\\s+/g,'');"
     "      if(txt.includes('森林'))continue;"
     "      if(txt==='领取'||txt==='点击领取'||txt==='立即领取'||txt==='领奖'||txt==='点击领奖'||txt==='立即领奖'||txt==='收下'||txt==='开心收下'||txt==='领机会'||txt==='领摸鱼次数'||txt==='领能量'||txt==='领取能量'||txt==='领摸鱼能量'||txt==='点击领能量'||txt.includes('领取')||txt.includes('领奖')){"
     "        const target=el.closest('button,[role=button],div[class*=btn],div[class*=button]')||el;"
     "        if(!clickedSet.has(target)){"
     "          clickedSet.add(target);"
     "          triggerClick(target);"
     "          triggerClick(el);"
     "          claimCnt++;"
     "        }"
     "      }"
     "    }"
     "  }"
     "  if(claimCnt>0)console.log('[AntForestPort] Auto-claimed '+claimCnt+' aifish reward buttons');"
     "}"
     "scanAndClick();"
     "if(!window.__afAIFishRewardObserverInstalled){"
     "  window.__afAIFishRewardObserverInstalled=true;"
     "  const obs=new MutationObserver(()=>{scanAndClick();});"
     "  obs.observe(document.body||document.documentElement,{childList:true,subtree:true});"
     "  setTimeout(()=>{try{obs.disconnect();window.__afAIFishRewardObserverInstalled=false;}catch(e){}},30000);"
     "}"
     "}catch(e){console.error('[AntForestPort] claimAllVisibleAIFishRewards error: ',e);}})();"];
}

- (void)executeRewardTaskScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        id bridge = (self.rewardTaskBridge && self.rewardTaskBridge != self.jsBridge) ? self.rewardTaskBridge : nil;
        if (bridge) {
            if ([bridge respondsToSelector:@selector(contentView)]) {
                id cv = [bridge contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([bridge respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(bridge, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if (([us containsString:@"180020010001247580"] || [us containsString:@"vitality"]) && ![us containsString:@"home.html"] && ![us containsString:@"60000002"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, nil);
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)claimAllVisibleRewardTaskRewardsOnWebView {
    [self executeRewardTaskScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(curUrl.includes('home.html')||curUrl.includes('60000002'))return;"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "function scanAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  let claimCnt=0;"
     "  const clickedSet=new Set();"
     "  const validWords=['领取','点击领取','立即领取','领奖','点击领奖','立即领奖','收下','开心收下','领能量','领取能量','领摸鱼能量','领步数'];"
     "  for(const el of all){"
     "    if(el.children.length===0&&el.innerText){"
     "      const txt=el.innerText.trim().replace(/\\s+/g,'');"
     "      if(validWords.indexOf(txt)!==-1){"
     "        const target=el.closest('button,[role=button],div[class*=btn],div[class*=button]')||el;"
     "        const targetTxt=(target.innerText||'').trim().replace(/\\s+/g,'');"
     "        if(targetTxt.startsWith('去')||targetTxt.includes('前往')||targetTxt.includes('逛')||targetTxt.includes('看')||targetTxt.includes('玩')||targetTxt.includes('农场')||targetTxt.includes('市集')||targetTxt.includes('保护地')||targetTxt.includes('庄园')||targetTxt.includes('肥料'))continue;"
     "        if(!clickedSet.has(target)){"
     "          clickedSet.add(target);"
     "          triggerClick(target);"
     "          triggerClick(el);"
     "          claimCnt++;"
     "        }"
     "      }"
     "    }"
     "  }"
     "  if(claimCnt>0)console.log('[AntForestPort] Auto-claimed '+claimCnt+' reward buttons');"
     "}"
     "scanAndClick();"
     "if(!window.__afRewardTaskObserverInstalled){"
     "  window.__afRewardTaskObserverInstalled=true;"
     "  let debounceTimer=null;"
     "  const obs=new MutationObserver(()=>{if(debounceTimer)clearTimeout(debounceTimer);debounceTimer=setTimeout(()=>{scanAndClick();},300);});"
     "  obs.observe(document.body||document.documentElement,{childList:true,subtree:true});"
     "  setTimeout(()=>{try{obs.disconnect();if(debounceTimer)clearTimeout(debounceTimer);window.__afRewardTaskObserverInstalled=false;}catch(e){}},30000);"
     "}"
     "}catch(e){console.error('[AntForestPort] claimAllVisibleRewardTaskRewards error: ',e);}})();"];
}

- (void)collectFarmChickenManure {
    static NSTimeInterval lastChickenCollectTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastChickenCollectTime < 10) return;
    lastChickenCollectTime = now;
    
    [self recordStage:@"芭芭农场：正在领取庄园小鸡生产的肥料..."];
    PSDJsBridge *bridge = (self.farmBridge && self.farmBridge != self.jsBridge) ? self.farmBridge : nil;
    if (bridge) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = [self effectiveUrlForBridge:bridge] ?: [self effectiveUrlForSceneCode:@"BABA_FARM"];
        
        NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.orchard.manure.collect\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"source\":\"alipayfarm\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
        manorSendRPC(bridge, arg1, url);
    }
    
    [self executeFarmScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(curUrl.includes('66666674')||curUrl.includes('antfarm')||curUrl.includes('manor')||curUrl.includes('2017090512380701'))return;"
     "if(!curUrl.includes('babafarm')&&!curUrl.includes('alipayfarm')&&!curUrl.includes('tmfarm')&&!curUrl.includes('orchard')&&!curUrl.includes('180020010001263018')&&!curUrl.includes('68687599'))return;"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  if(el.children.length===0&&el.innerText&&el.innerText.trim()==='领取'){"
     "    const p=el.closest('div[class*=\"task\"],div[class*=\"item\"],div')||el.parentElement;"
     "    if(p&&(p.innerText.includes('小鸡')||p.innerText.includes('生产中')||p.innerText.includes('肥'))&&!p.innerText.includes('森林')){"
     "      el.click();console.log('[AntForestPort] Clicked chicken manure receive button');break;"
     "    }"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
}

- (void)signFarmDailyWithKey:(NSString *)signKey {
    static NSString *lastSignKey = nil;
    if ([lastSignKey isEqualToString:signKey]) return;
    lastSignKey = [signKey copy];
    
    [self recordStage:[NSString stringWithFormat:@"芭芭农场：正在执行每日连续签到（%@）...", signKey ?: @"今日"]];
    [self executeFarmScriptOnWebView:@"(()=>{try{"
     "const curUrl=(window.location.href||'').toLowerCase();"
     "if(curUrl.includes('66666674')||curUrl.includes('antfarm')||curUrl.includes('manor')||curUrl.includes('2017090512380701'))return;"
     "if(!curUrl.includes('babafarm')&&!curUrl.includes('alipayfarm')&&!curUrl.includes('tmfarm')&&!curUrl.includes('orchard')&&!curUrl.includes('180020010001263018')&&!curUrl.includes('68687599'))return;"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  if(el.children.length===0&&el.innerText&&(el.innerText.trim()==='签到'||el.innerText.trim()==='点击签到'||el.innerText.trim()==='去签到'||el.innerText.trim()==='我知道了')){"
     "    el.click();console.log('[AntForestPort] Clicked farm sign button');break;"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
}

#pragma mark - 蚂蚁庄园全自动模块

- (void)executeManorScriptOnWebView:(NSString *)js {
    if (!js.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet *targets = [NSMutableSet set];
        SEL evalSel = @selector(evaluateJavaScript:completionHandler:);
        
        // 1. 如果有绑定的 manorBridge，提取其 webView
        id mb = self.manorBridge;
        if (mb && mb != self.jsBridge) {
            if ([mb respondsToSelector:@selector(contentView)]) {
                id cv = [mb contentView];
                if (cv && [cv respondsToSelector:evalSel]) [targets addObject:cv];
                if ([cv respondsToSelector:@selector(webView)]) {
                    id wv = ((id (*)(id, SEL))objc_msgSend)(cv, @selector(webView));
                    if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
                }
            }
            if ([mb respondsToSelector:@selector(webView)]) {
                id wv = ((id (*)(id, SEL))objc_msgSend)(mb, @selector(webView));
                if (wv && [wv respondsToSelector:evalSel]) [targets addObject:wv];
            }
        }
        
        // 2. 如果 targets 为空，扫描当前显示中的庄园 WKWebView
        if (targets.count == 0) {
            NSArray *windows = [UIApplication sharedApplication].windows;
            for (UIWindow *win in windows) {
                if (!win) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                while (stack.count > 0) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if ([v respondsToSelector:evalSel]) {
                        if (!v.hidden && v.alpha > 0.01) {
                            if ([v respondsToSelector:@selector(URL)]) {
                                NSURL *u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
                                if (u) {
                                    NSString *us = u.absoluteString.lowercaseString;
                                    if ([us containsString:@"60000002"] || [us containsString:@"180020010001247580"] || [us containsString:@"home.html"]) {
                                        continue;
                                    }
                                    if ([us containsString:@"66666674"] || [us containsString:@"2017090512380701"] || [us containsString:@"antfarm"] || [us containsString:@"manor"]) {
                                        [targets addObject:v];
                                    }
                                }
                            }
                        }
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            }
        }
        
        for (id target in targets) {
            if ([target respondsToSelector:evalSel]) {
                @try {
                    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))objc_msgSend)(target, evalSel, js, ^(__unused id res, __unused NSError *err) {
                    });
                } @catch (NSException *e) {}
            }
        }
    });
}

- (void)signManorDaily {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    NSString *lastSignDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorSignDate"];
    if ([lastSignDate isEqualToString:today]) {
        return;
    }
    
    [self recordStage:@"蚂蚁庄园：检测到今日未签到，正在自动签到领 180g 饲料..."];
    
    PSDJsBridge *bridge = [self activeManorBridge];
    if (bridge) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = [self manorRPCUrlString];
        
        // 真实标准庄园签到底层 RPC: com.alipay.antfarm.sign
        NSString *signArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.sign\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
        manorSendRPC(bridge, signArg, url);
    }
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){"
     "  if(!el)return false;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    if(r.width===0&&r.height===0)return false;"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "    return true;"
     "  }catch(e){try{el.click();return true;}catch(e2){return false;}}"
     "}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  if(el.tagName==='A' || (el.closest && el.closest('a[href]'))) continue;"
     "  const t=(el.innerText||el.textContent||'').trim();"
     "  if(t==='签到'||t==='点击签到'||t==='今日签到'||t==='签到领饲料'||t.includes('签到领饲料')){"
     "    triggerClick(el.closest('button,[role=\"button\"],[class*=\"btn\"]')||el);"
     "    break;"
     "  }"
     "}"
     "setTimeout(()=>{"
     "  const close=Array.from(document.querySelectorAll('button,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "    .find(c=>{"
     "      if(c.tagName==='A' || (c.closest && c.closest('a[href]'))) return false;"
     "      const ct=(c.innerText||'').trim();"
     "      return ct==='开心收下'||ct==='我知道了'||ct==='收下饲料'||ct==='好的';"
     "    });"
     "  if(close)triggerClick(close);"
     "},600);"
     "}catch(e){console.error(e);}})();"];
}

- (void)executeClassroomAnswerScript {
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "const QA_DB=["
     "{k:'退避三舍',a:'九十里'},{k:'烂醉如泥',a:'一种虫子'},{k:'宣笔',a:'宣州'},{k:'秋冻',a:'并不是'},"
     "{k:'企鹅有翅膀',a:'有'},{k:'奶皮',a:'脂肪和蛋白质'},{k:'猫咪胡子',a:'感知'},{k:'美轮美奂',a:'高大华美'},"
     "{k:'弱冠',a:'20岁'},{k:'执子之手',a:'战友情'},{k:'忘忧草',a:'萱草'},{k:'目无全牛',a:'技艺'},"
     "{k:'小鸡也是有耳朵',a:'当然有'},{k:'促织',a:'蟋蟀'},{k:'东道主',a:'方向'},{k:'单腿站立',a:'减少热量'},"
     "{k:'海中霸王',a:'虎鲸'},{k:'司空见惯',a:'官职'},{k:'生辰八字',a:'八个字'},{k:'初出茅庐',a:'草房'},"
     "{k:'立夏',a:'夏季'},{k:'兰亭序',a:'王羲之'},{k:'向日葵成熟后头',a:'花盘太重'},{k:'蹴鞠',a:'足球'},"
     "{k:'小鸡的羽毛能防水',a:'不能'},{k:'纨绔子弟',a:'细绢'},{k:'电热毯',a:'睡前关闭'},{k:'五花八门',a:'兵法'},"
     "{k:'海中牛奶',a:'牡蛎'},{k:'七月流火',a:'恒星'},{k:'六艺',a:'驾驭'},{k:'海星有眼睛',a:'有'},"
     "{k:'逆风',a:'增加升力'},{k:'炙手可热',a:'权势'},{k:'三秋',a:'三个季度'},{k:'三宝殿',a:'佛教'},"
     "{k:'吃小石子',a:'帮助消化'},{k:'花中君子',a:'竹'},{k:'千金小姐',a:'男'},{k:'打哈欠',a:'真会'},"
     "{k:'冰皮月饼',a:'不用烘烤'},{k:'落汤鸡',a:'尾脂腺'},{k:'信手拈来',a:'随手'},{k:'骨骼数量',a:'会'},"
     "{k:'弄璋',a:'男孩'},{k:'弄瓦',a:'女孩'},{k:'汗流浃背',a:'大臣'},{k:'梁上君子',a:'窃贼'},"
     "{k:'银子',a:'并不是'},{k:'蜗牛',a:'黏液'},{k:'吃太咸',a:'多喝水'},{k:'昙花一现',a:'晚上'},"
     "{k:'兔子眼睛',a:'血液'},{k:'藕断丝连',a:'导管'},{k:'金榜题名',a:'进士'},{k:'阳春白雪',a:'高雅'},"
     "{k:'下里巴人',a:'民间'},{k:'桃李满天下',a:'学生'},{k:'白发三千丈',a:'夸张'},{k:'红娘',a:'西厢记'},"
     "{k:'豆蔻年华',a:'13'},{k:'及笄',a:'15'},{k:'而立',a:'30'},{k:'不惑',a:'40'},"
     "{k:'知天命',a:'50'},{k:'耳顺',a:'60'},{k:'古稀',a:'70'},{k:'期颐',a:'100'},"
     "{k:'大腹便便',a:'肚子'},{k:'金针菇',a:'真菌'},{k:'皮蛋',a:'鸭蛋'},{k:'松花蛋',a:'鸭蛋'},"
     "{k:'哈密瓜',a:'新疆'},{k:'吐鲁番',a:'葡萄'},{k:'文房四宝',a:'笔墨纸砚'},{k:'岁寒三友',a:'松竹梅'},"
     "{k:'出水芙蓉',a:'荷花'},{k:'国色天香',a:'牡丹'},{k:'破釜沉舟',a:'巨鹿'},{k:'草船借箭',a:'赤壁'},"
     "{k:'负荆请罪',a:'廉颇'},{k:'完璧归赵',a:'蔺相如'},{k:'望梅止渴',a:'曹操'},{k:'三顾茅庐',a:'刘备'},"
     "{k:'指鹿为马',a:'赵高'},{k:'四面楚歌',a:'项羽'},{k:'背水一战',a:'韩信'},{k:'煮豆燃萁',a:'曹植'},"
     "{k:'入木三分',a:'王羲之'},{k:'闻鸡起舞',a:'祖逖'},{k:'程门立雪',a:'杨时'},{k:'东施效颦',a:'西施'},"
     "{k:'守株待兔',a:'侥幸'},{k:'掩耳盗铃',a:'自欺欺人'},{k:'拔苗助长',a:'急于求成'},{k:'刻舟求剑',a:'拘泥'},"
     "{k:'滥竽充数',a:'南郭先生'},{k:'买椟还珠',a:'取舍不当'},{k:'杯弓蛇影',a:'疑神疑鬼'},{k:'狐假虎威',a:'借别人威势'}"
     "];"
     "function triggerClick(el){"
     "  if(!el)return;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "  }catch(e){try{el.click();}catch(e2){}}"
     "}"
     "const rewardBtns=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "  .filter(el=>{"
     "    const t=(el.innerText||el.textContent||'').trim();"
     "    return t==='去领取'||t==='开心收下'||t==='领取饲料'||t==='收下饲料'||t==='我知道了'||t==='去拿饲料';"
     "  });"
     "if(rewardBtns.length>0){"
     "  triggerClick(rewardBtns[0]);"
     "  console.log('[AntForestPort] Manor Classroom reward claimed');"
     "  return;"
     "}"
     "let qText='';"
     "let qEl=null;"
     "const allElements=Array.from(document.querySelectorAll('*'));"
     "for(const el of allElements){"
     "  if(el.children.length===0){"
     "    const t=(el.innerText||el.textContent||'').trim();"
     "    if((t.includes('？')||t.includes('?')||t.includes('猜一猜')||t.includes('下列')||t.includes('考考你')||t.includes('通常情况下')||t.includes('成语'))&&t.length>=6&&t.length<=120){"
     "      qText=t;qEl=el;break;"
     "    }"
     "  }"
     "}"
     "if(qText){"
     "  const parentContainer=qEl.closest('[class*=\"content\"],[class*=\"modal\"],[class*=\"dialog\"],[class*=\"card\"],div')||qEl.parentElement?.parentElement||document.body;"
     "  const candidateOptions=Array.from(parentContainer.querySelectorAll('button,[role=\"button\"],[class*=\"option\"],[class*=\"answer\"],[class*=\"btn\"],div'))"
     "    .filter(el=>{"
     "      if(el.children.length>2)return false;"
     "      const t=(el.innerText||el.textContent||'').trim();"
     "      if(t===qText||t.length===0||t.length>35)return false;"
     "      if(t.includes('小课堂')||t.includes('饲料')||t.includes('知道了')||t.includes('关闭')||t.includes('规则'))return false;"
     "      const rect=el.getBoundingClientRect();"
     "      return rect.width>40&&rect.height>18&&rect.height<140;"
     "    });"
     "  const uniqueOptions=[];"
     "  const seenTexts=new Set();"
     "  for(const opt of candidateOptions){"
     "    const t=(opt.innerText||opt.textContent||'').trim();"
     "    if(!seenTexts.has(t)&&t.length>=1){"
     "      seenTexts.add(t);uniqueOptions.push({el:opt,text:t});"
     "    }"
     "  }"
     "  if(uniqueOptions.length>=2&&uniqueOptions.length<=4){"
     "    let bestMatch=null;"
     "    for(const item of QA_DB){"
     "      if(qText.includes(item.k)){bestMatch=item;break;}"
     "    }"
     "    let selectedOption=null;"
     "    if(bestMatch){"
     "      for(const opt of uniqueOptions){"
     "        if(opt.text.includes(bestMatch.a)||bestMatch.a.includes(opt.text)){"
     "          selectedOption=opt;break;"
     "        }"
     "      }"
     "    }"
     "    if(!selectedOption){"
     "      selectedOption=uniqueOptions.find(o=>o.text.includes('正确')||o.text.includes('是的')||o.text.includes('可以')||o.text.includes('有'))||uniqueOptions[0];"
     "    }"
     "    if(selectedOption){"
     "      triggerClick(selectedOption.el);"
     "      console.log('[AntForestPort] Selected Manor option: '+selectedOption.text);"
     "      setTimeout(()=>{"
     "        const claim=Array.from(document.querySelectorAll('button,a,[role=\"button\"],[class*=\"btn\"],div,span'))"
     "          .find(el=>{"
     "            const t=(el.innerText||el.textContent||'').trim();"
     "            return t==='去领取'||t==='开心收下'||t==='领取饲料'||t==='收下饲料'||t==='我知道了';"
     "          });"
     "        if(claim)triggerClick(claim);"
     "      },800);"
     "    }"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
    
    NSString *today = getCurrentDateString();
    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorAnswerDate"];
    [self recordStage:@"蚂蚁庄园：庄园小课堂答题已提交（稳拿 180g 饲料）"];
}

- (void)answerManorClassroomQuestion {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    NSString *lastAnswerDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorAnswerDate"];
    if ([lastAnswerDate isEqualToString:today]) {
        return;
    }
    
    [self recordStage:@"蚂蚁庄园：正在进入庄园小课堂自动答题（稳拿180g饲料）..."];
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  const t=(el.innerText||el.getAttribute('aria-label')||'').trim();"
     "  if((t==='庄园小课堂'||t==='小课堂'||t.includes('庄园小课堂'))&&el.children.length<=1){"
     "    triggerClick(el.closest('button,a,[role=\"button\"],[class*=\"btn\"]')||el);"
     "    break;"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self executeClassroomAnswerScript];
    });
}

- (void)executeManorTaskProcessScript {
    // 纯静默弹窗关闭兜底：仅关闭全局奖励弹窗（如“开心收下”、“我知道了”、“确认”），严禁触碰任务列表或任何跳转链接
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const modals=Array.from(document.querySelectorAll('[role=\"dialog\"],.ant-modal,[class*=\"modal\"],[class*=\"popup\"],[class*=\"dialog\"],[class*=\"pop-window\"]'));"
     "for(const m of modals){"
     "  const btns=Array.from(m.querySelectorAll('button,[role=\"button\"],[class*=\"btn\"],div,span'));"
     "  for(const b of btns){"
     "    if(b.tagName==='A'||(b.closest&&b.closest('a[href]'))) continue;"
     "    const t=(b.innerText||b.textContent||'').trim();"
     "    if(t==='开心收下'||t==='我知道了'||t==='好的'||t==='确认'||t==='确定'||t==='收下'||t==='明白'){"
     "      triggerClick(b);break;"
     "    }"
     "  }"
     "}"
     "}catch(e){console.error(e);}})();"];
}

- (void)openManorTaskPanelOnWebView {
    if (!self.enableAutoManor) return;
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){"
     "  if(!el)return false;"
     "  try{"
     "    const r=el.getBoundingClientRect();"
     "    if(r.width===0&&r.height===0)return false;"
     "    const x=r.left+r.width/2,y=r.top+r.height/2;"
     "    const opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y};"
     "    try{el.dispatchEvent(new PointerEvent('pointerdown',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mousedown',opts));}catch(e){}"
     "    try{"
     "      const t=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new PointerEvent('pointerup',opts));}catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('mouseup',opts));}catch(e){}"
     "    try{"
     "      const te=new Touch({identifier:Date.now(),target:el,clientX:x,clientY:y});"
     "      el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[te]}));"
     "    }catch(e){}"
     "    try{el.dispatchEvent(new MouseEvent('click',opts));}catch(e){}"
     "    try{el.click();}catch(e){}"
     "    return true;"
     "  }catch(e){try{el.click();return true;}catch(e2){return false;}}"
     "}"
     "function findAndClick(){"
     "  const all=Array.from(document.querySelectorAll('*'));"
     "  for(const el of all){"
     "    const txt=(el.innerText||el.textContent||el.getAttribute('aria-label')||'').trim().replace(/\\s+/g,'');"
     "    if(txt==='领饲料'||txt==='赚饲料'||txt==='做任务领饲料'||txt==='集饲料'||txt==='领饲料任务'){"
     "      const target=el.closest('button,[role=button],div[class*=btn],div[class*=button],div[class*=feed]')||el;"
     "      if(triggerClick(target)){"
     "        console.log('[AntForestPort] Clicked manor task panel button:',txt);"
     "        return true;"
     "      }"
     "    }"
     "  }"
     "  return false;"
     "}"
     "findAndClick();"
     "}catch(e){}})();"];
}

- (void)closeManorTaskPanelOnWebView {
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const mask=document.querySelector('.ant-drawer-mask,[class*=\"mask\"],[class*=\"overlay\"]');"
     "if(mask){triggerClick(mask);}"
     "const pt=document.elementFromPoint(window.innerWidth*0.5,window.innerHeight*0.12);"
     "if(pt&&pt!==document.body&&pt!==document.documentElement){triggerClick(pt);}"
     "const closeBtns=Array.from(document.querySelectorAll('.ant-drawer-close,[aria-label*=\"关闭\"],[class*=\"close\"],button'));"
     "for(const b of closeBtns){"
     "  const cls=(b.className||'').toLowerCase();"
     "  const txt=(b.innerText||'').trim();"
     "  if(cls.includes('close')||txt==='×'||txt==='✕'||txt==='关闭'){"
     "    triggerClick(b);break;"
     "  }"
     "}"
     "try{window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',code:'Escape',keyCode:27,bubbles:true}));}catch(e){}"
     "}catch(e){}})();"];
}

- (void)queryManorTaskList {
    if (!self.enableAutoManor) return;
    // 庄园常规推广任务服务端不支持RPC直接调用，无需强行呼出抽屉面板打扰用户
}

- (void)finishManorTask:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title {
    if (!self.enableAutoManor || !taskType.length) return;
    [self doManorFarmTaskWithBizKey:taskType];
}

- (void)receiveManorTaskAward:(NSString *)taskType sceneCode:(NSString *)sceneCode taskTitle:(NSString *)title awardName:(NSString *)awardName {
    if (!self.enableAutoManor || !taskType.length) return;
    [self receiveManorFarmTaskAwardWithTaskId:taskType title:title];
}

- (void)queryManorFarmTasks {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *taskArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.listFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", timeStamp, randNum];
    manorSendRPC(bridge, taskArg, url);
}

- (void)doManorFarmTaskWithBizKey:(NSString *)bizKey {
    if (!self.enableAutoManor || !bizKey.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *doTaskArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.doFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"bizKey\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", bizKey, timeStamp, randNum];
    manorSendRPC(bridge, doTaskArg, url);
}

- (void)receiveManorFarmTaskAwardWithTaskId:(NSString *)taskId title:(NSString *)title {
    if (!self.enableAutoManor || !taskId.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *claimArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.receiveFarmTaskAward\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"taskId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskId, timeStamp, randNum];
    manorSendRPC(bridge, claimArg, url);
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：已提交领取“%@”（饲料奖励）...", title ?: taskId]];
}

- (void)handleManorTaskList:(NSArray *)taskList {
    if (!self.enableAutoManor || !taskList.count) return;
    
    static NSTimeInterval lastProcessTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastProcessTime < 4.0) return;
    lastProcessTime = now;
    
    initDailyTaskCache();
    
    NSInteger taskDelayIndex = 0;
    
    for (NSDictionary *task in taskList) {
        if (![task isKindOfClass:NSDictionary.class]) continue;
        NSString *bizKey = task[@"bizKey"] ?: @"";
        NSString *taskId = task[@"taskId"] ?: @"";
        NSString *status = task[@"taskStatus"] ?: @"";
        NSString *title = task[@"title"] ?: (bizKey.length ? bizKey : taskId);
        NSString *mode = task[@"taskMode"] ?: @"";
        NSInteger award = [task[@"awardCount"] integerValue] ?: ([task[@"canReceiveAwardCount"] integerValue] ?: 90);
        
        if ([status isEqualToString:@"RECEIVED"]) {
            if ([bizKey isEqualToString:@"ANSWER"]) {
                NSString *today = getCurrentDateString();
                [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorAnswerDate"];
            }
            continue;
        }
        
        if ([status isEqualToString:@"FINISHED"]) {
            if (taskId.length) {
                NSInteger stock = self.lastManorFoodStock;
                NSInteger limit = self.lastManorFoodStockLimit > 0 ? self.lastManorFoodStockLimit : 1800;
                if (stock >= limit && limit > 0) {
                    static NSTimeInterval lastFullLogTime = 0;
                    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                    if (now - lastFullLogTime > 60) {
                        lastFullLogTime = now;
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：饲料背包已满（%ldg/%ldg），暂不领取“%@”，待小鸡进食后再领", (long)stock, (long)limit, title]];
                    }
                    continue;
                }
                NSString *claimKey = [NSString stringWithFormat:@"ANTFARM_CLAIM_TASK:%@", taskId];
                if (![gDailyCompletedTasks containsObject:claimKey]) {
                    [gDailyCompletedTasks addObject:claimKey];
                    saveDailyTaskCache();
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：发现已完成任务“%@”，正在领取 %ldg 饲料...", title, (long)award]];
                    [self receiveManorFarmTaskAwardWithTaskId:taskId title:title];
                }
            }
            continue;
        }
        
        if ([status isEqualToString:@"TODO"]) {
            if ([bizKey isEqualToString:@"ANSWER"]) {
                NSString *today = getCurrentDateString();
                NSString *lastAnswerDate = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastManorAnswerDate"];
                if (![lastAnswerDate isEqualToString:today]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self answerManorClassroomQuestion];
                    });
                }
                continue;
            }
            
            // 过滤捐款、支付、理财等需真实出资的任务，严禁自动化盲目调用
            NSString *desc = task[@"desc"] ?: task[@"taskDesc"] ?: @"";
            NSString *cat = task[@"categorizationSecondLevel"] ?: @"";
            if ([cat isEqualToString:@"Public_Welfare_Behavior"] ||
                [bizKey containsString:@"DONATE"] || [bizKey containsString:@"DONATION"] ||
                [bizKey containsString:@"PAY"] || [bizKey containsString:@"PURCHASE"] ||
                [bizKey containsString:@"ZhangDanTZ"] || [title containsString:@"信用卡"] ||
                [bizKey isEqualToString:@"JINGTAN_FEED_FISH"] ||
                [desc containsString:@"捐"] || [desc containsString:@"付款"] || [desc containsString:@"支付"] || [desc containsString:@"实付"]) {
                continue;
            }
            
            // 过滤纯游戏玩局类任务 (Game / Game_Charge)
            if ([cat isEqualToString:@"Game"] || [cat isEqualToString:@"Game_Charge"]) {
                continue;
            }
            
            // 针对 VIEW 或 TRIGGER 模式的浏览、逛一逛、功能开启类常规任务进行自动触发
            if ([mode isEqualToString:@"VIEW"] || [mode isEqualToString:@"TRIGGER"]) {
                NSString *taskKey = [NSString stringWithFormat:@"ANTFARM_FOOD_TASK:%@", bizKey];
                if (![gDailyCompletedTasks containsObject:taskKey]) {
                    [gDailyCompletedTasks addObject:taskKey];
                    saveDailyTaskCache();
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：正在完成浏览任务“%@”...", title]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(taskDelayIndex * 350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self doManorFarmTaskWithBizKey:bizKey];
                    });
                    taskDelayIndex++;
                }
            }
        }
    }
    
    // 如果有触发的任务，延时后重新查询任务列表，以便自动检测到 FINISHED 并领取饲料入包
    if (taskDelayIndex > 0) {
        int64_t refreshDelay = (int64_t)((taskDelayIndex * 350 + 2500) * NSEC_PER_MSEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, refreshDelay), dispatch_get_main_queue(), ^{
            [self queryManorFarmTasks];
        });
    }
}

- (void)runManorTasks {
    if (!self.enableAutoManor) return;
    [self queryManorFarmTasks];
    [self executeManorTaskProcessScript];
}

@synthesize myUserId = _myUserId;

- (NSString *)myUserId {
    if (_myUserId.length) return _myUserId;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"];
    if (saved.length) {
        _myUserId = [saved copy];
        return _myUserId;
    }
    return nil;
}

- (void)setMyUserId:(NSString *)myUserId {
    if (![myUserId isKindOfClass:NSString.class] || !myUserId.length) return;
    _myUserId = [myUserId copy];
    [[NSUserDefaults standardUserDefaults] setObject:_myUserId forKey:@"lastKnownUserId"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@synthesize lastManorFarmId = _lastManorFarmId;

- (NSString *)lastManorFarmId {
    if (_lastManorFarmId.length) return _lastManorFarmId;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"antforest_lastManorFarmId"];
    if (saved.length) {
        _lastManorFarmId = [saved copy];
        return _lastManorFarmId;
    }
    return nil;
}

- (void)setLastManorFarmId:(NSString *)lastManorFarmId {
    _lastManorFarmId = [lastManorFarmId copy];
    if (_lastManorFarmId.length) {
        [[NSUserDefaults standardUserDefaults] setObject:_lastManorFarmId forKey:@"antforest_lastManorFarmId"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)enterManorFarm {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    
    NSString *uid = self.myUserId.length ? self.myUserId : ([[NSUserDefaults standardUserDefaults] stringForKey:@"lastKnownUserId"] ?: @"");
    NSString *farmId = self.lastManorFarmId ?: @"";
    if (!uid.length && farmId.length > 2) {
        uid = [farmId substringFromIndex:farmId.length / 2];
    }
    
    NSString *url = [self manorRPCUrlString];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    
    // 真实标准底层 RPC: com.alipay.antfarm.enterFarm
    NSString *enterArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.enterFarm\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"animalId\":\"\",\"cityAdCode\":\"000000\",\"districtAdCode\":\"000000\",\"farmId\":\"%@\",\"masterFarmId\":\"\",\"queryLastRecordNum\":true,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"touchRecordId\":\"\",\"userId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId, uid, timeStamp, randNum];
    manorSendRPC(bridge, enterArg, url);
}

#pragma mark - 高级饲料（菜谱）逐个投喂

// 服务端抓包口径（manor_rpc 33 实证）：com.alipay.antfarm.useFarmFood 为扁平结构，一次只喂 1 个
// （顶层 cookbookId/cuisineId/useCuisine，无 cuisineList）；库存 1~N 个都正确，喂不动（不足/已饱）即停转普通饲料
static NSString * const kManorCuisineSource  = @"chInfo_ch_appcenter__chsub_9patch";
static NSString * const kManorCuisineVersion = @"1.8.2302070202.46";

static NSArray *manorBuiltinCuisineList(void) {
    static NSArray *list = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @{@"cookbookId": @"231001qiurichiyinong",       @"cuisineId": @"231001jianluobogao"},
            @{@"cookbookId": @"260301chuchunshiyanshi",     @"cuisineId": @"260301taohuaoufengeng"},
            @{@"cookbookId": @"260301chuchunshiyanshi",     @"cuisineId": @"260301jicaituantuan"},
            @{@"cookbookId": @"240701shengxiashiqingliang", @"cuisineId": @"240701huluobojiangzaotang"},
            @{@"cookbookId": @"240501chuxiaqiangxianchang", @"cuisineId": @"240501basimiju"},
            @{@"cookbookId": @"240701shengxiashiqingliang", @"cuisineId": @"240701huameibale"},
            @{@"cookbookId": @"240701shengxiashiqingliang", @"cuisineId": @"240701xingrenqingjiangyimian"}
        ];
    });
    return list;
}

static NSString * const kManorLearnedCuisineKey = @"antforest_manor_cuisines_v1";
static NSMutableDictionary *gManorLearnedCuisines = nil;   // cuisineId -> cookbookId（庄园页面自己拉回来的真实菜谱）
static NSTimeInterval gManorCuisineLearnScanAt = 0;        // 扫描节流：庄园回包很密，2 秒内只扫一次

static void manorLoadLearnedCuisines(void) {
    if (gManorLearnedCuisines) return;
    gManorLearnedCuisines = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kManorLearnedCuisineKey];
    for (id key in saved) {
        if ([key isKindOfClass:NSString.class] && [saved[key] isKindOfClass:NSString.class]) {
            gManorLearnedCuisines[key] = saved[key];
        }
    }
}

// 只认「同一个字典里同时出现 cookbookId 和 cuisineId」的成对数据：单边出现的（列表、配置）不敢拼，
// 拼错菜谱书等于给服务端一个不存在的组合，比不喂更糟
static void manorScanCuisinePairs(id obj, NSMutableDictionary *out, NSUInteger *budget) {
    if (!obj || *budget == 0) return;
    (*budget)--;
    if ([obj isKindOfClass:NSDictionary.class]) {
        id cookbook = obj[@"cookbookId"] ?: obj[@"cookBookId"];
        id cuisine = obj[@"cuisineId"];
        if ([cookbook isKindOfClass:NSString.class] && [cuisine isKindOfClass:NSString.class] &&
            [cookbook length] > 3 && [cuisine length] > 3) {
            out[cuisine] = cookbook;
        }
        for (id value in [obj allValues]) manorScanCuisinePairs(value, out, budget);
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in obj) manorScanCuisinePairs(value, out, budget);
    }
}

// 高级饲料库存（9/11 用户口径）：菜谱持有数就在回包的菜谱条目里（页面批量投喂口径 {cookbookId,cuisineId,count:1}），
// 只喂「识别到持有数 >0」的菜谱（有就投喂、没有就跳过）；查库存照 H5 自己的口径 syncAnimalStatus + QUERY_CUISINE_LIST
static NSString * const kManorCuisineStockKey = @"antforest_manor_cuisine_stock_v1";
static NSString * const kManorCuisineEmptyKey = @"antforest_manor_cuisine_empty_v1";
static NSMutableDictionary *gManorCuisineStock = nil;   // cuisineId -> NSNumber 持有数（回包实时识别）
static NSMutableSet *gManorCuisineEmptyIds = nil;       // 服务端确认没库存的菜谱（当天不再试）
static NSString *gManorCuisineEmptyDate = nil;          // 上面那份名单属于哪一天，跨天自动作废
static NSTimeInterval gManorCuisineStockScanAt = 0;     // 库存扫描节流：0.5 秒内只扫一次
static NSTimeInterval gManorCuisineStockAt = 0;         // 上次识别到库存的时间（判断新鲜度）
static NSTimeInterval gManorCuisineStockQueryAt = 0;    // 主动查库存节流：10 分钟最多一次

static void manorLoadCuisineStock(void) {
    if (gManorCuisineStock) return;
    gManorCuisineStock = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kManorCuisineStockKey];
    for (id key in saved) {
        if (![key isKindOfClass:NSString.class]) continue;
        NSInteger count = [saved[key] respondsToSelector:@selector(integerValue)] ? [saved[key] integerValue] : 0;
        if (count > 0) gManorCuisineStock[key] = @(count);
    }
}

static void manorSaveCuisineStock(void) {
    [NSUserDefaults.standardUserDefaults setObject:(gManorCuisineStock ?: @{}) forKey:kManorCuisineStockKey];
}

static void manorLoadCuisineEmptyIds(void) {
    if (gManorCuisineEmptyIds) return;
    gManorCuisineEmptyIds = [NSMutableSet set];
    gManorCuisineEmptyDate = getCurrentDateString();
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kManorCuisineEmptyKey];
    if ([saved[@"date"] isKindOfClass:NSString.class] && [saved[@"date"] isEqualToString:gManorCuisineEmptyDate]) {
        id ids = saved[@"ids"];
        if ([ids isKindOfClass:NSArray.class]) {
            for (id item in ids) {
                if ([item isKindOfClass:NSString.class]) [gManorCuisineEmptyIds addObject:item];
            }
        }
    }
}

static void manorSaveCuisineEmptyIds(void) {
    if (!gManorCuisineEmptyIds) return;
    [NSUserDefaults.standardUserDefaults setObject:@{@"date": (gManorCuisineEmptyDate ?: getCurrentDateString()),
                                                     @"ids": (gManorCuisineEmptyIds.allObjects ?: @[])}
                                            forKey:kManorCuisineEmptyKey];
}

// 持有数字段：count 是页面批量投喂口径里的持有数，其余为同类字段兜底
static NSInteger manorCuisineCountIn(NSDictionary *dict) {
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"count", @"num", @"numCount", @"cuisineCount", @"foodCount", @"quantity", @"amount",
                 @"leftCount", @"remainNum", @"numLeft", @"stock", @"usableNum"];
    });
    for (NSString *key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:NSNumber.class]) return [value integerValue];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return [(NSString *)value integerValue];
    }
    return 0;
}

// 库存识别：只认「同一个字典里同时有 cuisineId + 数字型持有数字段」的条目，且只记正数；
// 没有数字字段的条目（图鉴/配置）不猜，读到 0 也不当成持有
static void manorScanCuisineStock(id obj, NSMutableDictionary *out, NSUInteger *budget) {
    if (!obj || *budget == 0) return;
    (*budget)--;
    if ([obj isKindOfClass:NSDictionary.class]) {
        id cuisine = obj[@"cuisineId"];
        if ([cuisine isKindOfClass:NSString.class] && [cuisine length] > 3) {
            NSInteger count = manorCuisineCountIn(obj);
            NSInteger old = [out[cuisine] respondsToSelector:@selector(integerValue)] ? [out[cuisine] integerValue] : 0;
            if (count > 0 && count > old) out[cuisine] = @(count);
        }
        for (id value in [obj allValues]) manorScanCuisineStock(value, out, budget);
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in obj) manorScanCuisineStock(value, out, budget);
    }
}

// 库存新鲜度：10 分钟内的识别结果算新鲜，过期就先查一次再喂
static BOOL manorCuisineStockStale(NSTimeInterval now) {
    if (gManorCuisineStockAt <= 0) return YES;
    return ((now - gManorCuisineStockAt) > 600.0);
}

// 有库存就喂：识别到持有数 >0 的菜谱按持有数降序排前面（识别到的种类是全量口径，喂的只看库存）
static NSArray *manorOwnedCuisineList(void) {
    manorLoadLearnedCuisines();
    manorLoadCuisineStock();
    NSMutableArray *owned = [NSMutableArray array];
    for (NSString *cuisineId in gManorCuisineStock) {
        NSInteger count = [gManorCuisineStock[cuisineId] integerValue];
        NSString *cookbookId = gManorLearnedCuisines[cuisineId];
        if (count > 0 && cookbookId.length > 3) {
            [owned addObject:@{@"cuisineId": cuisineId, @"cookbookId": cookbookId, @"count": @(count)}];
        }
    }
    [owned sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ca = [a[@"count"] integerValue];
        NSInteger cb = [b[@"count"] integerValue];
        if (ca != cb) return (ca > cb) ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"cuisineId"] compare:b[@"cuisineId"]];
    }];
    return owned;
}

// 识别优先、写死兜底：识别到持有库存就只喂持有库存（有就投喂、没有就跳过）；
// 没识别到库存数据才退回已识别菜谱全量，识别不到菜谱才用写死的 7 组
static NSArray *manorAdvancedCuisineList(void) {
    NSArray *owned = manorOwnedCuisineList();
    if (owned.count > 0) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *cuisine in owned) {
            [out addObject:cuisine];
            if (out.count >= 40) break;
        }
        return out;
    }
    manorLoadLearnedCuisines();
    if (gManorLearnedCuisines.count > 0) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *cuisineId in [gManorLearnedCuisines.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [out addObject:@{@"cuisineId": cuisineId, @"cookbookId": gManorLearnedCuisines[cuisineId]}];
            if (out.count >= 40) break;
        }
        return out;
    }
    return manorBuiltinCuisineList();
}

static BOOL isManorCuisineSkipMemo(NSString *memo) {
    if (!memo.length) return NO;
    return ([memo containsString:@"还没吃完"] || [memo containsString:@"不要着急"] ||
            [memo containsString:@"已满"] || [memo containsString:@"睡觉"] || [memo containsString:@"外出"] ||
            [memo containsString:@"not finish"] || [memo containsString:@"eating"] ||
            [memo containsString:@"full"] || [memo containsString:@"sleep"]);
}

// 睡觉类 memo：服务端说小鸡在睡觉，此时高级饲料与普通饲料都投不进去（9/11 真机实证）
static BOOL isManorSleepMemo(NSString *memo) {
    if (!memo.length) return NO;
    return ([memo containsString:@"睡觉"] || [memo containsString:@"休息"] || [memo containsString:@"无法操作"] ||
            [memo containsString:@"sleep"] || [memo containsString:@"Sleep"]);
}

// 「高级饲料持有不足」：服务端说这个菜谱没库存（不是小鸡状态问题），换下一个菜谱继续试
static BOOL isManorCuisineEmptyMemo(NSString *memo) {
    if (!memo.length) return NO;
    return ([memo containsString:@"不足"] || [memo containsString:@"not enough"] ||
            [memo containsString:@"insufficient"] || [memo containsString:@"notEnough"] ||
            [memo containsString:@"no enough"]);
}

// 回包英文 memo 中文化（日志全中文口径，照 AntManor cnReason）
static NSString *manorCnReason(NSString *reason) {
    if (!reason.length) return reason;
    static NSDictionary *map = nil;
    if (!map) {
        map = @{ @"SUCCESS": @"成功", @"success": @"成功",
                 @"not finish": @"还没吃完", @"not finished": @"还没吃完", @"eating": @"小鸡正在进食",
                 @"has food": @"食物槽还有食物", @"full": @"饲料已满",
                 @"sleeping": @"小鸡在睡觉", @"sleep": @"小鸡在睡觉",
                 @"already": @"已领取过", @"claimed": @"已领取过", @"repeat": @"重复领取",
                 @"not enough": @"饲料不足", @"insufficient": @"饲料不足" };
    }
    NSString *text = reason;
    for (NSString *key in map) {
        if ([text rangeOfString:key].location != NSNotFound) {
            text = [text stringByReplacingOccurrencesOfString:key withString:map[key]];
        }
    }
    return text;
}

static NSUInteger gManorCuisineFedCount = 0;       // 本轮已投喂个数（单轮上限 15 个，防死循环）
static BOOL gManorCuisineInFlight = NO;            // 有请求在飞：等回包再喂下一个，防止同轮重复发送
static BOOL gManorCuisineRunning = NO;             // 本轮高级饲料投喂是否进行中
static NSTimeInterval gManorCuisineStopUntil = 0;  // 喂不动/喂完后的冷却（30 分钟），避免每轮回包都重试
static NSMutableSet *gManorCuisineBadIds = nil;    // 本轮被服务端明确拒掉的菜谱，不再重复撞
static NSString *gManorCuisineInFlightId = nil;    // 在飞的菜谱 ID：回包失败时用它拉黑
static NSUInteger gManorCuisineCursor = 0;         // 轮转游标：跳过被拒的菜谱继续下一个
static NSTimeInterval gManorChickenSleepUntil = 0;  // 小鸡在睡觉：这段时间内不投喂（高级/普通饲料服务端都拒）
static const NSTimeInterval kManorChickenSleepQuiet = 300.0;  // 睡觉静默 5 分钟，醒了由 60 秒监控自动接上

// 本轮结算口径（9/11 用户反馈「日志说全部投喂完、剩余 0，实际还有 1 个没喂进去」）
static NSUInteger gManorCuisineRoundOwned = 0;      // 本轮开始时「识别到持有」种类数
static NSUInteger gManorCuisineRoundCandidate = 0;  // 本轮候选种类数
static NSUInteger gManorCuisineRoundFail = 0;       // 本轮失败个数（4 秒无回执 / 被服务端拒）
static NSUInteger gManorCuisineRoundSkip = 0;       // 本轮被服务端判「无库存」个数
static NSString *gManorCuisineRoundFailNote = nil;  // 本轮未投喂明细（菜谱 ID + 原因）

// 睡觉静默期内？投喂入口先查这里，避免明知服务端会拒还发请求
static BOOL manorChickenSleeping(void) {
    return (gManorChickenSleepUntil > 0 && [[NSDate date] timeIntervalSince1970] < gManorChickenSleepUntil);
}

static NSString *manorFindOperationType(id obj, NSUInteger *budget) {
    if (!obj || *budget == 0) return nil;
    (*budget)--;
    if ([obj isKindOfClass:NSDictionary.class]) {
        id op = obj[@"operationType"];
        if ([op isKindOfClass:NSString.class] && [op length]) return op;
        for (id value in [obj allValues]) {
            NSString *found = manorFindOperationType(value, budget);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in obj) {
            NSString *found = manorFindOperationType(value, budget);
            if (found) return found;
        }
    }
    return nil;
}

static NSString *manorOperationDisplayName(NSString *op) {
    if (!op.length) return @"未知操作";
    if ([op containsString:@"useFarmFood"]) return @"高级饲料投喂";
    if ([op containsString:@"feedAnimal"]) return @"普通饲料投喂";
    if ([op containsString:@"harvestProduce"]) return @"收鸡蛋";
    if ([op containsString:@"syncAnimalStatus"]) return @"同步小鸡状态";
    if ([op containsString:@"enterFamily"]) return @"进入家庭";
    if ([op containsString:@"sleep"]) return @"小鸡睡觉";
    if ([op containsString:@"sign"]) return @"家庭签到";
    if ([op containsString:@"receiveFarmTaskAward"]) return @"领取饲料奖励";
    return @"庄园操作";
}

// 轮转取下一个还没被拒的菜谱；被拒过/今天已判无库存的都跳过，返回 nil 就不喂高级饲料了
static NSDictionary *manorNextCuisineToFeed(NSArray *list) {
    if (!gManorCuisineBadIds) gManorCuisineBadIds = [NSMutableSet set];
    manorLoadCuisineEmptyIds();
    if (!list.count) return nil;
    for (NSUInteger i = 0; i < list.count; i++) {
        NSDictionary *item = list[(gManorCuisineCursor + i) % list.count];
        NSString *cuisineId = item[@"cuisineId"];
        if ([gManorCuisineBadIds containsObject:cuisineId]) continue;
        if ([gManorCuisineEmptyIds containsObject:cuisineId]) continue;
        return item;
    }
    return nil;
}

// 记一条本轮失败明细：供结算日志说清「哪几个没喂进去、为什么」
static void manorNoteCuisineFail(NSString *cuisineId, NSString *reason) {
    gManorCuisineRoundFail++;
    NSString *item = [NSString stringWithFormat:@"%@（%@）", cuisineId.length ? cuisineId : @"未知菜谱",
                      reason.length ? manorCnReason(reason) : @"未知原因"];
    gManorCuisineRoundFailNote = gManorCuisineRoundFailNote.length
        ? [NSString stringWithFormat:@"%@、%@", gManorCuisineRoundFailNote, item] : item;
}

- (void)feedManorChickenWithAdvancedFood {
    if (!self.enableAutoManor) return;
    if (manorChickenSleeping()) return;   // 小鸡在睡觉：饲料投不进去，等静默期过再试
    if (gManorCuisineInFlight) return;
    // 小鸡正在进食中照喂：高级饲料除睡觉外任何时候都能投（9/11 用户口径）
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gManorCuisineStopUntil > 0 && now < gManorCuisineStopUntil) return;
    
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) {
        [self feedManorChicken];
        return;
    }
    
    if (!gManorCuisineRunning) {
        // 起手先确认「有没有高级饲料」：库存过期就先查一次，回包或 5 秒到期后继续
        if (manorCuisineStockStale(now) && [self requestManorCuisineStockIfNeeded]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self feedManorChickenWithAdvancedFood];
            });
            return;
        }
        NSArray *prepared = manorAdvancedCuisineList();
        if (!manorNextCuisineToFeed(prepared)) {
            [self stopManorAdvancedFoodFeed:@"没有可投喂的高级饲料" silent:YES];
            return;
        }
        gManorCuisineRunning = YES;
        gManorCuisineFedCount = 0;
        gManorCuisineCursor = 0;
        gManorCuisineRoundOwned = manorOwnedCuisineList().count;
        gManorCuisineRoundCandidate = prepared.count;
        gManorCuisineRoundFail = 0;
        gManorCuisineRoundSkip = 0;
        gManorCuisineRoundFailNote = nil;
        [gManorCuisineBadIds removeAllObjects];
        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料投喂开始（识别到持有 %lu 种，本轮可喂 %lu 种，逐个投喂）...",
                           (unsigned long)manorOwnedCuisineList().count, (unsigned long)prepared.count]];
    }
    if (gManorCuisineFedCount >= 15) {
        [self stopManorAdvancedFoodFeed:@"已连喂 15 个，达单轮上限" silent:NO];
        return;
    }
    
    NSArray *cuisineList = manorAdvancedCuisineList();
    NSDictionary *cuisine = manorNextCuisineToFeed(cuisineList);
    if (!cuisine) {
        [self stopManorAdvancedFoodFeed:@"可喂的高级饲料已全部喂完" silent:YES];
        return;
    }
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *cuisineArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.useFarmFood\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"requestData\":[{\"cookbookId\":\"%@\",\"cuisineId\":\"%@\",\"useCuisine\":true,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"%@\",\"version\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorCuisineSource, kManorCuisineSource, cuisine[@"cookbookId"], cuisine[@"cuisineId"], kManorCuisineSource, kManorCuisineVersion, timeStamp, randNum];
    manorSendRPC(bridge, cuisineArg, url);
    gManorCuisineInFlight = YES;
    gManorCuisineInFlightId = cuisine[@"cuisineId"];
    gManorCuisineCursor++;
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：正在投喂第 %lu 个高级饲料（%@，持有 %@ 个，本轮可喂 %lu 种）...", (unsigned long)(gManorCuisineFedCount + 1), cuisine[@"cuisineId"], (cuisine[@"count"] ?: @"未知"), (unsigned long)cuisineList.count]];
    
    // 4 秒无回包：按「没喂进去」处理（不记成功、拉黑这一个），1.2 秒后继续下一个
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (!gManorCuisineInFlight) return;
        gManorCuisineInFlight = NO;
        NSString *stuckId = gManorCuisineInFlightId;
        if (stuckId.length) [gManorCuisineBadIds addObject:stuckId];
        manorNoteCuisineFail(stuckId, @"4 秒无回执");
        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料 %@ 4 秒无回执，本轮跳过（已成功 %lu 个）",
                           stuckId.length ? stuckId : @"未知菜谱", (unsigned long)gManorCuisineFedCount]];
        if (gManorCuisineFedCount >= 15) {
            [self stopManorAdvancedFoodFeed:@"连喂 15 个未收到成功回执" silent:NO];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self feedManorChickenWithAdvancedFood];
        });
    });
}

// 本轮结算：成功/失败/判无库存各几个 + 未投喂明细，避免「全部喂完」把失败吞掉（9/11 用户反馈）
- (void)logManorCuisineRoundSummary {
    NSString *tail = gManorCuisineRoundFailNote.length
        ? [NSString stringWithFormat:@"，未投喂 %@", gManorCuisineRoundFailNote] : @"";
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料本轮结算——成功 %lu 个，失败 %lu 个，判无库存 %lu 个（识别持有 %lu 种，候选 %lu 种）%@",
                       (unsigned long)gManorCuisineFedCount, (unsigned long)gManorCuisineRoundFail,
                       (unsigned long)gManorCuisineRoundSkip, (unsigned long)gManorCuisineRoundOwned,
                       (unsigned long)gManorCuisineRoundCandidate, tail]];
}

- (void)stopManorAdvancedFoodFeed:(NSString *)reason silent:(BOOL)silent {
    BOOL roundRan = gManorCuisineRunning;
    gManorCuisineRunning = NO;
    gManorCuisineInFlight = NO;
    if (roundRan) [self logManorCuisineRoundSummary];
    if (isManorSleepMemo(reason)) {
        gManorChickenSleepUntil = [[NSDate date] timeIntervalSince1970] + kManorChickenSleepQuiet;
        gManorCuisineStopUntil = 0;
        recordEggDiagOnce(self, @"cuisine_sleep",
                          [NSString stringWithFormat:@"蚂蚁庄园：小鸡在睡觉，暂不投喂饲料（%@）", manorCnReason(reason)]);
        return;   // 睡觉期间普通饲料同样喂不进，不再转普通饲料（省一次无效请求）
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (silent) {
        gManorCuisineStopUntil = now + 600;   // 没有可喂的高级饲料：静默收工，10 分钟后再看一次库存
        if (!roundRan) {
            recordEggDiagOnce(self, @"cuisine_none", @"蚂蚁庄园：当前没有可投喂的高级饲料（已按库存跳过），下一轮自动重查");
        }
        return;
    }
    gManorCuisineStopUntil = now + 1800;
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料投喂暂停（%@），转普通饲料投喂", manorCnReason(reason)]];
    [self feedManorChicken];
}

- (void)feedManorChicken {
    if (!self.enableAutoManor) return;
    if (manorChickenSleeping()) return;   // 睡觉静默期内不投喂（普通饲料服务端同样拒）
    if (self.isManorChickenEating) {
        if (!self.isManorFeedProbe) [self recordStage:@"蚂蚁庄园：小鸡当前正在进食中，暂无需投喂"];
        return;
    }
    
    static NSTimeInterval lastFeedTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastFeedTime < 4.0) return;
    lastFeedTime = now;
    
    // 1. 投喂前，先关闭抽屉面板，确保院子小鸡与饲料袋完全暴露
    [self closeManorTaskPanelOnWebView];
    
    if (!self.isManorFeedProbe) [self recordStage:@"蚂蚁庄园：正在投喂小鸡（180g 饲料）..."];
    
    PSDJsBridge *bridge = [self activeManorBridge];
    if (bridge) {
        NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
        NSString *randNum = [AntForestManager getNumberRandom:15];
        NSString *url = [self manorRPCUrlString];
        
        NSString *farmId = self.lastManorFarmId ?: @"";
        // 真实标准底层 RPC: com.alipay.antfarm.feedAnimal
        NSString *feedArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.feedAnimal\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"animalType\":\"CHICK\",\"canMock\":true,\"farmId\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId ?: @"", timeStamp, randNum];
        manorSendRPC(bridge, feedArg, url);
        
        // 真实标准底层状态同步: com.alipay.antfarm.syncAnimalStatus
        NSString *syncUserId = self.myUserId;
        if (!syncUserId.length && farmId.length > 2) {
            syncUserId = [farmId substringFromIndex:farmId.length / 2];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            NSString *syncArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"operType\":\"FEEDSYNC\",\"queryFoodStockInfo\":false,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"userId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId ?: @"", syncUserId ?: @"", [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
            manorSendRPC(bridge, syncArg, url);
        });
        
        if (!farmId.length) {
            // 没有 farmId 时触发一次 enterManorFarm 以便探明 farmId 并拉取最新主页状态
            [self enterManorFarm];
        }
    }
    
    // 静默探针模式只发底层 RPC（照 AntManor quietWatchTick），不做界面触控模拟
    if (self.isManorFeedProbe) return;
    
    // 2. 界面触控模拟：针对 Canvas 与饲料袋精准投喂
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self executeManorScriptOnWebView:@"(()=>{try{"
         "function sendTouch(target, type, x, y){"
         "  if(!target) return;"
         "  let t = null;"
         "  try{"
         "    t = new Touch({identifier:Date.now(), target:target, clientX:x, clientY:y, pageX:x, pageY:y, screenX:x, screenY:y, radiusX:15, radiusY:15});"
         "  }catch(e){}"
         "  if(!t && document.createTouch){"
         "    try{ t = document.createTouch(window, target, 1, x, y, x, y); }catch(e){}"
         "  }"
         "  if(t){"
         "    try{"
         "      const evt = new TouchEvent(type, {bubbles:true, cancelable:true, view:window, touches:(type==='touchend'?[]:[t]), targetTouches:(type==='touchend'?[]:[t]), changedTouches:[t]});"
         "      target.dispatchEvent(evt);"
         "    }catch(e){"
         "      if(document.createTouchList){"
         "        try{"
         "          const evt = document.createEvent('TouchEvent');"
         "          const touchList = (type==='touchend'?document.createTouchList():document.createTouchList(t));"
         "          evt.initTouchEvent(type, true, true, window, 0, 0, 0, x, y, false, false, false, false, touchList, touchList, document.createTouchList(t), 1, 0);"
         "          target.dispatchEvent(evt);"
         "        }catch(ee){}"
         "      }"
         "    }"
         "  }"
         "  try{"
         "    const opts = {bubbles:true, cancelable:true, view:window, clientX:x, clientY:y, button:0};"
         "    if(type==='touchstart'){"
         "      target.dispatchEvent(new PointerEvent('pointerdown', opts));"
         "      target.dispatchEvent(new MouseEvent('mousedown', opts));"
         "    } else if(type==='touchend'){"
         "      target.dispatchEvent(new PointerEvent('pointerup', opts));"
         "      target.dispatchEvent(new MouseEvent('mouseup', opts));"
         "      target.dispatchEvent(new MouseEvent('click', opts));"
         "      try{ target.click(); }catch(ce){}"
         "    }"
         "  }catch(e){}"
         "}"
         "const W = window.innerWidth, H = window.innerHeight;"
         "const bagX = W * 0.86, bagY = H * 0.90;"
         "const bowlX = W * 0.58, bowlY = H * 0.72;"
         "const canvas = document.querySelector('canvas') || document.body;"
         "const elAtBag = document.elementFromPoint(bagX, bagY) || canvas;"
         "const isInsideDrawer = elAtBag.closest && elAtBag.closest('.ant-drawer, [class*=\"drawer\"], [class*=\"task\"]');"
         "if(!isInsideDrawer){"
         "  // A. 模拟点击饲料袋"
         "  sendTouch(elAtBag, 'touchstart', bagX, bagY);"
         "  setTimeout(()=>{ sendTouch(elAtBag, 'touchend', bagX, bagY); }, 80);"
         "  // B. 模拟将饲料袋拖拽至饭盆"
         "  setTimeout(()=>{"
         "    sendTouch(canvas, 'touchstart', bagX, bagY);"
         "    setTimeout(()=>{"
         "      sendTouch(canvas, 'touchmove', (bagX+bowlX)/2, (bagY+bowlY)/2);"
         "      setTimeout(()=>{"
         "        sendTouch(canvas, 'touchmove', bowlX, bowlY);"
         "        setTimeout(()=>{"
         "          sendTouch(canvas, 'touchend', bowlX, bowlY);"
         "        }, 60);"
         "      }, 60);"
         "    }, 60);"
         "  }, 200);"
         "}"
         "// C. 查找是否有独立的饲料袋 DOM（严格排除抽屉、弹窗与跳转链接）"
         "const all = Array.from(document.querySelectorAll('*'));"
         "for(const el of all){"
         "  if(el.closest && el.closest('.ant-drawer, [class*=\"drawer\"], [class*=\"modal\"], [class*=\"dialog\"], [class*=\"task\"], [role=\"dialog\"], ul, ol')) continue;"
         "  if(el.tagName==='A' || (el.closest && el.closest('a[href]'))) continue;"
         "  const r = el.getBoundingClientRect();"
         "  if(r.width>0 && r.height>0 && r.top > H*0.70 && r.left > W*0.60){"
         "    const t = (el.innerText||el.textContent||'').trim();"
         "    const cls = (el.className||'').toString().toLowerCase();"
         "    const aria = (el.getAttribute('aria-label')||'').toLowerCase();"
         "    if(t==='投喂' || t==='喂食' || t==='喂小鸡' || t.includes('饲料') || cls.includes('feed') || cls.includes('food') || cls.includes('stock') || aria.includes('喂食') || aria.includes('饲料')){"
         "      sendTouch(el, 'touchstart', r.left+r.width/2, r.top+r.height/2);"
         "      sendTouch(el, 'touchend', r.left+r.width/2, r.top+r.height/2);"
         "      break;"
         "    }"
         "  }"
         "}"
         "}catch(e){console.error(e);}})();"];
    });
}

- (void)collectManorChickenManurePot:(NSString *)potNo {
    if (!self.enableAutoManor || !potNo.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *manureArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.collectManurePot\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"manurePotNOs\":\"%@\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", potNo, timeStamp, randNum];
    manorSendRPC(bridge, manureArg, url);
}

- (void)collectManorChickenManure {
    if (!self.enableAutoManor) return;
    
    NSString *today = getCurrentDateString();
    if ([self.lastManorManureCollectDate isEqualToString:today]) {
        return;
    }
    
    static NSTimeInterval lastCollectTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastCollectTime < 15) return;
    lastCollectTime = now;
    
    [self executeManorScriptOnWebView:@"(()=>{try{"
     "function triggerClick(el){if(!el)return;try{el.click();}catch(e){}}"
     "const all=Array.from(document.querySelectorAll('*'));"
     "for(const el of all){"
     "  const t=(el.innerText||el.getAttribute('aria-label')||'').trim();"
     "  if(t.includes('肥料')||t.includes('收肥料')||t.includes('金色肥料')||el.className?.includes?.('manure')){"
     "    triggerClick(el);"
     "    console.log('[AntForestPort] Clicked chicken manure pile');break;"
     "  }"
     "}"
     "}catch(e){}})();"];
}

#pragma mark - 收鸡蛋（harvestProduce）

// 收鸡蛋 RPC 口径（AntManor autoHarvest 实测）：operationType=com.alipay.antfarm.harvestProduce，harvestType=NORMALEGG
// 请求体 source 用 "antfarm"（非 H5），headers.source 沿用 9patch 口径；成功后补一条 syncAnimalStatus 刷新蛋巢
static NSString * const kManorEggRPCSource = @"chInfo_ch_appcenter__chsub_9patch";
static NSString * const kManorEggRPCVersion = @"1.8.2302070202.46";

// 庄园 H5 Bridge 强持有（照 AntManor gManorBridge）：离开庄园页后 WebView 不释放，60 秒监控定时器才能持续收蛋
static id gManorHeldBridge = nil;
// 收蛋监控心跳（秒）：照 AntManor「实时监听」口径，最短 1 分钟一轮
static NSTimeInterval const kManorEggWatchInterval = 60.0;
// 喂鸡静默探针间隔（秒）：照 AntManor quietWatchTick 口径，5 分钟一轮盲探，服务端裁决、失败静默
static NSTimeInterval const kManorFeedProbeInterval = 300.0;

// 收蛋诊断日志：同一句每天最多输出一条，避免每 60 秒重复刷屏
static NSMutableSet *gEggDiagLoggedKeys = nil;
static void recordEggDiagOnce(AntForestManager *mgr, NSString *key, NSString *message) {
    if (!gEggDiagLoggedKeys) gEggDiagLoggedKeys = [NSMutableSet set];
    NSString *fullKey = [NSString stringWithFormat:@"%@|%@", getCurrentDateString(), key];
    if ([gEggDiagLoggedKeys containsObject:fullKey]) return;
    [gEggDiagLoggedKeys addObject:fullKey];
    [mgr recordStage:message];
}

// 监控计数：面板只保留最近 100 条日志，收蛋 60 秒 / 喂鸡 5 分钟一轮的心跳若逐条记会刷屏、
// 把真正的事件（签到/投喂成功/收蛋成功）挤出面板，所以心跳按「每小时一条汇总」输出；成功类逐次记录、不封顶
static NSString *gLastWatchSummaryHour = nil;
static NSUInteger gWatchEggSent = 0;    // 本小时发出的收蛋请求次数
static NSUInteger gWatchEggOk = 0;      // 本小时成功收到蛋的次数
static NSUInteger gWatchFeedProbe = 0;  // 本小时喂鸡探针次数
static NSUInteger gWatchFeedOk = 0;     // 本小时投喂成功次数

static NSString *getCurrentHourString(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH";
    return [fmt stringFromDate:[NSDate date]];
}

// 每小时一条监控汇总：让「收蛋/喂鸡每天不止一次」在面板上按次数可见（成功类仍逐次记录）
- (void)flushManorWatchSummaryIfNeeded {
    NSString *hour = getCurrentHourString();
    if (!gLastWatchSummaryHour.length) {
        gLastWatchSummaryHour = hour;
        return;
    }
    if ([hour isEqualToString:gLastWatchSummaryHour]) return;
    gLastWatchSummaryHour = hour;
    if (!(gWatchEggSent || gWatchEggOk || gWatchFeedProbe || gWatchFeedOk)) return;
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 监控汇总（近 1 小时）：收蛋探测 %lu 次 / 成功 %lu 次，喂鸡探测 %lu 次 / 成功 %lu 次",
                      (unsigned long)gWatchEggSent, (unsigned long)gWatchEggOk,
                      (unsigned long)gWatchFeedProbe, (unsigned long)gWatchFeedOk]];
    gWatchEggSent = 0;
    gWatchEggOk = 0;
    gWatchFeedProbe = 0;
    gWatchFeedOk = 0;
}

// 高级饲料识别：庄园页面自己带来的数据里带着账号真实存在的 cookbookId + cuisineId
- (NSDictionary *)manorCuisinePairsIn:(id)obj {
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    NSUInteger budget = 600;
    manorScanCuisinePairs(obj, found, &budget);
    return found;
}

- (void)mergeLearnedCuisines:(NSDictionary *)found {
    if (!found.count) return;
    manorLoadLearnedCuisines();
    NSUInteger added = 0;
    for (NSString *cuisineId in found) {
        if (gManorLearnedCuisines[cuisineId]) continue;
        gManorLearnedCuisines[cuisineId] = found[cuisineId];
        added++;
    }
    if (!added) return;
    [NSUserDefaults.standardUserDefaults setObject:gManorLearnedCuisines forKey:kManorLearnedCuisineKey];
    recordEggDiagOnce(self, @"cuisine_learn",
                      [NSString stringWithFormat:@"蚂蚁庄园 · 高级饲料识别：新增 %lu 种菜谱（可喂菜谱共 %lu 种）",
                       (unsigned long)added, (unsigned long)gManorLearnedCuisines.count]);
}

- (void)learnManorCuisinesFromObject:(id)obj {
    if (!self.enableAutoManor || !obj) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gManorCuisineLearnScanAt < 2.0) return;
    gManorCuisineLearnScanAt = now;
    [self mergeLearnedCuisines:[self manorCuisinePairsIn:obj]];
    [self learnManorCuisineStockFromObject:obj];
}

// 「有没有高级饲料」主动查一次（照 H5 自己领饲料后的口径）：syncAnimalStatus + QUERY_CUISINE_LIST
// 返回 YES = 请求已发出（起手等这一包回包），NO = 节流中/条件不满足，直接按已有信息继续
- (BOOL)requestManorCuisineStockIfNeeded {
    if (!self.enableAutoManor) return NO;
    if (manorChickenSleeping()) return NO;
    PSDJsBridge *bridge = [self activeManorBridge];
    NSString *farmId = self.lastManorFarmId ?: @"";
    if (!bridge || !farmId.length) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gManorCuisineStockQueryAt > 0 && (now - gManorCuisineStockQueryAt) < 600.0) return NO;
    gManorCuisineStockQueryAt = now;
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *stockArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"requestData\":[{\"farmId\":\"%@\",\"operTag\":\"SYNC_RESUME\",\"operType\":\"QUERY_USER_INFO|QUERY_CUISINE_LIST|QUERY_SNACKS_FOOD\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorCuisineSource, kManorCuisineSource, farmId, kManorCuisineVersion, timeStamp, randNum];
    manorSendRPC(bridge, stockArg, url);
    return YES;
}

// 库存合并：识别到持有数 >0 才落库，并把该菜谱从「今天没库存」名单里放出来（用户可能又做了新的）
- (NSUInteger)mergeManorCuisineStock:(NSDictionary *)found {
    if (!found.count) return 0;
    manorLoadCuisineStock();
    manorLoadCuisineEmptyIds();
    NSUInteger updated = 0;
    for (NSString *cuisineId in found) {
        NSInteger count = [found[cuisineId] integerValue];
        if (count <= 0) continue;
        NSInteger old = [gManorCuisineStock[cuisineId] respondsToSelector:@selector(integerValue)] ? [gManorCuisineStock[cuisineId] integerValue] : 0;
        if (count != old) {
            gManorCuisineStock[cuisineId] = @(count);
            updated++;
        }
        [gManorCuisineEmptyIds removeObject:cuisineId];
    }
    if (!updated) return 0;
    gManorCuisineStockAt = [[NSDate date] timeIntervalSince1970];
    manorSaveCuisineStock();
    manorSaveCuisineEmptyIds();
    recordEggDiagOnce(self, @"cuisine_stock",
                      [NSString stringWithFormat:@"蚂蚁庄园 · 高级饲料库存识别：持有 %lu 种（共识别 %lu 种菜谱）",
                       (unsigned long)manorOwnedCuisineList().count, (unsigned long)gManorLearnedCuisines.count]);
    return updated;
}

// 识别到库存就投喂（除小鸡睡觉外任何时候都能喂，含正在吃普通饲料时）
- (void)learnManorCuisineStockFromObject:(id)obj {
    if (!self.enableAutoManor || !obj) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gManorCuisineStockScanAt < 0.5) return;
    gManorCuisineStockScanAt = now;
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    NSUInteger budget = 600;
    manorScanCuisineStock(obj, found, &budget);
    if (![self mergeManorCuisineStock:found]) return;
    if (manorChickenSleeping() || gManorCuisineInFlight) return;
    if (gManorCuisineStopUntil > 0 && now < gManorCuisineStopUntil) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self feedManorChickenWithAdvancedFood];
    });
}

// 投喂成功后本地扣一个（下一次统一以服务端回包为准）：扣到 0 就从可喂清单里消失，不再盲试
- (NSInteger)consumeManorCuisineStock:(NSString *)cuisineId {
    if (!cuisineId.length) return 0;
    manorLoadCuisineStock();
    NSInteger left = [gManorCuisineStock[cuisineId] respondsToSelector:@selector(integerValue)] ? [gManorCuisineStock[cuisineId] integerValue] : 0;
    left = (left > 0) ? (left - 1) : 0;
    if (left > 0) gManorCuisineStock[cuisineId] = @(left);
    else [gManorCuisineStock removeObjectForKey:cuisineId];
    manorSaveCuisineStock();
    return left;
}

// 页面自己发的高级饲料请求是最好的老师：ID、参数口径都以它为准，抓到就学
- (void)noteManorPageRPCRequest:(id)payload {
    if (!self.enableAutoManor || !payload) return;
    id obj = payload;
    if ([payload isKindOfClass:NSString.class]) {
        NSData *raw = [(NSString *)payload dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
        obj = parsed ?: payload;
    }
    NSDictionary *pairs = [self manorCuisinePairsIn:obj];
    if (!pairs.count) return;
    [self mergeLearnedCuisines:pairs];
    [self learnManorCuisineStockFromObject:obj];
    NSString *cuisineId = pairs.allKeys.firstObject;
    NSString *cookbookId = pairs[cuisineId];
    if (gManorCuisineInFlightId.length && [cuisineId isEqualToString:gManorCuisineInFlightId]) return;
    NSUInteger budget = 600;
    NSString *opType = manorFindOperationType(obj, &budget);
    recordEggDiagOnce(self, [@"pagereq_" stringByAppendingString:(opType.length ? opType : @"unknown")],
                      [NSString stringWithFormat:@"蚂蚁庄园 · 捕获到页面自己发的请求：%@（菜谱书 %@，菜谱 %@，本次识别 %lu 种）",
                       manorOperationDisplayName(opType), cookbookId, cuisineId, (unsigned long)pairs.count]);
}

#pragma mark - 抽抽乐（DrawMachine）自动攒次数与一键连抽

// —— 服务端口径（manor_probe 抓包 2026-09-11 实证，两个活动字段完全对称）——
// 查任务   com.alipay.antfarm.listFarmTask        requestData: taskSceneCode = ANTFARM_[IP_]DRAW_TASK
// 逛杂货铺 com.alipay.antiep.finishTask           outBizNo = <taskId>_<13位毫秒>_<8位hex>，source = ADBASICLIB
// 领次数   com.alipay.antfarm.receiveFarmTaskAward taskSceneCode + taskId + awardType
// 做任务   com.alipay.antfarm.doFarmTask          bizKey + taskSceneCode
// 查活动   com.alipay.antfarm.queryDrawMachineActivity scene + otherScenes
// 抽奖     com.alipay.antfarm.drawMachine         scene + batchDrawTimes（1 = 单抽，N = 连抽）
//
// 次数配额由服务端 rightsTimes / rightsTimesLimit 下发：逛杂货铺 3、饲料换机会 1、签到 1，
// 循环次数直接读字段，不硬编码。
// 用户口径：平时不抽，积满 maxDrawTimes（官方 10）才连抽；活动当天结束则剩余全部抽掉。
// 节奏（9/11 修正）：每个活动每 5 分钟补一轮、当天最多 kManorDrawMaxRounds 轮；任务全部做满才写 DONE 封盘，之后当天零请求。
// 教训：旧版「发起即标记收工」在桥断开或只做了一半时当天永久跳过 —— 实测漏做（逛杂货铺剩 1 次、第二个活动整个没做）。

static NSString * const kManorDrawSceneDaily     = @"dailyDrawMachine";
static NSString * const kManorDrawSceneIP        = @"ipDrawMachine";
static NSString * const kManorDrawTaskSceneDaily = @"ANTFARM_DAILY_DRAW_TASK";
static NSString * const kManorDrawTaskSceneIP    = @"ANTFARM_IP_DRAW_TASK";

static NSTimeInterval const kManorDrawRunInterval  = 300.0;   // 两轮之间最小间隔
static NSTimeInterval const kManorDrawStepInterval = 3.0;     // 相邻请求基础间隔
static NSTimeInterval const kManorDrawShopInterval = 14.0;    // 逛杂货铺每轮之间（模拟真实浏览）
static NSTimeInterval const kManorDrawSceneStagger = 8.0;     // 两个活动任务列表请求错开（旧版 55s，桥一断就漏做第二个活动）
static NSInteger    const kManorDrawMaxRounds      = 6;       // 每活动当天最多补跑轮数（6 轮 × 5 分钟 = 30 分钟，防风控）
static NSTimeInterval const kManorDrawExecThrottle = 20.0;    // 同一活动两次任务列表下发的最小间隔（H5 回包防重复）
static NSInteger    const kManorDrawDrawGapSeconds = 3;       // 降级单抽间隔
static NSInteger    const kManorDrawMaxDrawTimes   = 10;      // 单次连抽上限（服务端 maxDrawTimes 兜底值）
static NSTimeInterval const kManorDrawPendInterval = 25.0;    // 补抽轮间隔
static NSInteger    const kManorDrawPendMaxRounds  = 5;       // 补抽轮数上限（防风控）
static NSString  *gManorDrawPendScene  = nil;                 // 还有剩余次数没抽完的活动
static NSInteger  gManorDrawPendRemain = 0;                   // 剩余未抽次数
static NSInteger  gManorDrawPendRound  = 0;                   // 已补抽轮数
static NSTimeInterval gManorDrawPendNext = 0;                 // 下一轮最早可抽时间

static NSTimeInterval gManorDrawLastRunTime = 0;
static NSMutableArray<NSString *> *gManorDrawQueryScenes = nil;   // 查次数请求 FIFO，用于回包对号入座
static NSString *gManorDrawRetryScene = nil;                     // 降级重抽中的活动
static NSInteger gManorDrawRetryRemain = 0;
static NSString *gManorDrawLastDrawScene = nil;                  // 最近一次抽奖的活动（回包归属用）

// 抽抽乐任务分组：只做签到 / 逛杂货铺 / 饲料换机会，
// 小游戏、捐款、外部跳转（苏心游 / 江苏文旅）当前版本不下手（9/11 定「先不做，后续再动手」）
// 注：外部跳转并非做不了——browse + jumpUrl 后台预取 + finishTask 链路抓包已实证可走，
//     口径与试探方案见 skill antmanor-tweak-dev/references/external-jump-task-feasibility.md
static NSString *manorDrawTaskGroup(NSString *taskId) {
    if (!taskId.length) return nil;
    if ([taskId isEqualToString:@"SIGN_FREE_TASK"] || [taskId isEqualToString:@"IP_SIGN_FREE"]) return @"SIGN";
    if ([taskId isEqualToString:@"SHANGYEHUA_DAILY_DRAW_TIMES"] || [taskId isEqualToString:@"IP_SHANGYEHUA_TASK"]) return @"SHOP";
    if ([taskId isEqualToString:@"DAILY_DRAW_EXCHANGE_TASK_180"] || [taskId isEqualToString:@"IP_EXCHANGE_TASK_180"]) return @"FEED";
    return nil;
}

static NSString *manorDrawTaskSceneForScene(NSString *scene) {
    return [scene isEqualToString:kManorDrawSceneIP] ? kManorDrawTaskSceneIP : kManorDrawTaskSceneDaily;
}

static NSString *manorDrawSceneForTaskScene(NSString *taskScene) {
    return [taskScene isEqualToString:kManorDrawTaskSceneIP] ? kManorDrawSceneIP : kManorDrawSceneDaily;
}

static BOOL isManorDrawTaskScene(NSString *taskSceneCode) {
    return [taskSceneCode containsString:@"DRAW_TASK"];
}

// 回包里的 farmTaskList 是否属于抽抽乐（taskSceneCode 含 DRAW_TASK）
static BOOL isManorDrawTaskList(NSArray *taskList) {
    for (id item in taskList) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id ts = ((NSDictionary *)item)[@"taskSceneCode"];
        if ([ts isKindOfClass:NSString.class] && isManorDrawTaskScene(ts)) return YES;
    }
    return NO;
}

static BOOL isManorDrawOperation(NSString *opType) {
    if (!opType.length) return NO;
    return [opType containsString:@"queryDrawMachineActivity"] || [opType containsString:@"drawMachine"];
}

// outBizNo 口径：<taskId>_<13位毫秒>_<8位小写hex>（照抓包逐字复刻）
static NSString *manorDrawOutBizNo(NSString *taskId) {
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"%@_%lld_%08x", taskId, ms, (unsigned int)arc4random_uniform(0xFFFFFFFFu)];
}

static NSString *manorDrawDailyMark(NSString *prefix, NSString *scene) {
    return [NSString stringWithFormat:@"ANTFARM_DRAW_%@:%@", prefix, scene];
}

static NSString *manorDrawGroupName(NSString *group) {
    if ([group isEqualToString:@"SHOP"]) return @"逛杂货铺";
    if ([group isEqualToString:@"FEED"]) return @"饲料换机会";
    return @"签到";
}

// 当天已用轮数：键形如 ANTFARM_DRAW_RND:<scene>#<n>，随当天 cache 一起清零，进程重启不丢
static NSInteger manorDrawRoundUsed(NSString *scene) {
    NSString *prefix = manorDrawDailyMark(@"RND", scene);
    NSInteger n = 0;
    for (NSString *key in gDailyCompletedTasks) {
        if ([key hasPrefix:prefix]) n++;
    }
    return n;
}

static void manorDrawRoundBump(NSString *scene) {
    if (!gDailyCompletedTasks) gDailyCompletedTasks = [NSMutableSet set];
    NSInteger n = manorDrawRoundUsed(scene) + 1;
    [gDailyCompletedTasks addObject:[NSString stringWithFormat:@"%@#%ld", manorDrawDailyMark(@"RND", scene), (long)n]];
    saveDailyTaskCache();
}

// 同一活动下发窗口（内存态，仅防同一窗口重复下发：我方回包与 H5 回包撞车）
static NSMutableDictionary<NSString *, NSNumber *> *gManorDrawExecUntil = nil;

static BOOL manorDrawExecAllowed(NSString *scene) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!gManorDrawExecUntil) gManorDrawExecUntil = [NSMutableDictionary dictionary];
    if (now < [gManorDrawExecUntil[scene] doubleValue]) return NO;
    gManorDrawExecUntil[scene] = @(now + kManorDrawExecThrottle);
    return YES;
}

// 计划下发后把窗口延长到整轮执行结束（逛杂货铺一轮约 51s，期间回包不得重复下发同一批差额）
static void manorDrawExecHold(NSString *scene, NSTimeInterval duration) {
    if (!gManorDrawExecUntil) gManorDrawExecUntil = [NSMutableDictionary dictionary];
    NSTimeInterval until = [[NSDate date] timeIntervalSince1970] + duration + kManorDrawExecThrottle;
    if (until > [gManorDrawExecUntil[scene] doubleValue]) gManorDrawExecUntil[scene] = @(until);
}

static void manorDrawPushQueryScene(NSString *scene) {
    if (!gManorDrawQueryScenes) gManorDrawQueryScenes = [NSMutableArray array];
    @synchronized (gManorDrawQueryScenes) {
        while (gManorDrawQueryScenes.count >= 8) [gManorDrawQueryScenes removeObjectAtIndex:0];
        [gManorDrawQueryScenes addObject:scene];
    }
}

static NSString *manorDrawPopQueryScene(void) {
    if (!gManorDrawQueryScenes) return nil;
    @synchronized (gManorDrawQueryScenes) {
        if (!gManorDrawQueryScenes.count) return nil;
        NSString *scene = gManorDrawQueryScenes[0];
        [gManorDrawQueryScenes removeObjectAtIndex:0];
        return scene;
    }
}

// 从任意回包对象里找活动 scene（回包自带 scene / activityId 时优先用它，找不到再回落到 FIFO）
static NSString *manorDrawSceneInObject(id obj, NSUInteger *budget) {
    if (!obj || *budget == 0) return nil;
    (*budget)--;
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (NSString *key in (NSDictionary *)obj) {
            id value = ((NSDictionary *)obj)[key];
            if ([key isEqualToString:@"scene"] || [key isEqualToString:@"activityId"] || [key isEqualToString:@"sceneCode"]) {
                NSString *s = [value isKindOfClass:NSString.class] ? value : @"";
                if ([s containsString:kManorDrawSceneIP]) return kManorDrawSceneIP;
                if ([s containsString:kManorDrawSceneDaily]) return kManorDrawSceneDaily;
            }
            NSString *found = manorDrawSceneInObject(value, budget);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id value in (NSArray *)obj) {
            NSString *found = manorDrawSceneInObject(value, budget);
            if (found) return found;
        }
    }
    return nil;
}

// 补抽：单次上限抽不完的剩余次数，由心跳逐轮清空（先扣减再发请求 = 失败不重试，优先防风控）
- (void)drainManorDrawPending {
    if (!self.enableAutoManor) return;
    if (gManorDrawPendRemain <= 0 || !gManorDrawPendScene.length) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < gManorDrawPendNext) return;
    if (gManorDrawPendRound >= kManorDrawPendMaxRounds) {
        gManorDrawPendRemain = 0;
        gManorDrawPendScene = nil;
        gManorDrawPendRound = 0;
        return;
    }
    NSString *scene = gManorDrawPendScene;
    NSInteger times = gManorDrawPendRemain > kManorDrawMaxDrawTimes ? kManorDrawMaxDrawTimes : gManorDrawPendRemain;
    gManorDrawPendRound++;
    gManorDrawPendRemain -= times;
    gManorDrawPendNext = now + kManorDrawPendInterval;
    if (gManorDrawPendRemain <= 0) {
        gManorDrawPendRemain = 0;
        gManorDrawPendScene = nil;
        gManorDrawPendRound = 0;
    }
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：补抽剩余 %ld 次…", scene, (long)times]];
    [self requestManorDrawMachineDraw:scene times:times];
}

// 心跳入口：每个活动每 5 分钟补一轮，任务做满写 DONE 才封盘（之后当天零请求）
- (void)runManorDrawMachineDaily {
    if (!self.enableAutoManor) return;
    if (![self activeManorBridge]) return;

    [self drainManorDrawPending];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gManorDrawLastRunTime > 0 && now - gManorDrawLastRunTime < kManorDrawRunInterval) return;
    gManorDrawLastRunTime = now;

    initDailyTaskCache();

    NSInteger slot = 0;
    for (NSString *scene in @[kManorDrawSceneDaily, kManorDrawSceneIP]) {
        if ([gDailyCompletedTasks containsObject:manorDrawDailyMark(@"DONE", scene)]) continue;   // 已做满 → 零请求
        if (manorDrawRoundUsed(scene) >= kManorDrawMaxRounds) continue;                           // 当天轮数用完 → 停（防风控）
        manorDrawRoundBump(scene);
        NSTimeInterval delay = slot * kManorDrawSceneStagger;   // 两个活动错开，避免同一秒连发
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self queryManorDrawTaskListForScene:scene];
        });
        slot++;
    }

    if (slot == 0) {
        static NSTimeInterval lastIdleLog = 0;
        if (now - lastIdleLog > 3600) {
            lastIdleLog = now;
            [self recordStage:@"蚂蚁庄园 · 抽抽乐：今日任务已做满或轮数用完，不再监控（防风控）"];
        }
    }
}

// 读取某活动的抽抽乐任务列表
- (void)queryManorDrawTaskListForScene:(NSString *)scene {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSString *taskScene = manorDrawTaskSceneForScene(scene);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *listArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.listFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"NORMAL\",\"topTask\":\"\",\"source\":\"H5\",\"taskSceneCode\":\"%@\",\"signSceneCode\":\"\",\"sceneCode\":\"ANTFARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskScene, timeStamp, randNum];
    manorSendRPC(bridge, listArg, url);
    NSInteger round = manorDrawRoundUsed(scene);
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐：开始第 %ld/%ld 轮（%@），正在读取任务列表…", (long)round, (long)kManorDrawMaxRounds, scene]];
}

// 逛杂货铺：com.alipay.antiep.finishTask（每轮 outBizNo 全新）
- (void)finishManorDrawShopTask:(NSString *)taskId taskSceneCode:(NSString *)taskScene {
    if (!self.enableAutoManor || !taskId.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *outBizNo = manorDrawOutBizNo(taskId);
    NSString *finishArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antiep.finishTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"RPC\",\"outBizNo\":\"%@\",\"taskType\":\"%@\",\"source\":\"ADBASICLIB\",\"sceneCode\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", outBizNo, taskId, taskScene, timeStamp, randNum];
    manorSendRPC(bridge, finishArg, url);
}

// 饲料换机会：com.alipay.antfarm.doFarmTask（消耗 180g 饲料换机会）
- (void)doManorDrawExchangeTask:(NSString *)taskId taskSceneCode:(NSString *)taskScene {
    if (!self.enableAutoManor || !taskId.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *doArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.doFarmTask\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"RPC\",\"bizKey\":\"%@\",\"source\":\"icon\",\"taskSceneCode\":\"%@\",\"sceneCode\":\"ANTFARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskId, taskScene, timeStamp, randNum];
    manorSendRPC(bridge, doArg, url);
}

// 领抽抽乐次数：receiveFarmTaskAward（比常规领饲料多 taskSceneCode + awardType）
- (void)receiveManorDrawTaskAward:(NSString *)taskId taskSceneCode:(NSString *)taskScene awardType:(NSString *)awardType label:(NSString *)label {
    if (!self.enableAutoManor || !taskId.length) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *claimArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.receiveFarmTaskAward\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"RPC\",\"taskSceneCode\":\"%@\",\"source\":\"icon\",\"taskId\":\"%@\",\"awardType\":\"%@\",\"sceneCode\":\"ANTFARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", taskScene, taskId, awardType ?: @"", timeStamp, randNum];
    manorSendRPC(bridge, claimArg, url);
}

// 查活动状态与剩余次数
- (void)queryManorDrawMachineWithScene:(NSString *)scene {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSString *other = [scene isEqualToString:kManorDrawSceneIP] ? kManorDrawSceneDaily : kManorDrawSceneIP;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *queryArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.queryDrawMachineActivity\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"RPC\",\"source\":\"icon\",\"scene\":\"%@\",\"otherScenes\":[\"%@\"],\"sceneCode\":\"ANTFARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, other, timeStamp, randNum];
    manorDrawPushQueryScene(scene);
    manorSendRPC(bridge, queryArg, url);
}

// 抽奖：batchDrawTimes = 1 单抽，N 连抽
- (void)requestManorDrawMachineDraw:(NSString *)scene times:(NSInteger)times {
    if (!self.enableAutoManor || times <= 0) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    gManorDrawLastDrawScene = scene;
    NSString *drawArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.drawMachine\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"requestType\":\"RPC\",\"source\":\"icon\",\"scene\":\"%@\",\"batchDrawTimes\":%ld,\"sceneCode\":\"ANTFARM\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", scene, (long)times, timeStamp, randNum];
    manorSendRPC(bridge, drawArg, url);
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：一键连抽 %ld 次…", scene, (long)times]];
}

// 任务列表回包：按白名单分组执行，全部走完再查次数
- (void)handleManorDrawTaskList:(NSArray *)taskList {
    if (!self.enableAutoManor || !taskList.count) return;

    NSString *taskScene = @"";
    for (NSDictionary *task in taskList) {
        if (![task isKindOfClass:NSDictionary.class]) continue;
        NSString *ts = task[@"taskSceneCode"];
        if (ts.length) { taskScene = ts; break; }
    }
    if (!isManorDrawTaskScene(taskScene)) return;

    NSString *scene = manorDrawSceneForTaskScene(taskScene);
    NSString *defaultAward = [scene isEqualToString:kManorDrawSceneIP] ? @"IP_DRAW_MACHINE_DRAW_TIMES" : @"DAILY_DRAW_TIMES";

    // 任务列表回包（我方心跳或 H5 页面刷新都算）：已做满 → 零请求；桥已断 → 不消费本轮，留给下一轮
    initDailyTaskCache();
    if ([gDailyCompletedTasks containsObject:manorDrawDailyMark(@"DONE", scene)]) return;
    if (![self activeManorBridge]) return;
    if (!manorDrawExecAllowed(scene)) return;   // 20s 内同一活动的重复回包 → 防同一批差额重复下发

    NSMutableArray *plan = [NSMutableArray array];
    NSInteger skipped = 0;
    for (NSDictionary *task in taskList) {
        if (![task isKindOfClass:NSDictionary.class]) continue;
        NSString *taskId = task[@"taskId"] ?: @"";
        NSString *status = task[@"taskStatus"] ?: @"";
        NSString *group = manorDrawTaskGroup(taskId);
        if (!group) { skipped++; continue; }
        if ([status isEqualToString:@"RECEIVED"]) continue;
        NSInteger done = [task[@"rightsTimes"] integerValue];
        NSInteger limit = [task[@"rightsTimesLimit"] integerValue];
        if (limit <= 0) limit = 1;
        NSInteger todo = limit - done;
        if (todo <= 0 && ![status isEqualToString:@"FINISHED"]) continue;
        if (todo <= 0) todo = 1;
        if (todo > 5) todo = 5;
        [plan addObject:@{@"group": group, @"taskId": taskId, @"taskScene": taskScene,
                          @"awardType": (task[@"awardType"] ?: defaultAward), @"rounds": @(todo)}];
    }

    if (!plan.count) {
        [gDailyCompletedTasks addObject:manorDrawDailyMark(@"DONE", scene)];
        saveDailyTaskCache();
        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：今日任务已做满（跳过 %ld 项小游戏/捐款/外部跳转），封盘不再监控", scene, (long)skipped]];
        [self queryManorDrawMachineWithScene:scene];
        return;
    }

    NSTimeInterval t = 0;
    for (NSDictionary *item in plan) {
        NSString *group = item[@"group"];
        NSString *taskId = item[@"taskId"];
        NSString *ts = item[@"taskScene"];
        NSString *awardType = item[@"awardType"];
        NSString *groupName = manorDrawGroupName(group);
        NSInteger rounds = [item[@"rounds"] integerValue];
        for (NSInteger i = 0; i < rounds; i++) {
            NSInteger idx = i + 1;
            NSInteger total = rounds;
            NSString *stepLabel = [NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：执行「%@」第 %ld/%ld 次", scene, groupName, (long)idx, (long)total];
            NSTimeInterval actDelay = t;
            NSTimeInterval claimDelay = t + kManorDrawStepInterval;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(actDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (![self activeManorBridge]) {
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：已离开庄园，本轮中断，下次心跳补做", scene]];
                    return;
                }
                [self recordStage:stepLabel];
                if ([group isEqualToString:@"SHOP"]) {
                    [self finishManorDrawShopTask:taskId taskSceneCode:ts];
                } else if ([group isEqualToString:@"FEED"]) {
                    [self doManorDrawExchangeTask:taskId taskSceneCode:ts];
                }
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(claimDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (![self activeManorBridge]) return;
                [self receiveManorDrawTaskAward:taskId taskSceneCode:ts awardType:awardType label:groupName];
            });
            t = claimDelay + ([group isEqualToString:@"SHOP"] ? kManorDrawShopInterval : kManorDrawStepInterval);
        }
    }

    NSTimeInterval queryDelay = t + 6.0;
    manorDrawExecHold(scene, queryDelay);   // 整轮执行期间不接受第二份回包重复下发
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(queryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self queryManorDrawMachineWithScene:scene];
    });
}

// 回包处理：查次数 → 判定是否连抽；连抽失败 → 降级为逐次单抽
- (void)handleManorDrawMachineResponse:(NSString *)opType resData:(NSDictionary *)resData dict:(NSDictionary *)dict {
    if (!isManorDrawOperation(opType)) return;

    NSString *memo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: (dict[@"memo"] ?: @"")];
    BOOL ok = [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
              [memo isEqualToString:@"SUCCESS"] ||
              [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"];

    if ([opType containsString:@"queryDrawMachineActivity"]) {
        // 以我方请求 FIFO 为准（回包内同时含对方活动 id，扫描容易认错活动）
        NSString *scene = manorDrawPopQueryScene();
        if (!scene.length) {
            NSUInteger budget = 400;
            scene = manorDrawSceneInObject(resData, &budget) ?: manorDrawSceneInObject(dict, &budget);
        }
        if (!scene.length) return;

        NSInteger drawTimes = [resData[@"drawTimes"] integerValue];
        if (!resData[@"drawTimes"]) drawTimes = [dict[@"drawTimes"] integerValue];
        NSDictionary *activity = [resData[@"drawMachineActivity"] isKindOfClass:NSDictionary.class] ? resData[@"drawMachineActivity"] : nil;
        if (!activity && [dict[@"drawMachineActivity"] isKindOfClass:NSDictionary.class]) activity = dict[@"drawMachineActivity"];
        NSInteger maxDraw = [resData[@"maxDrawTimes"] integerValue];
        if (maxDraw <= 0) maxDraw = [dict[@"maxDrawTimes"] integerValue];
        if (maxDraw <= 0 && activity) maxDraw = [activity[@"maxDrawTimes"] integerValue];
        if (maxDraw <= 0) maxDraw = kManorDrawMaxDrawTimes;

        if (drawTimes <= 0) {
            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：当前 0 次机会，今日不抽", scene]];
            return;
        }

        BOOL isLastDay = NO;
        NSString *endRaw = nil;
        for (NSDictionary *src in @[resData, dict, activity ?: @{}]) {
            for (NSString *key in @[@"endTime", @"activityEndTime", @"endDate", @"activityEndDate"]) {
                id v = src[key];
                if (v != nil) { endRaw = [NSString stringWithFormat:@"%@", v]; break; }
            }
            if (endRaw.length) break;
        }
        if (endRaw.length) {
            long long ms = [endRaw longLongValue];
            NSDate *endDate = ms > 1000000000000LL ? [NSDate dateWithTimeIntervalSince1970:(ms / 1000.0)] : nil;
            if (endDate) {
                isLastDay = [[NSCalendar currentCalendar] isDateInToday:endDate];
            }
        }

        NSInteger times = 0;
        if (drawTimes >= maxDraw) {
            times = maxDraw;
            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：已积满 %ld 次，开始一键连抽 %ld 次…", scene, (long)drawTimes, (long)times]];
        } else if (isLastDay) {
            times = drawTimes > maxDraw ? maxDraw : drawTimes;
            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：活动今日结束，剩余 %ld 次全部抽掉…", scene, (long)drawTimes]];
        } else {
            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：已积 %ld/%ld 次，未满不抽（满 %ld 自动连抽）", scene, (long)drawTimes, (long)maxDraw, (long)maxDraw]];
            return;
        }

        if ([gDailyCompletedTasks containsObject:manorDrawDailyMark(@"PULL", scene)]) return;
        [gDailyCompletedTasks addObject:manorDrawDailyMark(@"PULL", scene)];
        saveDailyTaskCache();

        NSInteger left = drawTimes - times;
        if (left > 0) {
            NSInteger cap = maxDraw * kManorDrawPendMaxRounds;
            gManorDrawPendScene = scene;
            gManorDrawPendRemain = left > cap ? cap : left;
            gManorDrawPendRound = 0;
            gManorDrawPendNext = [[NSDate date] timeIntervalSince1970] + kManorDrawPendInterval;
            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：单次上限 %ld 次，本轮抽 %ld 次，剩余 %ld 次排队补抽", scene, (long)maxDraw, (long)times, (long)gManorDrawPendRemain]];
        }

        [self requestManorDrawMachineDraw:scene times:times];
        return;
    }

    // drawMachine 回包
    NSString *drawScene = gManorDrawLastDrawScene;
    if (!drawScene.length) {
        drawScene = manorDrawSceneInObject(resData, &(NSUInteger){0}) ?: manorDrawSceneInObject(dict, &(NSUInteger){0});
    }
    if (gManorDrawRetryRemain > 0 && gManorDrawRetryScene.length) drawScene = gManorDrawRetryScene;

    NSArray *prizes = [resData[@"drawMachinePrizeList"] isKindOfClass:NSArray.class] ? resData[@"drawMachinePrizeList"] : nil;
    if (!prizes && [dict[@"drawMachinePrizeList"] isKindOfClass:NSArray.class]) prizes = dict[@"drawMachinePrizeList"];

    if (ok) {
        NSString *sceneName = drawScene.length ? drawScene : @"抽抽乐";
        if (prizes.count) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *p in prizes) {
                if (![p isKindOfClass:NSDictionary.class]) continue;
                NSString *n = p[@"prizeName"] ?: (p[@"title"] ?: p[@"prizeTitle"]);
                if (n.length) [names addObject:n];
            }
            [self recordStage:[NSString stringWithFormat:@"✅ 蚂蚁庄园 · 抽抽乐（%@）：连抽完成，获得 %ld 个奖品%@", sceneName, (long)prizes.count, names.count ? [NSString stringWithFormat:@"（%@）", [names componentsJoinedByString:@"、"]] : @""]];
        } else {
            [self recordStage:[NSString stringWithFormat:@"✅ 蚂蚁庄园 · 抽抽乐（%@）：抽奖成功", sceneName]];
        }
        gManorDrawRetryRemain = 0;
        gManorDrawRetryScene = nil;
        return;
    }

    // 连抽被拒 → 降级为逐次单抽（间隔 3 秒）
    if (gManorDrawRetryRemain <= 0 && drawScene.length) {
        gManorDrawRetryScene = drawScene;
        gManorDrawRetryRemain = 10;
        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园 · 抽抽乐（%@）：连抽未被接受（%@），降级为逐次单抽", drawScene, memo.length ? memo : @"未知原因"]];
    }
    if (gManorDrawRetryRemain > 0 && drawScene.length) {
        gManorDrawRetryRemain--;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kManorDrawDrawGapSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self requestManorDrawMachineDraw:drawScene times:1];
        });
    }
}


#pragma mark - 收蛋监控（60 秒一轮常驻探测，照 AntManor 实时监听定时器）

// 当前可用的庄园 Bridge：优先实时绑定，庄园页面关闭后回落到强持有引用（照 AntManor gManorBridge 做法）
- (id)activeManorBridge {
    id bridge = self.manorBridge ?: gManorHeldBridge;
    if (!bridge || bridge == self.jsBridge) return nil;
    return bridge;
}

- (void)startManorEggWatchTimer {
    if (self.manorEggWatchTimer.isValid) return;
    if (![self activeManorBridge]) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startManorEggWatchTimer];
        });
        return;
    }
    self.manorEggWatchTimer = [NSTimer scheduledTimerWithTimeInterval:kManorEggWatchInterval target:self selector:@selector(manorEggWatchTick) userInfo:nil repeats:YES];
    [self recordStage:@"蚂蚁庄园 · 收蛋/喂鸡监控已启动（60 秒一轮，喂鸡每 5 分钟静默探一次）"];
}

// 每一轮心跳：睡觉 / 家庭签到 / 收鸡蛋 全部按各自「当天一次 + 冷却」规则补跑，重复调用不刷请求
- (void)manorEggWatchTick {
    if (!self.enableAutoManor) return;
    if (![self activeManorBridge]) return;
    [self flushManorWatchSummaryIfNeeded];
    [self retryManorPendingAutomations];
    // 抽抽乐：两个活动各自「当天一轮」，跑完即收工（当天不再发任何请求，防风控）
    [self runManorDrawMachineDaily];
    [self probeFeedManorChicken];
    [self requestManorCuisineStockIfNeeded];
}

// 喂鸡静默探针（照 AntManor quietWatchTick）：探测即动作，能不能喂由服务端裁决；
// 「还没吃完 / 小鸡睡觉 / 外出」等拒绝情形回包静默丢弃，不写面板日志，喂成功由回包分支记录
- (void)probeFeedManorChicken {
    if (!self.enableAutoManor) return;
    if (![self activeManorBridge]) return;
    
    static NSTimeInterval lastProbeTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastProbeTime < kManorFeedProbeInterval) return;
    lastProbeTime = now;
    gWatchFeedProbe++;
    
    self.isManorFeedProbe = YES;
    [self feedManorChicken];
    self.isManorFeedProbe = NO;
}

- (void)harvestManorEgg {
    if (!self.enableAutoManor) return;
    
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) {
        recordEggDiagOnce(self, @"bridge", @"蚂蚁庄园：收鸡蛋跳过（庄园桥接未就绪）");
        return;
    }
    
    NSString *farmId = self.lastManorFarmId ?: @"";
    if (!farmId.length) {
        recordEggDiagOnce(self, @"farmid", @"蚂蚁庄园：收鸡蛋跳过（尚未获取到庄园 ID）");
        return;
    }
    
    static NSTimeInterval lastEggHarvestTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastEggHarvestTime < 60) return;
    lastEggHarvestTime = now;
    
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    NSString *eggArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.harvestProduce\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"requestData\":[{\"farmId\":\"%@\",\"harvestType\":\"NORMALEGG\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"antfarm\",\"version\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorEggRPCSource, kManorEggRPCSource, farmId, kManorEggRPCVersion, timeStamp, randNum];
    manorSendRPC(bridge, eggArg, url);
    
    NSString *eggTail = farmId.length > 6 ? [farmId substringFromIndex:farmId.length - 6] : farmId;
    gWatchEggSent++;
    recordEggDiagOnce(self, @"eggsent", [NSString stringWithFormat:@"蚂蚁庄园：已发出收蛋请求（农场尾号 %@），此后每小时汇总一次", eggTail]);
}

// 赶走访客：记录最近一次请求的访客尾号，供回包确认时输出面板日志
static NSString *gLastExpelledTail = nil;

- (void)sendBackManorAnimal:(NSString *)animalId masterFarmId:(NSString *)masterFarmId {
    if (!self.enableAutoManor || !animalId.length || !masterFarmId.length) return;
    
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;
    
    NSString *farmId = self.lastManorFarmId ?: @"";
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)(now * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];
    NSString *url = [self manorRPCUrlString];
    
    // 真实标准底层 RPC: com.alipay.antfarm.sendBackAnimal（把访客小鸡送回它自己家的农场）
    NSString *expelArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.sendBackAnimal\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"animalId\":\"%@\",\"currentFarmId\":\"%@\",\"masterFarmId\":\"%@\",\"receiveNPCReward\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"sendType\":\"NORMAL\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", animalId, farmId, masterFarmId, timeStamp, randNum];
    manorSendRPC(bridge, expelArg, url);
    
    NSString *tail = masterFarmId.length > 6 ? [masterFarmId substringFromIndex:masterFarmId.length - 6] : masterFarmId;
    gLastExpelledTail = tail;
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：正在赶走偷吃的小鸡（访客尾号 %@）...", tail]];
    
    // 赶走后同步访客列表，让院子里的小鸡从页面上消失
    NSString *syncUserId = self.myUserId;
    if (!syncUserId.length && farmId.length > 2) {
        syncUserId = [farmId substringFromIndex:farmId.length / 2];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        NSString *syncArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"operTag\":\"SYNC_RESUME\",\"operType\":\"QUERY_ALL\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"userId\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", farmId ?: @"", syncUserId ?: @"", [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, syncArg, url);
    });
    
    // 顺手给来偷吃的访客发个生气表情（与蚂蚁庄园手动流程一致）
    if (masterFarmId.length >= 16) {
        NSString *friendUserId = [masterFarmId substringFromIndex:masterFarmId.length - 16];
        NSString *chatArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.liveChat\",\"showError\":false,\"showLoading\":false,\"requestData\":[{\"friendUserId\":\"%@\",\"requestType\":\"NORMAL\",\"scene\":\"ANGER_03\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"type\":\"HURT\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", friendUserId, [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, chatArg, url);
    }
}

- (void)expelManorVisitors:(NSArray *)animals {
    if (!self.enableAutoManor) return;
    if (![animals isKindOfClass:NSArray.class] || !animals.count) return;
    if (!self.lastManorFarmId.length) return;
    
    static NSTimeInterval lastExpelScanTime = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - lastExpelScanTime < 20.0) return;
    lastExpelScanTime = now;
    
    static NSMutableSet *expelledFarmIds = nil;
    if (!expelledFarmIds) expelledFarmIds = [NSMutableSet set];
    
    // 来偷吃的访客清单是「当前院子状态」：清单里已经不存在的农场，说明那只小鸡已经走了，
    // 顺手清掉它的去重记录 —— 否则同一只小鸡下次再来会被永久跳过（进程不重启就再也不赶）
    NSMutableSet *presentFarmIds = [NSMutableSet set];
    for (NSDictionary *animal in animals) {
        if (![animal isKindOfClass:NSDictionary.class]) continue;
        NSString *pf = [NSString stringWithFormat:@"%@", animal[@"masterFarmId"] ?: @""];
        if (pf.length) [presentFarmIds addObject:pf];
    }
    [expelledFarmIds intersectSet:presentFarmIds];
    
    NSMutableArray *queue = [NSMutableArray array];
    for (NSDictionary *animal in animals) {
        if (![animal isKindOfClass:NSDictionary.class]) continue;
        NSString *mFarmId = [NSString stringWithFormat:@"%@", animal[@"masterFarmId"] ?: @""];
        if (!mFarmId.length || [mFarmId isEqualToString:self.lastManorFarmId]) continue;  // 院子里自己的小鸡不赶
        if ([expelledFarmIds containsObject:mFarmId]) continue;                           // 本次运行已赶过，不重复发请求
        NSString *aid = [NSString stringWithFormat:@"%@", animal[@"animalId"] ?: @""];
        if (!aid.length && mFarmId.length > 1) {
            // 回包未带 animalId 时推导：animalId = "2" + masterFarmId 去掉首位
            aid = [NSString stringWithFormat:@"2%@", [mFarmId substringFromIndex:1]];
        }
        if (!aid.length) continue;
        [queue addObject:@[aid, mFarmId]];
        [expelledFarmIds addObject:mFarmId];
    }
    if (!queue.count) return;
    
    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：发现 %lu 只来偷吃的小鸡，正在逐个赶走...", (unsigned long)queue.count]];
    
    NSInteger index = 0;
    for (NSArray *pair in queue) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(index * 3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendBackManorAnimal:pair[0] masterFarmId:pair[1]];
        });
        index++;
    }
}

#pragma mark - 小鸡睡觉（家庭别墅）

// 睡觉 RPC 口径：AntManor rpc31 抓包实证 —— 家庭别墅 = 先 enterFamily 再 sleep，source=aixinxiaowutojiating
// 本插件只送小鸡去家庭别墅睡觉，爱心小屋不启用
static NSString * const kManorSleepSource      = @"aixinxiaowutojiating";
static NSString * const kManorSleepRPCSource   = @"chInfo_ch_appcenter__chsub_9patch";
static NSString * const kManorSleepDoneDateKey = @"antforest_manor_sleep_date";
// 上次被服务端接受的口径序号（落盘：下一晚优先复用，不再从第一组重跑）
static NSString * const kManorSleepVariantKey  = @"antforest_manor_sleep_variant";
// 家庭组 ID（rpc31 抓包实证，与 AntManor 同一账号）
static NSString * const kManorFamilyGroupId    = @"0372620009220250119202832812";

// 睡觉口径变体：一组口径 = enterFamily(+refinedOperation) + sleep 的请求参数组合
//  idx 0：与真机已验证的家庭签到链同构（enterFamily source=H5 → refinedOperation(ENTERFAMILY) → sleep NORMAL + 真实版本号）
//  idx 1：rpc31 口径（3.1.4 真机实证：9/11 21:00 送睡成功就是这一组）
//  idx 2：rpc31 口径 + 补 refinedOperation(ENTERFAMILY)
//  idx 3：全 H5 口径（enterFamily 与 sleep 都用 source=H5）
static const NSInteger kManorSleepVariantCount = 4;
// 两次尝试间隔（秒）：服务端会因小鸡进食/外出拒一次，10 分钟后再试，不必等半小时
static const NSTimeInterval kManorSleepAttemptGap = 600;
// 每晚上限（次）：防止整晚反复打请求
static const NSInteger kManorSleepAttemptMax = 12;
static BOOL gManorSleepPending = NO;
static NSInteger gManorSleepInFlightVariant = -1;
static NSString *gManorSleepAttemptDate = nil;
static NSInteger gManorSleepAttemptCount = 0;

// 每天 20:00 之后才送小鸡回别墅睡觉
static BOOL isManorSleepTime(void) {
    NSDateComponents *comp = [[NSCalendar currentCalendar] components:NSCalendarUnitHour fromDate:[NSDate date]];
    return comp.hour >= 20;
}

// 当天是否已睡过（落盘，跨启动有效，避免夜里反复重发）
static BOOL isManorSleepDoneToday(void) {
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kManorSleepDoneDateKey];
    return [last isEqualToString:getCurrentDateString()];
}

static void markManorSleepDone(void) {
    [[NSUserDefaults standardUserDefaults] setObject:getCurrentDateString() forKey:kManorSleepDoneDateKey];
    if (gManorSleepInFlightVariant >= 0) {
        [[NSUserDefaults standardUserDefaults] setInteger:gManorSleepInFlightVariant forKey:kManorSleepVariantKey];
    }
}

// 优先口径：上次真机睡成的那一组；没记录就用 rpc31 口径（idx 1）
static NSInteger manorSleepPreferredVariant(void) {
    NSString *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kManorSleepVariantKey];
    if (!stored) return 1;
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kManorSleepVariantKey];
    if (v < 0 || v >= kManorSleepVariantCount) return 1;
    return v;
}

// 尝试步序 -> 口径序号：第一步永远是「已验证口径」，之后才逐个换备选
static NSInteger manorSleepVariantForStep(NSInteger step) {
    NSInteger first = manorSleepPreferredVariant();
    if (step <= 0) return first;
    NSInteger seen = 0;
    for (NSInteger v = 0; v < kManorSleepVariantCount; v++) {
        if (v == first) continue;
        seen++;
        if (seen == step) return v;
    }
    return first;
}

static void manorSleepVariantAt(NSInteger idx, NSString **enterSource, BOOL *refined, NSString **sleepSource, NSString **sleepRequestType, NSString **sleepVersion) {
    switch ((idx % kManorSleepVariantCount + kManorSleepVariantCount) % kManorSleepVariantCount) {
        case 0:
            *enterSource = @"H5";
            *refined = YES;
            *sleepSource = kManorSleepSource;
            *sleepRequestType = @"NORMAL";
            *sleepVersion = @"1.8.2302070202.46";
            break;
        case 1:
            *enterSource = kManorSleepSource;
            *refined = NO;
            *sleepSource = kManorSleepSource;
            *sleepRequestType = @"RPC";
            *sleepVersion = @"unknown";
            break;
        case 2:
            *enterSource = kManorSleepSource;
            *refined = YES;
            *sleepSource = kManorSleepSource;
            *sleepRequestType = @"NORMAL";
            *sleepVersion = @"1.8.2302070202.46";
            break;
        default:
            *enterSource = @"H5";
            *refined = NO;
            *sleepSource = @"H5";
            *sleepRequestType = @"NORMAL";
            *sleepVersion = @"1.8.2302070202.46";
            break;
    }
}

// 当晚允许再试一次？每 600 秒最多一次，整晚封顶 kManorSleepAttemptMax 次
static BOOL canStartManorSleepAttempt(void) {
    static NSTimeInterval lastSleepAttempt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (lastSleepAttempt > 0 && now - lastSleepAttempt < kManorSleepAttemptGap) return NO;
    if (![gManorSleepAttemptDate isEqualToString:getCurrentDateString()]) {
        gManorSleepAttemptDate = getCurrentDateString();
        gManorSleepAttemptCount = 0;
    }
    if (gManorSleepAttemptCount >= kManorSleepAttemptMax) return NO;
    lastSleepAttempt = now;
    gManorSleepAttemptCount++;
    return YES;
}

- (void)sleepManorChicken {
    if (!self.enableAutoManor) return;
    if (!isManorSleepTime()) {
        recordEggDiagOnce(self, @"sleep_wait", @"蚂蚁庄园：还没到 20:00，小鸡先在外面玩");
        return;
    }
    if (isManorSleepDoneToday()) return;
    if (gManorSleepPending) return;

    if (!canStartManorSleepAttempt()) {
        recordEggDiagOnce(self, @"sleep_cool", @"蚂蚁庄园：睡觉重试冷却中（每 10 分钟一次，今晚封顶 12 次）");
        return;
    }
    if (![self activeManorBridge]) {
        recordEggDiagOnce(self, @"sleep_bridge", @"蚂蚁庄园：睡觉跳过（庄园桥接未就绪，等庄园页面出现）");
        return;
    }

    gManorSleepPending = YES;
    recordEggDiagOnce(self, @"sleep_open", @"蚂蚁庄园：已到 20:00，开始尝试送小鸡回家庭别墅睡觉");
    [self sendManorSleepStep:0 round:0];
}

// 逐组口径尝试：口径不靠猜，只看服务端回包（成功即 markManorSleepDone），被拒就自动换下一组
- (void)sendManorSleepStep:(NSInteger)step round:(NSInteger)round {
    if (isManorSleepDoneToday() || !isManorSleepTime()) {
        gManorSleepPending = NO;
        return;
    }
    if (step >= kManorSleepVariantCount) {
        gManorSleepPending = NO;
        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：本轮 %ld 组睡觉口径都没睡成，%ld 分钟后再试", (long)kManorSleepVariantCount, (long)(kManorSleepAttemptGap / 60)]];
        return;
    }

    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) {
        gManorSleepPending = NO;
        recordEggDiagOnce(self, @"sleep_bridge", @"蚂蚁庄园：睡觉跳过（庄园桥接未就绪，等庄园页面出现）");
        return;
    }

    NSInteger idx = manorSleepVariantForStep(step);
    NSString *enterSource = nil;
    NSString *sleepSource = nil;
    NSString *sleepRequestType = nil;
    NSString *sleepVersion = nil;
    BOOL refined = NO;
    manorSleepVariantAt(idx, &enterSource, &refined, &sleepSource, &sleepRequestType, &sleepVersion);

    NSString *url = [self manorRPCUrlString];
    NSString *farmId = self.lastManorFarmId ?: @"";
    gManorSleepInFlightVariant = idx;

    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：天黑了，正在送小鸡回家庭别墅睡觉...（第 %ld 次尝试，口径 %ld/%ld）", (long)gManorSleepAttemptCount, (long)(step + 1), (long)kManorSleepVariantCount]];

    // 1. 家庭别墅需先进家庭（rpc31：enterFamily source=aixinxiaowutojiating）
    NSString *enterTs = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    NSString *enterArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.enterFamily\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"fromAnn\":false,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"%@\",\"timeZoneId\":\"Asia/Shanghai\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, farmId, enterSource, enterTs, [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, enterArg, url);

    NSInteger enterDelayMs = refined ? 1500 : 0;

    // 2. 部分口径要补 refinedOperation(ENTERFAMILY)（与真机已验证的家庭签到链一致）
    if (refined) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (isManorSleepDoneToday()) return;
            NSString *refineTs = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
            NSString *refineArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.refinedOperation\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"actionId\":\"ENTERFAMILY\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, refineTs, [AntForestManager getNumberRandom:15]];
            manorSendRPC(bridge, refineArg, url);
        });
    }

    // 3. 进家庭后发 sleep（source / requestType / version 按口径变体决定）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((enterDelayMs + 2000) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (isManorSleepDoneToday()) return;
        NSString *sleepTs = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
        NSString *sleepArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.sleep\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"groupId\":\"%@\",\"recall\":false,\"requestType\":\"%@\",\"sceneCode\":\"ANTFARM\",\"source\":\"%@\",\"spaceType\":\"ChickFamily\",\"version\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, kManorFamilyGroupId, sleepRequestType, sleepSource, sleepVersion, sleepTs, [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, sleepArg, url);

        // 4. 睡后同步动物状态，刷新页面显示
        if (!farmId.length) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *syncTs = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
            NSString *syncArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"operTag\":\"SYNC_RESUME\",\"operType\":\"QUERY_ALL\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"%@\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, farmId, kManorSleepRPCSource, syncTs, [AntForestManager getNumberRandom:15]];
            manorSendRPC(bridge, syncArg, url);
        });
    });

    // 5. 本组口径的判决窗口：没等到「睡着」就换下一组（失败原因看面板日志）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((enterDelayMs + 6000) * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (isManorSleepDoneToday()) {
            gManorSleepPending = NO;
            return;
        }
        if (gManorSleepInFlightVariant != idx) return;
        [self sendManorSleepStep:step + 1 round:round];
    });
}

// ---------------- 家庭签到（AntManor 移植）----------------
// 抓包口径 manor_rpc(14)：enterFamily -> refinedOperation(ENTERFAMILY)
//   -> receiveFarmTaskAward(FAMILY_SIGN_TASK / ANTFARM_FAMILY_TASK / FAMILY_INTIMACY)
//   -> 成功后 syncFamilyStatus(INTIMACY_VALUE) + syncAnimalStatus(SYNC_RESUME_FAMILY)
static NSString * const kManorFamilySignDateKey = @"antforest_manor_family_sign_date";
static BOOL gManorFamilySignPending = NO;

static BOOL isManorFamilySignDoneToday(void) {
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:kManorFamilySignDateKey];
    return [last isEqualToString:getCurrentDateString()];
}

static void markManorFamilySignDone(void) {
    [[NSUserDefaults standardUserDefaults] setObject:getCurrentDateString() forKey:kManorFamilySignDateKey];
}

- (void)signManorFamily {
    if (!self.enableAutoManor) return;
    if (isManorFamilySignDoneToday()) return;

    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) {
        recordEggDiagOnce(self, @"familysign_bridge", @"蚂蚁庄园：家庭签到跳过（庄园桥接未就绪）");
        return;
    }
    // 防重入 + 失败重试节流：链外补跑时 30 分钟内最多发一次
    if (gManorFamilySignPending) return;
    static NSTimeInterval lastFamilySignAttempt = 0;
    NSTimeInterval signNow = [[NSDate date] timeIntervalSince1970];
    if (lastFamilySignAttempt > 0 && signNow - lastFamilySignAttempt < 1800) return;
    lastFamilySignAttempt = signNow;

    NSString *url = [self manorRPCUrlString];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    NSString *randNum = [AntForestManager getNumberRandom:15];

    [self recordStage:@"蚂蚁庄园：正在执行家庭签到..."];

    // 1. 家庭签到前置：先进入家庭（与睡觉共用同一条 enterFamily）
    NSString *enterArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.enterFamily\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"fromAnn\":false,\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"timeZoneId\":\"Asia/Shanghai\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, timeStamp, randNum];
    manorSendRPC(bridge, enterArg, url);

    // 2. +1.5s 进入家庭场景（ENTERFAMILY）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        NSString *refineArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.refinedOperation\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"actionId\":\"ENTERFAMILY\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, refineArg, url);
    });

    // 3. +3.0s 领取家庭签到奖励（FAMILY_SIGN_TASK / FAMILY_INTIMACY）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        NSString *awardArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.receiveFarmTaskAward\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"awardType\":\"FAMILY_INTIMACY\",\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"taskId\":\"FAMILY_SIGN_TASK\",\"taskSceneCode\":\"ANTFARM_FAMILY_TASK\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, awardArg, url);
        gManorFamilySignPending = YES;   // 等这条回包判定成功/已签到
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (!gManorFamilySignPending) return;   // 已收到回包，无需处理
            gManorFamilySignPending = NO;           // 回包超时复位，避免挡住饲料奖励解析
            [self recordStage:@"蚂蚁庄园：家庭签到回包超时，下次自动重试"];
        });
    });
}

- (void)syncManorFamilyStatusAndAnimal {
    if (!self.enableAutoManor) return;
    PSDJsBridge *bridge = [self activeManorBridge];
    if (!bridge) return;

    [self recordStage:@"蚂蚁庄园：正在同步家庭状态（亲密值）与小鸡状态..."];

    NSString *farmId = self.lastManorFarmId ?: @"";
    NSString *userId = self.myUserId;
    if (!userId.length && farmId.length > 2) {
        userId = [farmId substringFromIndex:farmId.length / 2];
    }
    NSString *url = [self manorRPCUrlString];

    // 1. 同步家庭状态（亲密值）
    NSString *familyArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncFamilyStatus\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"groupId\":\"%@\",\"operType\":\"INTIMACY_VALUE\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"syncUserIds\":[\"%@\"],\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, kManorFamilyGroupId, userId ?: @"", [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
    manorSendRPC(bridge, familyArg, url);

    // 2. +1.2s 同步小鸡状态（家庭场景），刷新页面显示
    if (!farmId.length) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        NSString *animalArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"showError\":false,\"showLoading\":false,\"requestData\":[{\"farmId\":\"%@\",\"operTag\":\"SYNC_RESUME_FAMILY\",\"operType\":\"QUERY_ALL|QUERY_FAMILY_ANIMAL\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"1.8.2302070202.46\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorSleepRPCSource, kManorSleepRPCSource, farmId, [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)], [AntForestManager getNumberRandom:15]];
        manorSendRPC(bridge, animalArg, url);
    });
}

// 庄园体检链上次执行时间（链外补跑据此避免插队、打乱原有 RPC 时序）
static NSTimeInterval gLastManorCheckTime = 0;

- (void)checkAndRunManorAutomations {
    if (!self.enableAutoManor) return;
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - gLastManorCheckTime < 15.0) return;
    gLastManorCheckTime = now;
    
    self.isManorChickenEating = NO;
    
    [self recordStage:@"蚂蚁庄园：正在执行日常自动化体检..."];
    
    // 0. 主动刷新庄园主页状态（获取小鸡进食、饭盆余粮、饲料存量等状态）
    [self enterManorFarm];
    
    // 1. 每日签到
    [self signManorDaily];
    
    // 2. 智能答题
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self answerManorClassroomQuestion];
    });
    
    // 3. 收取肥料（仅在今日未收取时尝试）
    NSString *today = getCurrentDateString();
    if (![self.lastManorManureCollectDate isEqualToString:today]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self collectManorChickenManure];
        });
    }
    
    // 4. 自动投喂小鸡（优先逐个投喂高级饲料，喂不动/喂完转普通 180g 饲料兜底）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self feedManorChickenWithAdvancedFood];
    });
    
    // 5. 庄园任务体检与做任务
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self queryManorFarmTasks];
    });

    // 6. 夜间睡觉（每天 20:00 后送小鸡回家庭别墅，当天只睡一次）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self sleepManorChicken];
    });

    // 7. 家庭签到（每天一次，领家庭亲密值；已签到/成功即落盘当日完成）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self signManorFamily];
    });

    // 8. 收鸡蛋（有蛋才收：蛋巢无蛋时服务端回绝，静默不打扰；60s 冷却防重发）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self harvestManorEgg];
    });
}

- (void)retryManorPendingAutomations {
    if (!self.enableAutoManor) return;
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gLastManorCheckTime > 0 && now - gLastManorCheckTime < 15.0) return;
    
    if (isManorSleepTime() && !isManorSleepDoneToday()) {
        [self sleepManorChicken];
    }
    if (!isManorFamilySignDoneToday()) {
        [self signManorFamily];
    }
    [self harvestManorEgg];
}

- (void)handleManorResponse:(NSDictionary *)dict {
    if (!self.enableAutoManor) return;
    // 收蛋监控：强持有庄园 Bridge，并启动 60 秒一轮常驻探测（页面关闭后仍持续收蛋）
    if (self.manorBridge && gManorHeldBridge != self.manorBridge) {
        manorClearPendingOps();   // 换页 / WebView 重建：旧请求的回包不会再来，清空 FIFO 防错位
        gManorHeldBridge = self.manorBridge;
    }
    [self startManorEggWatchTimer];
    if (![dict isKindOfClass:NSDictionary.class]) return;
    
    @try {
        NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : dict;

        // 菜谱识别：任何庄园回包里出现成对的 cookbookId + cuisineId，就记下来当真实可喂菜谱
        [self learnManorCuisinesFromObject:dict];
        
        // A. 小鸡与饭盆状态检测 (subFarmVO / ownAnimal)
        NSDictionary *subFarm = [resData[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? resData[@"subFarmVO"] : ([dict[@"subFarmVO"] isKindOfClass:NSDictionary.class] ? dict[@"subFarmVO"] : nil);
        NSDictionary *ownAnimal = [resData[@"ownAnimal"] isKindOfClass:NSDictionary.class] ? resData[@"ownAnimal"] : ([dict[@"ownAnimal"] isKindOfClass:NSDictionary.class] ? dict[@"ownAnimal"] : nil);
        
        if (subFarm || ownAnimal) {
            if (subFarm[@"farmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", subFarm[@"farmId"]];
            } else if (ownAnimal[@"farmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", ownAnimal[@"farmId"]];
            } else if (ownAnimal[@"masterFarmId"]) {
                self.lastManorFarmId = [NSString stringWithFormat:@"%@", ownAnimal[@"masterFarmId"]];
            }
            
            NSString *farmId = self.lastManorFarmId;
            NSArray *animals = [subFarm[@"animals"] isKindOfClass:NSArray.class] ? subFarm[@"animals"] : nil;
            if (animals.count > 0) {
                for (NSDictionary *animal in animals) {
                    if ([animal isKindOfClass:NSDictionary.class]) {
                        NSString *mFarmId = [NSString stringWithFormat:@"%@", animal[@"masterFarmId"] ?: @""];
                        NSString *aFarmId = [NSString stringWithFormat:@"%@", animal[@"farmId"] ?: @""];
                        if ((farmId.length && ([mFarmId isEqualToString:farmId] || [aFarmId isEqualToString:farmId])) ||
                            [animal[@"animalStatusVO"][@"animalInteractStatus"] isEqualToString:@"HOME"]) {
                            self.lastManorAnimalId = [NSString stringWithFormat:@"%@", animal[@"animalId"]];
                            break;
                        }
                    }
                }
                if (!self.lastManorAnimalId.length && animals.firstObject[@"animalId"]) {
                    self.lastManorAnimalId = [NSString stringWithFormat:@"%@", animals.firstObject[@"animalId"]];
                }
            } else if (ownAnimal[@"animalId"]) {
                self.lastManorAnimalId = [NSString stringWithFormat:@"%@", ownAnimal[@"animalId"]];
            }
            
            // 访客小鸡检查：院子里 masterFarmId 不是自己农场的，就是来偷吃饲料的访客，逐个赶走
            if (animals.count > 0) {
                [self expelManorVisitors:animals];
            }
            
            NSInteger foodStock = 0;
            if (subFarm[@"foodStock"]) {
                foodStock = [subFarm[@"foodStock"] integerValue];
            } else if (resData[@"foodStock"]) {
                foodStock = [resData[@"foodStock"] integerValue];
            } else if (dict[@"foodStock"]) {
                foodStock = [dict[@"foodStock"] integerValue];
            }
            NSInteger foodStockLimit = [subFarm[@"foodStockLimit"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"foodStockLimit"] integerValue] : ([resData[@"foodStockLimit"] respondsToSelector:@selector(integerValue)] ? [resData[@"foodStockLimit"] integerValue] : 1800);
            if (foodStock > 0 || subFarm[@"foodStock"] != nil) {
                self.lastManorFoodStock = foodStock;
            }
            if (foodStockLimit > 0) {
                self.lastManorFoodStockLimit = foodStockLimit;
            }
            
            NSInteger foodInTrough = 0;
            if (subFarm[@"foodInTrough"]) {
                foodInTrough = [subFarm[@"foodInTrough"] integerValue];
            }
            NSInteger foodLimit = [subFarm[@"foodInTroughLimit"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"foodInTroughLimit"] integerValue] : 180;
            NSInteger countdown = [subFarm[@"countdown"] respondsToSelector:@selector(integerValue)] ? [subFarm[@"countdown"] integerValue] : 0;
            
            // 真实判定：食盆余粮满了，或者倒计时大于0且盆内有粮，才算真正进食中
            BOOL isEating = (foodInTrough >= foodLimit) || (countdown > 0 && foodInTrough > 0);
            self.isManorChickenEating = isEating;
            
            if (isEating) {
                NSInteger hours = countdown / 3600;
                NSInteger minutes = (countdown % 3600) / 60;
                NSInteger seconds = countdown % 60;
                NSLog(@"🐔 [蚂蚁庄园·小鸡状态] 正在进食中 | 盆内:%ld/%ldg | 倒计时:%02ld:%02ld:%02ld | 饲料存量:%ldg", (long)foodInTrough, (long)foodLimit, (long)hours, (long)minutes, (long)seconds, (long)foodStock);
                
                static NSTimeInterval lastEatLogTime = 0;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - lastEatLogTime > 30) {
                    lastEatLogTime = now;
                    if (countdown > 0) {
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡正在进食中（盆内余粮 %ldg / 倒计时 %02ld:%02ld:%02ld / 背包存量 %ldg），暂无需喂食", (long)foodInTrough, (long)hours, (long)minutes, (long)seconds, (long)foodStock]];
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡正在进食中（背包存量 %ldg），暂无需喂食", (long)foodStock]];
                    }
                }
            } else if (manorChickenSleeping()) {
                NSLog(@"🐔 [蚂蚁庄园·小鸡状态] 小鸡在睡觉，不投喂 | 盆内:%ld/%ldg | 饲料存量:%ldg", (long)foodInTrough, (long)foodLimit, (long)foodStock);
            } else {
                NSLog(@"🐔 [蚂蚁庄园·小鸡状态] 饭盆空闲 | 盆内:%ld/%ldg | 饲料存量:%ldg", (long)foodInTrough, (long)foodLimit, (long)foodStock);
                if (foodStock >= 180) {
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：检测到小鸡饭盆空闲（盆内 %ldg / 背包存量 %ldg），正在自动投喂（优先高级饲料）...", (long)foodInTrough, (long)foodStock]];
                    [self feedManorChickenWithAdvancedFood];
                } else if (foodStock > 0) {
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：检测到小鸡饭盆空闲，背包存量不足 180g（当前 %ldg），尝试投喂（优先高级饲料）...", (long)foodStock]];
                    [self feedManorChickenWithAdvancedFood];
                } else {
                    [self recordStage:@"蚂蚁庄园：小鸡饭盆空闲，但背包饲料存量为 0g，需先做任务赚饲料"];
                }
            }
            
            NSDictionary *manureVO = [subFarm[@"manureVO"] isKindOfClass:NSDictionary.class] ? subFarm[@"manureVO"] : nil;
            if (manureVO) {
                NSArray *potList = manureVO[@"manurePotList"];
                for (NSDictionary *pot in potList) {
                    if ([pot isKindOfClass:NSDictionary.class]) {
                        NSString *potNo = pot[@"manurePotNO"];
                        NSInteger potNum = [pot[@"manurePotNum"] integerValue];
                        if (potNo.length && potNum >= 100) {
                            [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：打扫鸡屎/肥料（罐内 %ldg），正在自动收取...", (long)potNum]];
                            [self collectManorChickenManurePot:potNo];
                        }
                    }
                }
            }
        }
        
        // B. 每日连续签到 (signList)
        NSDictionary *signDict = [resData[@"signList"] isKindOfClass:NSDictionary.class] ? resData[@"signList"] : ([dict[@"signList"] isKindOfClass:NSDictionary.class] ? dict[@"signList"] : nil);
        if (signDict) {
            NSArray *signs = [signDict[@"signList"] isKindOfClass:NSArray.class] ? signDict[@"signList"] : nil;
            NSString *today = getCurrentDateString();
            BOOL todaySigned = NO;
            NSInteger contDays = 0;
            NSInteger award = 180;
            for (NSDictionary *s in signs) {
                if ([s isKindOfClass:NSDictionary.class]) {
                    if ([s[@"signKey"] isEqualToString:today]) {
                        todaySigned = [s[@"signed"] boolValue];
                        award = [s[@"awardCount"] integerValue] ?: 180;
                    }
                    if (s[@"currentContinuousCount"]) {
                        contDays = [s[@"currentContinuousCount"] integerValue];
                    }
                }
            }
            if (todaySigned) {
                static NSString *lastLoggedSignKey = nil;
                if (![lastLoggedSignKey isEqualToString:today]) {
                    lastLoggedSignKey = [today copy];
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：今日已连续签到（已连签 %ld 天），已稳拿 %ldg 饲料", (long)contDays, (long)award]];
                    [[NSUserDefaults standardUserDefaults] setObject:today forKey:@"lastManorSignDate"];
                }
            } else {
                [self signManorDaily];
            }
        }
        
        // C. 任务列表解析与驱动 (farmTaskList)
        NSArray *taskList = [resData[@"farmTaskList"] isKindOfClass:NSArray.class] ? resData[@"farmTaskList"] : ([dict[@"farmTaskList"] isKindOfClass:NSArray.class] ? dict[@"farmTaskList"] : nil);
        if (taskList.count > 0) {
            // 抽抽乐任务列表（taskSceneCode 含 DRAW_TASK）走独立链路，不混进庄园食物链
            if (isManorDrawTaskList(taskList)) {
                [self handleManorDrawTaskList:taskList];
            } else {
                [self handleManorTaskList:taskList];
            }
        }
        
        // D. 气泡检查 (bubbleConfig)
        id bubbleConfig = resData[@"bubbleConfig"] ?: dict[@"bubbleConfig"];
        if ([bubbleConfig isKindOfClass:NSDictionary.class]) {
            NSString *bubbleType = bubbleConfig[@"bubbleType"];
            if ([bubbleType isEqualToString:@"NEW_DAILY_MANURE"]) {
                NSDictionary *dailyManure = [resData[@"dailyManure"] isKindOfClass:NSDictionary.class] ? resData[@"dailyManure"] : ([dict[@"dailyManure"] isKindOfClass:NSDictionary.class] ? dict[@"dailyManure"] : nil);
                BOOL canCollect = dailyManure ? [dailyManure[@"canCollect"] boolValue] : YES;
                NSString *today = getCurrentDateString();
                if (!canCollect) {
                    self.lastManorManureCollectDate = today;
                    NSLog(@"🐔 [蚂蚁庄园] 小鸡今日肥料已全部领取完毕 (canCollect=NO)");
                } else if (![self.lastManorManureCollectDate isEqualToString:today]) {
                    [self recordStage:@"蚂蚁庄园：检测到小鸡已拉出农场肥料，正在自动收取..."];
                    [self collectManorChickenManure];
                }
            }
        }
        
        // E. 领饲料奖励回包处理 (receiveFarmTaskAward)
        id respOpRaw = [dict[@"operationType"] isKindOfClass:NSString.class] ? dict[@"operationType"] : ([resData[@"operationType"] isKindOfClass:NSString.class] ? resData[@"operationType"] : nil);
        NSString *opType = respOpRaw ?: @"";
        if (opType.length) {
            manorRemovePendingOp(opType);
        } else {
            NSString *assocOp = manorPopPendingOp();
            if (assocOp.length) {
                opType = assocOp;
                self.lastRpcOperationType = assocOp;
            }
        }
        if (!gManorFamilySignPending && (resData[@"haveAddFoodStock"] || [opType containsString:@"receiveFarmTaskAward"])) {
            NSInteger addFood = [resData[@"haveAddFoodStock"] integerValue];
            NSInteger curFood = [resData[@"foodStock"] integerValue];
            if (addFood > 0) {
                if (curFood > 0) self.lastManorFoodStock = curFood;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：成功领取饲料 +%ldg（背包存量 %ldg）", (long)addFood, (long)(curFood > 0 ? curFood : self.lastManorFoodStock)]];
            } else if ([resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"]) {
                if (curFood > 0) self.lastManorFoodStock = curFood;
                [self recordStage:@"蚂蚁庄园：成功领取饲料奖励"];
            }
        }
        
        // G. 投喂小鸡回包处理 (feedAnimal)
        if ([opType containsString:@"feedAnimal"] && ([resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] || [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"] || resData[@"foodStock"] != nil)) {
            self.isManorChickenEating = YES;
            gWatchFeedOk++;   // 投喂成功逐次记录（不封顶）
            NSInteger curFood = [resData[@"foodStock"] integerValue];
            if (curFood > 0 || resData[@"foodStock"] != nil) {
                NSInteger prevFood = self.lastManorFoodStock;
                self.lastManorFoodStock = curFood;
                NSInteger fed = (prevFood > curFood && prevFood > 0) ? (prevFood - curFood) : 180;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡投喂成功（消耗 %ldg 饲料，背包剩余 %ldg）", (long)fed, (long)curFood]];
            } else {
                [self recordStage:@"蚂蚁庄园：小鸡投喂成功（已倒入 180g 饲料）"];
            }
        }

        // G2. 普通饲料被「小鸡在睡觉」拒：同样立 5 分钟静默闸门（睡醒前不再发投喂请求）
        if ([opType containsString:@"feedAnimal"]) {
            NSString *feedMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: (dict[@"memo"] ?: @"")];
            if (isManorSleepMemo(feedMemo)) {
                gManorChickenSleepUntil = [[NSDate date] timeIntervalSince1970] + kManorChickenSleepQuiet;
                recordEggDiagOnce(self, @"cuisine_sleep",
                                  [NSString stringWithFormat:@"蚂蚁庄园：小鸡在睡觉，暂不投喂饲料（%@）", manorCnReason(feedMemo)]);
            }
        }

        // H. 去睡觉回包处理 (sleep)：以服务端回执为准标记当天已完成
        if ([opType containsString:@"antfarm.sleep"]) {
            NSString *sleepMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: (dict[@"memo"] ?: @"")];
            BOOL sleepOk = [resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] ||
                           [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"] ||
                           [resData[@"success"] boolValue] || [dict[@"success"] boolValue];
            if (sleepOk) {
                markManorSleepDone();
                gManorSleepPending = NO;
                gManorSleepInFlightVariant = -1;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡已在家庭别墅睡着（今日完成，口径 %ld）", (long)(manorSleepPreferredVariant() + 1)]];
            } else if ([sleepMemo containsString:@"已经睡"] || [sleepMemo containsString:@"睡觉中"]) {
                markManorSleepDone();
                gManorSleepPending = NO;
                gManorSleepInFlightVariant = -1;
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡已经在睡觉了（%@）", sleepMemo]];
            } else {
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：小鸡暂时睡不着（%@），自动换下一组口径", sleepMemo.length ? sleepMemo : @"未知原因"]];
            }
        }

        // H2. 抽抽乐回包处理：查次数决定是否连抽 / 连抽结果落账
        [self handleManorDrawMachineResponse:opType resData:resData dict:dict];

        // I. 家庭签到回包处理：以服务端回执为准标记当天已完成
        if (gManorFamilySignPending && [opType containsString:@"receiveFarmTaskAward"]) {
            gManorFamilySignPending = NO;
            NSString *fsMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: (dict[@"memo"] ?: @"")];
            BOOL fsOk = [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
                        [resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] ||
                        [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"];
            if (fsOk) {
                markManorFamilySignDone();
                [self recordStage:@"☑️ 家庭签到成功（+亲密值）"];
                [self syncManorFamilyStatusAndAnimal];
            } else if ([fsMemo containsString:@"已签到"] || [fsMemo containsString:@"重复"] ||
                       [fsMemo containsString:@"已领取"] || [fsMemo containsString:@"签到过"]) {
                markManorFamilySignDone();
                [self recordStage:@"☑️ 家庭签到已签到（今日完成）"];
            } else {
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：家庭签到未成功（%@），下次自动重试", fsMemo.length ? fsMemo : @"未知原因"]];
            }
        }

        // J. 赶走访客回包处理 (sendBackAnimal)：以服务端回执为准输出结果
        if ([opType containsString:@"sendBackAnimal"]) {
            NSString *expelMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: (dict[@"memo"] ?: @"")];
            BOOL expelOk = [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
                           [resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] ||
                           [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"];
            NSString *tailSuffix = gLastExpelledTail.length ? [NSString stringWithFormat:@"（访客尾号 %@）", gLastExpelledTail] : @"";
            if (expelOk) {
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：已赶走一只偷吃的小鸡%@（服务端已确认）", tailSuffix]];
            } else {
                [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：赶走小鸡未成功%@（%@），下次自动重试", tailSuffix, expelMemo.length ? expelMemo : @"未知原因"]];
            }
            gLastExpelledTail = nil;
        }
        
        // K. 链外补跑：庄园页面停留期间每来一条回包都顺带体检睡觉/家庭签到
        //    （两者各有「当天一次」标记 + 30 分钟冷却，重复调用不会刷请求）
        [self retryManorPendingAutomations];

        // L. 收鸡蛋回包处理 (harvestProduce)：服务端确认收到蛋才输出日志，蛋巢无蛋被回绝则静默
        if ([opType containsString:@"harvestProduce"]) {
            BOOL eggOk = [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
                         [resData[@"memo"] isEqualToString:@"SUCCESS"] || [dict[@"memo"] isEqualToString:@"SUCCESS"] ||
                         [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"];
            if (eggOk) {
                gWatchEggOk++;   // 收到蛋逐次记录（不封顶）
                [self recordStage:@"蚂蚁庄园：已收取小鸡下的鸡蛋（蛋巢已刷新）"];
                NSString *eggFarmId = self.lastManorFarmId ?: @"";
                if (eggFarmId.length) {
                    NSString *eggTs = [NSString stringWithFormat:@"%ld", (long)([[NSDate date] timeIntervalSince1970] * 1000)];
                    NSString *syncArg = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"com.alipay.antfarm.syncAnimalStatus\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"%@\",\"ags-source\":\"%@\"},\"requestData\":[{\"farmId\":\"%@\",\"operTag\":\"SYNC_RESUME\",\"operType\":\"QUERY_ALL\",\"recall\":false,\"requestType\":\"NORMAL\",\"sceneCode\":\"ANTFARM\",\"source\":\"H5\",\"version\":\"%@\"}],\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]", kManorEggRPCSource, kManorEggRPCSource, eggFarmId, kManorEggRPCVersion, eggTs, [AntForestManager getNumberRandom:15]];
                    PSDJsBridge *eggBridge = [self activeManorBridge];
                    if (eggBridge) manorSendRPC(eggBridge, syncArg, [self manorRPCUrlString]);
                }
            } else {
                NSString *eggMemo = resData[@"memo"] ?: dict[@"memo"];
                if (![eggMemo isKindOfClass:NSString.class]) eggMemo = nil;
                NSString *eggReason = eggMemo.length ? eggMemo : @"未知原因";
                recordEggDiagOnce(self, @"noegg", [NSString stringWithFormat:@"蚂蚁庄园：蛋巢暂无可收鸡蛋（%@），下次自动重试", eggReason]);
            }
        }
        
        // M. 高级饲料投喂回包处理 (useFarmFood)：成功 → 1.2 秒后继续喂下一个；喂不动/喂完 → 转普通饲料兜底
        if ([opType containsString:@"useFarmFood"]) {
            if (gManorCuisineInFlight) {
                gManorCuisineInFlight = NO;
                id cuisineMemoRaw = resData[@"memo"] ?: dict[@"memo"];
                NSString *cuisineMemo = [cuisineMemoRaw isKindOfClass:NSString.class] ? cuisineMemoRaw : @"";
                BOOL cuisineOk = [resData[@"success"] boolValue] || [dict[@"success"] boolValue] ||
                                 [resData[@"resultCode"] isEqualToString:@"100"] || [dict[@"resultCode"] isEqualToString:@"100"] ||
                                 [cuisineMemo containsString:@"SUCCESS"] || [cuisineMemo containsString:@"成功"];
                if (cuisineOk && isManorCuisineSkipMemo(cuisineMemo)) cuisineOk = NO;
                if (cuisineOk) {
                    gManorCuisineFedCount++;
                    NSInteger cuisineLeft = [self consumeManorCuisineStock:gManorCuisineInFlightId];
                    [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料投喂成功（第 %lu 个，%@ 还剩 %ld 个）", (unsigned long)gManorCuisineFedCount, gManorCuisineInFlightId, (long)cuisineLeft]];
                    if (gManorCuisineFedCount >= 15) {
                        [self stopManorAdvancedFoodFeed:@"已连喂 15 个，达单轮上限" silent:NO];
                    } else {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                            [self feedManorChickenWithAdvancedFood];
                        });
                    }
                } else if (isManorSleepMemo(cuisineMemo)) {
                    [self stopManorAdvancedFoodFeed:(cuisineMemo.length ? cuisineMemo : @"我的小鸡在睡觉中，无法操作") silent:NO];
                } else if (isManorCuisineEmptyMemo(cuisineMemo)) {
                    // 服务端说这个菜谱没库存：记进「今天不再试」名单，静默换下一个（有就投喂、没有就跳过）
                    NSString *emptyId = gManorCuisineInFlightId;
                    if (emptyId.length) {
                        manorLoadCuisineStock();
                        manorLoadCuisineEmptyIds();
                        [gManorCuisineEmptyIds addObject:emptyId];
                        [gManorCuisineStock removeObjectForKey:emptyId];
                        gManorCuisineRoundSkip++;
                        manorSaveCuisineEmptyIds();
                        manorSaveCuisineStock();
                    }
                    if (manorNextCuisineToFeed(manorAdvancedCuisineList())) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                            [self feedManorChickenWithAdvancedFood];
                        });
                    } else {
                        recordEggDiagOnce(self, @"cuisine_empty", @"蚂蚁庄园：识别到的菜谱都判过无库存，高级饲料本轮跳过（做出新菜谱会自动重试）");
                        [self stopManorAdvancedFoodFeed:@"识别到的菜谱今天都没库存" silent:YES];
                    }
                } else if (isManorCuisineSkipMemo(cuisineMemo) || [cuisineMemo containsString:@"正在吃"]) {
                    [self stopManorAdvancedFoodFeed:(cuisineMemo.length ? cuisineMemo : @"小鸡正在吃，暂不需要") silent:NO];
                } else {
                    NSString *why = manorCnReason(cuisineMemo.length ? cuisineMemo : @"高级饲料不可用");
                    if (gManorCuisineInFlightId.length) [gManorCuisineBadIds addObject:gManorCuisineInFlightId];
                    manorNoteCuisineFail(gManorCuisineInFlightId, why);
                    if (manorNextCuisineToFeed(manorAdvancedCuisineList())) {
                        [self recordStage:[NSString stringWithFormat:@"蚂蚁庄园：高级饲料 %@ 被服务端拒（%@），换下一个菜谱", gManorCuisineInFlightId, why]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1200 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                            [self feedManorChickenWithAdvancedFood];
                        });
                    } else {
                        [self stopManorAdvancedFoodFeed:[NSString stringWithFormat:@"%@（可喂菜谱都被拒了）", why] silent:NO];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort] Exception in handleManorResponse: %@", e);
    }
}

static void extractFarmTasksRecursive(id obj, int depth, NSMutableArray *outTasks) {
    if (depth > 6 || !obj || outTasks.count >= 150) return;
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        for (id child in arr) {
            if ([child isKindOfClass:NSDictionary.class]) {
                NSDictionary *d = (NSDictionary *)child;
                if (d[@"ongoing"] && ![d[@"ongoing"] boolValue]) {
                    // 限时挑战步骤未解锁，跳过此步骤及其下所有子任务
                    continue;
                }
                if (d[@"taskBaseInfo"] && [d[@"taskBaseInfo"] isKindOfClass:NSDictionary.class]) {
                    if (![outTasks containsObject:d]) {
                        [outTasks addObject:d];
                    }
                } else if (d[@"taskType"] || d[@"taskId"] || d[@"iepTaskId"] || d[@"deliveryId"] ||
                    (d[@"actionType"] && (d[@"awardCount"] || d[@"bizInfo"] || d[@"awardNum"] || d[@"taskDisplayConfig"]))) {
                    if (![outTasks containsObject:d]) {
                        [outTasks addObject:d];
                    }
                }
                extractFarmTasksRecursive(d, depth + 1, outTasks);
            } else if ([child isKindOfClass:NSArray.class]) {
                extractFarmTasksRecursive(child, depth + 1, outTasks);
            }
        }
    } else if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        if (d[@"ongoing"] && ![d[@"ongoing"] boolValue]) {
            // 限时挑战未解锁分组/步骤，跳过
            return;
        }
        [d enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            if (!val || val == (id)kCFNull) return;
            if ([val isKindOfClass:NSDictionary.class] || [val isKindOfClass:NSArray.class]) {
                extractFarmTasksRecursive(val, depth + 1, outTasks);
            }
        }];
    }
}

- (void)handleFarmResponse:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return;
    @try {
        initDailyTaskCache();
        NSDictionary *data = dict;
        if (data[@"resData"] && [data[@"resData"] isKindOfClass:NSDictionary.class]) {
            data = data[@"resData"];
        }
        
        // 打印顶层主要特征 Key
        NSMutableArray<NSString *> *topKeys = [NSMutableArray array];
        for (id k in dict.allKeys) {
            if ([k isKindOfClass:NSString.class]) [topKeys addObject:k];
        }
        NSLog(@"🌾 [芭芭农场·回包探针] 顶层Keys: [%@]", [topKeys componentsJoinedByString:@", "]);
        
        NSString *memo = [NSString stringWithFormat:@"%@", dict[@"memo"] ?: (dict[@"resultDesc"] ?: (data[@"memo"] ?: (data[@"resultDesc"] ?: @"")))];
        NSString *resCode = [NSString stringWithFormat:@"%@", dict[@"resultCode"] ?: (dict[@"code"] ?: (data[@"resultCode"] ?: (data[@"code"] ?: @"")))];
        if ([resCode isEqualToString:@"WateringTimeLimitError"] || [memo containsString:@"施肥次数已经用完"]) {
            [self recordStage:@"芭芭农场：今日施肥次数已达上限，明日再来"];
        }
        
        // 1. 小鸡肥料探测与处理
        NSDictionary *factory = [data[@"manureFactory"] isKindOfClass:NSDictionary.class] ? data[@"manureFactory"] : ([dict[@"manureFactory"] isKindOfClass:NSDictionary.class] ? dict[@"manureFactory"] : nil);
        if ([factory isKindOfClass:NSDictionary.class]) {
            BOOL canCollect = [factory[@"canCollect"] respondsToSelector:@selector(boolValue)] ? [factory[@"canCollect"] boolValue] : NO;
            NSDictionary *manure = [factory[@"manure"] isKindOfClass:NSDictionary.class] ? factory[@"manure"] : nil;
            NSArray *potList = [manure[@"manurePotList"] isKindOfClass:NSArray.class] ? manure[@"manurePotList"] : ([data[@"manurePotList"] isKindOfClass:NSArray.class] ? data[@"manurePotList"] : nil);
            NSInteger totalManure = 0;
            for (NSDictionary *pot in potList) {
                if ([pot isKindOfClass:NSDictionary.class]) {
                    totalManure += [pot[@"manurePotNum"] respondsToSelector:@selector(integerValue)] ? [pot[@"manurePotNum"] integerValue] : 0;
                }
            }
            NSInteger displayManure = totalManure > 1000 ? (totalManure / 1000) : totalManure;
            NSLog(@"🌾 [芭芭农场·小鸡肥料] 状态:【%@】| 可收肥料: %ld 肥 | 肥料锅数: %lu", canCollect ? @"可收取" : @"生产中", (long)displayManure, (unsigned long)potList.count);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：庄园小鸡肥料状态【%@】，可收取约 %ld 肥", canCollect ? @"可领取" : @"生产中/未满", (long)displayManure]];
            
            if (canCollect && self.enableAutoFarmTasks) {
                [self collectFarmChickenManure];
            }
        }
        
        // 2. 连续签到探测与处理
        NSDictionary *signInfo = [data[@"signTaskInfo"] isKindOfClass:NSDictionary.class] ? data[@"signTaskInfo"] : ([dict[@"signTaskInfo"] isKindOfClass:NSDictionary.class] ? dict[@"signTaskInfo"] : nil);
        if ([signInfo isKindOfClass:NSDictionary.class]) {
            NSInteger contCount = [signInfo[@"continuousCount"] respondsToSelector:@selector(integerValue)] ? [signInfo[@"continuousCount"] integerValue] : 0;
            NSArray *list = [signInfo[@"list"] isKindOfClass:NSArray.class] ? signInfo[@"list"] : nil;
            NSLog(@"🌾 [芭芭农场·连续签到] 已连续签到 %ld 天，周期列表 %lu 项", (long)contCount, (unsigned long)list.count);
            for (NSUInteger i = 0; i < list.count; i++) {
                NSDictionary *sItem = list[i];
                if (![sItem isKindOfClass:NSDictionary.class]) continue;
                NSString *signKey = [sItem[@"signKey"] isKindOfClass:NSString.class] ? sItem[@"signKey"] : @"";
                BOOL signedToday = [sItem[@"signed"] respondsToSelector:@selector(boolValue)] ? [sItem[@"signed"] boolValue] : NO;
                id awardCount = sItem[@"awardCount"] ?: sItem[@"awardDesc"] ?: @"奖励";
                NSLog(@"🌾 [农场签到 %lu/%lu] 日期: %@ | 状态: %@ | 奖励: %@", (unsigned long)(i+1), (unsigned long)list.count, signKey, signedToday ? @"已签" : @"待签", awardCount);
                
                NSString *todayStr = getCurrentDateString();
                if (!signedToday && ([signKey isEqualToString:todayStr] || i == contCount || i == 0)) {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：探测到今日连续签到（%@），正在自动签到...", signKey]];
                    if (self.enableAutoFarmTasks) {
                        [self signFarmDailyWithKey:signKey];
                    }
                }
            }
        }
        
        // 3. 淘宝农场热气球
        NSDictionary *balloon = [data[@"balloonCooper"] isKindOfClass:NSDictionary.class] ? data[@"balloonCooper"] : ([dict[@"balloonCooper"] isKindOfClass:NSDictionary.class] ? dict[@"balloonCooper"] : nil);
        if ([balloon isKindOfClass:NSDictionary.class]) {
            NSString *status = [balloon[@"status"] isKindOfClass:NSString.class] ? balloon[@"status"] : @"";
            NSString *actId = [balloon[@"activityId"] isKindOfClass:NSString.class] ? balloon[@"activityId"] : @"";
            NSString *awardCount = @"2400";
            id ext = balloon[@"extend"];
            if ([ext isKindOfClass:NSString.class]) {
                NSData *ed = [(NSString *)ext dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *eDict = ed ? [NSJSONSerialization JSONObjectWithData:ed options:0 error:nil] : nil;
                if ([eDict isKindOfClass:NSDictionary.class] && eDict[@"awardCount"]) awardCount = [NSString stringWithFormat:@"%@", eDict[@"awardCount"]];
            }
            NSLog(@"🌾 [芭芭农场·淘宝热气球] 活动: %@ | 状态: %@ | 奖励: %@ 肥", actId, status, awardCount);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：淘宝热气球【%@】，奖励 %@ 肥", [status isEqualToString:@"TODO"] ? @"去逛逛" : status, awardCount]];
        }
        
        // 4. 深度扫描提取任务列表（彻底杜绝单行截断与 Block 递归野指针）
        NSMutableArray *allFoundTasks = [NSMutableArray array];
        extractFarmTasksRecursive(dict, 0, allFoundTasks);
        
        // 如果发现了任务，逐条格式化打印并调度
        if (allFoundTasks.count > 0) {
            NSLog(@"🌾 [芭芭农场·任务探测] ══════════════ 共发现 %lu 个农场任务 ══════════════", (unsigned long)allFoundTasks.count);
            [self recordStage:[NSString stringWithFormat:@"芭芭农场：探测到 %lu 个任务，正在解析列表...", (unsigned long)allFoundTasks.count]];
            
            NSMutableArray<NSDictionary *> *tasksToQueue = [NSMutableArray array];
            for (NSUInteger idx = 0; idx < allFoundTasks.count; idx++) {
                id rawTask = allFoundTasks[idx];
                if (![rawTask isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *t = (NSDictionary *)rawTask;
                
                id baseInfo = [t[@"taskBaseInfo"] isKindOfClass:NSDictionary.class] ? t[@"taskBaseInfo"] : nil;
                id rawTaskType = t[@"taskType"] ?: t[@"taskId"] ?: t[@"iepTaskId"] ?: t[@"deliveryId"] ?: [baseInfo objectForKey:@"taskType"];
                if (!rawTaskType && [t[@"taobaoTaskParams"] isKindOfClass:NSDictionary.class]) {
                    rawTaskType = t[@"taobaoTaskParams"][@"deliveryId"] ?: t[@"taobaoTaskParams"][@"implId"];
                }
                NSString *taskType = @"";
                if ([rawTaskType isKindOfClass:NSString.class]) {
                    taskType = (NSString *)rawTaskType;
                } else if ([rawTaskType respondsToSelector:@selector(stringValue)]) {
                    taskType = [rawTaskType stringValue];
                }
                if ([taskType containsString:@"POP"] || [taskType containsString:@"MIGRATE"]) {
                    continue;
                }
                
                id rawScene = t[@"sceneCode"] ?: t[@"iepSceneCode"] ?: [baseInfo objectForKey:@"sceneCode"];
                if (!rawScene && [t[@"taobaoTaskParams"] isKindOfClass:NSDictionary.class]) {
                    rawScene = t[@"taobaoTaskParams"][@"sceneId"];
                }
                NSString *sceneCode = @"";
                if ([rawScene isKindOfClass:NSString.class]) {
                    sceneCode = (NSString *)rawScene;
                } else if ([rawScene respondsToSelector:@selector(stringValue)]) {
                    sceneCode = [rawScene stringValue];
                }
                if (!sceneCode.length) sceneCode = @"ANTFARM_ORCHARD_TASK_V2";
                
                NSString *taskStatus = [t[@"taskStatus"] isKindOfClass:NSString.class] ? t[@"taskStatus"] : ([t[@"status"] isKindOfClass:NSString.class] ? t[@"status"] : ([baseInfo[@"taskStatus"] isKindOfClass:NSString.class] ? baseInfo[@"taskStatus"] : @""));
                NSString *actionType = [t[@"actionType"] isKindOfClass:NSString.class] ? t[@"actionType"] : ([baseInfo[@"actionType"] isKindOfClass:NSString.class] ? baseInfo[@"actionType"] : @"");
                
                NSDictionary *displayConfig = [t[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? t[@"taskDisplayConfig"] : ([baseInfo[@"taskDisplayConfig"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskDisplayConfig"] : nil);
                
                NSString *awardCount = @"";
                id rawAward = displayConfig[@"confAwardCount"] ?: displayConfig[@"awardCount"] ?: t[@"awardCount"] ?: t[@"awardNum"] ?: [baseInfo objectForKey:@"awardCount"];
                if ([rawAward isKindOfClass:NSString.class]) {
                    awardCount = (NSString *)rawAward;
                } else if ([rawAward respondsToSelector:@selector(stringValue)]) {
                    awardCount = [rawAward stringValue];
                }
                
                NSDictionary *bizInfo = nil;
                id rawBiz = t[@"bizInfo"] ?: t[@"deliveryBenefitInfo"] ?: [baseInfo objectForKey:@"bizInfo"];
                if ([rawBiz isKindOfClass:NSDictionary.class]) {
                    bizInfo = rawBiz;
                } else if ([rawBiz isKindOfClass:NSString.class]) {
                    NSData *bd = [(NSString *)rawBiz dataUsingEncoding:NSUTF8StringEncoding];
                    if (bd) {
                        id parsed = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
                        if ([parsed isKindOfClass:NSDictionary.class]) bizInfo = parsed;
                    }
                }
                
                id rawTitle = displayConfig[@"title"] ?: bizInfo[@"taskTitle"] ?: bizInfo[@"title"] ?: t[@"title"] ?: t[@"taskTitle"] ?: [baseInfo objectForKey:@"taskTitle"] ?: taskType;
                NSString *taskTitle = [rawTitle isKindOfClass:NSString.class] ? (NSString *)rawTitle : ([rawTitle respondsToSelector:@selector(stringValue)] ? [rawTitle stringValue] : @"");
                if (!taskTitle.length) taskTitle = taskType;
                NSDictionary *taskRights = [t[@"taskRights"] isKindOfClass:NSDictionary.class] ? t[@"taskRights"] : ([baseInfo[@"taskRights"] isKindOfClass:NSDictionary.class] ? baseInfo[@"taskRights"] : nil);
                NSInteger rTimes = [taskRights[@"rightsTimes"] integerValue];
                if (rTimes <= 0 && t[@"rightsTimes"]) rTimes = [t[@"rightsTimes"] integerValue];
                if (rTimes <= 0 && baseInfo[@"rightsTimes"]) rTimes = [baseInfo[@"rightsTimes"] integerValue];
                NSInteger rLimit = [taskRights[@"rightsTimesLimit"] integerValue];
                if (rLimit <= 0 && t[@"rightsTimesLimit"]) rLimit = [t[@"rightsTimesLimit"] integerValue];
                if (rLimit <= 0 && baseInfo[@"rightsTimesLimit"]) rLimit = [baseInfo[@"rightsTimesLimit"] integerValue];
                if (rLimit > 1 && ![taskTitle containsString:@"/"]) {
                    taskTitle = [NSString stringWithFormat:@"%@ (%ld/%ld)", taskTitle, (long)MIN(rTimes + 1, rLimit), (long)rLimit];
                }
                
                id rawBtn = displayConfig[@"todoBtn"] ?: displayConfig[@"completeBtn"] ?: displayConfig[@"finishedBtn"] ?: bizInfo[@"taskJumpBtn"] ?: t[@"btnText"] ?: t[@"buttonText"] ?: t[@"actionText"] ?: @"";
                NSString *taskJumpBtn = [rawBtn isKindOfClass:NSString.class] ? (NSString *)rawBtn : ([rawBtn respondsToSelector:@selector(stringValue)] ? [rawBtn stringValue] : @"");
                NSString *awardDesc = awardCount.length ? [NSString stringWithFormat:@"%@肥", awardCount] : @"肥料奖励";
                
                NSLog(@"🌾 [农场任务 %lu/%lu] 标题:【%@】| 标识: %@ | 状态: %@ | 按钮:【%@】| 奖励: %@",
                      (unsigned long)(idx + 1), (unsigned long)allFoundTasks.count,
                      taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc);
                
                [self recordProbeLog:[NSString stringWithFormat:@"[芭芭农场 %lu/%lu] 标题:%@ | 标识:%@ | 状态:%@ | 按钮:%@ | 奖励:%@",
                                      (unsigned long)(idx + 1), (unsigned long)allFoundTasks.count,
                                      taskTitle, taskType, taskStatus, taskJumpBtn, awardDesc]];
                
                if (!self.enableAutoFarmTasks) continue;
                
                BOOL isContainer = ([t[@"childTaskList"] isKindOfClass:NSArray.class] && [(NSArray *)t[@"childTaskList"] count] > 0) ||
                                   ([t[@"subTaskList"] isKindOfClass:NSArray.class] && [(NSArray *)t[@"subTaskList"] count] > 0);
                
                NSString *taskKey = [NSString stringWithFormat:@"%@:%@", sceneCode, taskType];
                BOOL isMulti = [actionType isEqualToString:@"MULTI_STAGE"] || (rLimit > 1 && rTimes < rLimit) || isMultiStageIncompleteTask(taskTitle, 0, 0) || isMultiStageTaskFromDict(t, nil, bizInfo ?: displayConfig);
                
                if (isMulti || [taskType containsString:@"FLOATBALL"] || [taskType containsString:@"ncly"] || [taskTitle containsString:@"玩一玩"]) {
                    @synchronized(self) {
                        if ([gDailyFailedTasks containsObject:taskKey]) {
                            [gDailyFailedTasks removeObject:taskKey];
                        }
                        if ([gDailyCompletedTasks containsObject:taskKey]) {
                            [gDailyCompletedTasks removeObject:taskKey];
                        }
                        saveDailyTaskCache();
                    }
                }
                
                if ([taskStatus isEqualToString:@"RECEIVED"]) {
                    @synchronized(self) {
                        if (taskKey.length) {
                            [gDailyCompletedTasks addObject:taskKey];
                            if (gFarmTaskRetryCounts[taskKey]) {
                                [gFarmTaskRetryCounts removeObjectForKey:taskKey];
                            }
                            saveDailyTaskCache();
                        }
                    }
                    continue;
                }
                
                BOOL canClaim = [taskStatus isEqualToString:@"FINISHED"] ||
                                [taskStatus isEqualToString:@"CAN_RECEIVE"] ||
                                (([taskJumpBtn containsString:@"领"] && ![taskJumpBtn containsString:@"去领"] && ![taskJumpBtn containsString:@"去逛"]) && ![taskStatus isEqualToString:@"RECEIVED"]);
                
                if (canClaim) {
                    @synchronized(self) {
                        if ([gDailyCompletedTasks containsObject:taskKey]) [gDailyCompletedTasks removeObject:taskKey];
                        if ([gDailyFailedTasks containsObject:taskKey]) [gDailyFailedTasks removeObject:taskKey];
                        if (gFarmTaskRetryCounts[taskKey]) {
                            [gFarmTaskRetryCounts removeObjectForKey:taskKey];
                        }
                        saveDailyTaskCache();
                    }
                    [tasksToQueue addObject:@{
                        @"action": @"receive",
                        @"taskType": taskType,
                        @"sceneCode": sceneCode,
                        @"title": taskTitle,
                        @"awardName": awardDesc,
                        @"scenePrefix": @"芭芭农场",
                        @"isMultiStage": @(isMulti),
                        @"stageIndex": @(rTimes)
                    }];
                } else if (!isContainer &&
                           ![actionType isEqualToString:@"SPREAD_MANURE"] &&
                           ![actionType isEqualToString:@"ANTFARM_COLLECT_MANURE"] &&
                           ![taskType isEqualToString:@"ANTFARM_COLLECT_MANURE"] &&
                           ([taskStatus isEqualToString:@"TODO"] || [taskStatus isEqualToString:@"INIT"] || [taskStatus isEqualToString:@"SIGN"])) {
                    BOOL isSafe = isSafeFarmTask(taskType, taskTitle);
                    if (isSafe) {
                        NSString *retryKey = isMulti ? [NSString stringWithFormat:@"%@:stage_%ld", taskKey, (long)rTimes] : taskKey;
                        @synchronized(self) {
                            if (!isMulti && [gDailyFailedTasks containsObject:taskKey]) {
                                continue;
                            }
                            NSInteger retries = [gFarmTaskRetryCounts[retryKey] integerValue];
                            if (retries >= 3) {
                                NSLog(@"🌾 [芭芭农场] 任务【%@】(%@) 已经尝试执行 %ld 次但服务端仍未完成，可能需要真实端内页面交互，自动标记跳过避免死循环", taskTitle, retryKey, (long)retries);
                                [self recordStage:[NSString stringWithFormat:@"芭芭农场：“%@”需在界面手动完成（服务端要求真实浏览，已跳过）", taskTitle]];
                                if (!isMulti) {
                                    [gDailyFailedTasks addObject:taskKey];
                                    saveDailyTaskCache();
                                }
                                continue;
                            }
                            if (!isMulti && [gDailyCompletedTasks containsObject:taskKey] && ![taskStatus isEqualToString:@"TODO"]) {
                                continue;
                            }
                        }
                        NSInteger seconds = extractTaskBrowseSeconds(t, displayConfig ?: bizInfo, taskTitle);
                        if (seconds <= 0) seconds = 15;
                        id rawJump = displayConfig[@"targetUrl"] ?: bizInfo[@"targetUrl"] ?: bizInfo[@"jumpUrl"] ?: t[@"targetUrl"] ?: t[@"jumpUrl"];
                        NSString *jumpUrl = [rawJump isKindOfClass:NSString.class] ? (NSString *)rawJump : @"";
                        [tasksToQueue addObject:@{
                            @"action": @"browse",
                            @"taskType": taskType,
                            @"sceneCode": sceneCode,
                            @"title": taskTitle,
                            @"awardName": awardDesc,
                            @"browseSeconds": @(seconds),
                            @"jumpUrl": jumpUrl,
                            @"scenePrefix": @"芭芭农场",
                            @"isMultiStage": @(isMulti),
                            @"stageIndex": @(rTimes)
                        }];
                    }
                }
            }
            
            if (tasksToQueue.count > 0) {
                BOOL shouldStart = NO;
                @synchronized(self) {
                    if (!vitalityTaskQueue) vitalityTaskQueue = [NSMutableArray array];
                    for (NSDictionary *task in tasksToQueue) {
                        NSString *tk = [NSString stringWithFormat:@"%@:%@:%@", task[@"sceneCode"], task[@"taskType"], task[@"action"]];
                        BOOL already = NO;
                        for (NSDictionary *q in vitalityTaskQueue) {
                            NSString *qk = [NSString stringWithFormat:@"%@:%@:%@", q[@"sceneCode"], q[@"taskType"], q[@"action"]];
                            if ([qk isEqualToString:tk]) { already = YES; break; }
                        }
                        if (!already) [vitalityTaskQueue addObject:task];
                    }
                    if (!vitalityTaskRunning && vitalityTaskQueue.count > 0) {
                        vitalityTaskRunning = YES;
                        shouldStart = YES;
                    }
                }
                if (shouldStart) {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：规划 %lu 项待完成与领肥料操作", (unsigned long)tasksToQueue.count]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                        [self executeNextVitalityTask];
                    });
                } else {
                    [self recordStage:[NSString stringWithFormat:@"芭芭农场：已追加 %lu 项肥料任务至执行队列", (unsigned long)tasksToQueue.count]];
                }
            } else {
                if (allFoundTasks.count > 0) {
                    NSLog(@"[AntForestPort] 芭芭农场：当前所有任务奖励已全部领取完毕");
                }
            }
        }
        
        // 5. 自动在 Web 页面上领取当前所有可见的“领取”按钮
        if (self.enableAutoFarmTasks) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self claimAllVisibleFarmRewardsOnWebView];
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[AntForestPort][FarmTask] Exception in handleFarmResponse: %@", e);
    }
}

    


static NSMutableArray<NSString *> *oceanQueue = nil;
static NSString *oceanCurrentUserId = nil;
static BOOL oceanRunning = NO;
static NSUInteger oceanRequestToken = 0;
static NSUInteger oceanCleanedInCurrentRound = 0;
static const NSUInteger kOceanMaxCleanPerRound = 5;

- (void)oceanStopWithReason:(NSString *)reason {
    oceanRunning = NO;
    oceanCurrentUserId = nil;
    oceanRequestToken++;
    [oceanQueue removeAllObjects];
    if (reason.length) [self recordStage:[NSString stringWithFormat:@"神奇海洋 · %@", reason]];
}

- (void)oceanSendNext {
    if (!self.enableCleanOcean || !self.jsBridge) {
        if (oceanRunning) [self oceanStopWithReason:@"任务已停止或桥接不可用"];
        return;
    }
    
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) {
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20) {
        [defaults setBool:YES forKey:@"oceanLimitReachedToday"];
        [self recordStage:@"神奇海洋：今日已帮满 20 位好友清理，已达每日上限"];
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    if (oceanCleanedInCurrentRound >= kOceanMaxCleanPerRound) {
        [self recordStage:[NSString stringWithFormat:@"神奇海洋：本轮已成功帮助 %lu 位好友清理，稍后下轮继续", (unsigned long)oceanCleanedInCurrentRound]];
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        [oceanQueue removeAllObjects];
        return;
    }
    
    NSString *nextUid = nil;
    while (oceanQueue.count > 0) {
        NSString *candidate = oceanQueue.firstObject;
        [oceanQueue removeObjectAtIndex:0];
        if (candidate.length && ![candidate isEqualToString:self.myUserId] && ![cleanedSet containsObject:candidate]) {
            nextUid = candidate;
            break;
        }
    }
    
    if (!nextUid.length) {
        oceanRunning = NO;
        oceanCurrentUserId = nil;
        return;
    }
    
    oceanRunning = YES;
    oceanCurrentUserId = nextUid;
    NSUInteger token = ++oceanRequestToken;
    
    [self cleanFriendsOcean:nextUid];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (oceanRunning && token == oceanRequestToken) {
            oceanRunning = NO;
            oceanCurrentUserId = nil;
            double delaySec = 1.0 + (arc4random_uniform(1000) / 1000.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.enableCleanOcean) [self oceanSendNext];
            });
        }
    });
}

static BOOL oceanPlanLoggedThisRound = NO;

-(void)scanOceanForFriends:(NSArray<NSString *> *)friendIds {
    if (!self.enableCleanOcean || !friendIds.count) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        oceanQueue = [NSMutableArray array];
    });
    
    NSString *today = getCurrentDateString();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![[defaults stringForKey:@"oceanCleanedDate"] isEqualToString:today]) {
        [defaults setObject:today forKey:@"oceanCleanedDate"];
        [defaults setObject:@[] forKey:@"oceanCleanedFriendsToday"];
        [defaults setBool:NO forKey:@"oceanLimitReachedToday"];
    }
    if ([defaults boolForKey:@"oceanLimitReachedToday"]) return;
    
    NSArray *cleanedArr = [defaults arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
    NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
    if (cleanedSet.count >= 20) return;
    
    NSUInteger added = 0;
    for (NSString *uid in friendIds) {
        if (!uid.length || [uid isEqualToString:self.myUserId]) continue;
        if ([cleanedSet containsObject:uid]) continue;
        if (![oceanQueue containsObject:uid] && ![oceanCurrentUserId isEqualToString:uid]) {
            [oceanQueue addObject:uid];
            added++;
        }
    }
    
    if (!oceanRunning && oceanQueue.count > 0) {
        if (!oceanPlanLoggedThisRound) {
            oceanPlanLoggedThisRound = YES;
            [self recordStage:[NSString stringWithFormat:@"神奇海洋：今日已帮 %lu/20 位好友清理，已规划 %lu 位候选好友（安全随机间隔）", (unsigned long)cleanedSet.count, (unsigned long)oceanQueue.count]];
        }
        [self oceanSendNext];
    }
}

-(void)queryRankPage:(NSInteger)startIndex {
    if (!self.enableAutoCollect || !self.jsBridge) return;
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate date] timeIntervalSince1970]*1000];
    NSString *randNum = [AntForestManager getNumberRandom:16];
    NSString *arg1 = [NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startIndex\":%ld,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@_p%ld\"}]", version, (long)startIndex, timeStamp, randNum, (long)startIndex];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    [self recordStage:[NSString stringWithFormat:@"请求好友排行榜自动翻页（第 %ld-%ld 位）", (long)startIndex + 1, (long)startIndex + 200]];
    manorSendRPC([self jsBridge], arg1, arg2);
}

//查询总排行 可以获取所有人的ID
-(void)queryTotalRank{
    NSString *version = @"20230501";
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antmember.forest.h5.queryEnergyRanking\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"rankType\":\"energyRank\",\"periodType\":\"total\",\"version\":\"%@\",\"startNum\":1,\"startIndex\":0,\"pageSize\":200,\"contactsStatus\":\"N\",\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\",\"myself\",\"totalDatas\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",version,timeStamp,randNum];
    NSString *arg2 = @"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total";
    if([self jsBridge]) {
        [self recordStage:@"请求全量好友排行榜（200位/页）"];
        manorSendRPC([self jsBridge], arg1, arg2);
    }
}

//查询 20 个人是否有可领能量球
-(void)queryRobFlag:(NSString*)uids{
    [[AntForestManager sharedLock] lock];
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"rpc\",\"data\":{\"operationType\":\"alipay.antforest.forest.h5.fillUserRobFlag\",\"showError\":false,\"showLoading\":false,\"headers\":{\"source\":\"chInfo_ch_appcenter__chsub_9patch\",\"ags-source\":\"chInfo_ch_appcenter__chsub_9patch\"},\"requestData\":[{\"userIdList\":[%@],\"source\":\"chInfo_ch_appcenter__chsub_9patch\"}],\"relationLocal\":{\"pathList\":[\"friendRanking\"]},\"getResponse\":true},\"callbackId\":\"rpc_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"uids:%@", uids);
        //FileLog(@"anthook queryRobFlag");
    }
    double robFlagDelay = 0.15 + (arc4random_uniform(100) / 1000.0);
    [NSThread sleepForTimeInterval:robFlagDelay];
    [[AntForestManager sharedLock] unlock];
}

// 查询已存在的账户名称
-(void)queryAccount:(NSString*)uids{
    NSString *timeStamp = [NSString stringWithFormat:@"%ld",(long)[[NSDate  date] timeIntervalSince1970]*1000];
    NSString *randNum=[AntForestManager getNumberRandom:16];
    NSString *arg1=[NSString stringWithFormat:@"[{\"handlerName\":\"APSocialNebulaPlugin.queryExistingAccounts\",\"data\":{\"uids\":[%@]},\"callbackId\":\"APSocialNebulaPlugin.queryExistingAccounts_%@.%@\"}]",uids,timeStamp,randNum];
    NSString *arg2 = [NSString stringWithFormat:@"https://render.alipay.com/p/yuyan/180020010001247580/listRank.html?caprMode=sync&init=energyRank&periodType=total"];
    if([self jsBridge]) {
        manorSendRPC([self jsBridge], arg1, arg2);
        //FileLog(@"uids:%@", uids);
        //FileLog(@"anthook queryAccount");
    }
}

-(NSMutableArray*)intArrToStr:(NSArray*)arr{
    // 将每个数字转换为带双引号的字符串
    NSMutableArray *quotedIds = [NSMutableArray array];
    for (NSNumber *number in arr) {
        NSString *quotedString = [NSString stringWithFormat:@"\"%@\"", number];  // 将数字加上双引号
        [quotedIds addObject:quotedString];
    }
    return quotedIds;
}

- (void)scanRankedFriends:(NSArray *)friendIds cycle:(NSUInteger)cycle {
    if (!friendIds.count || !self.enableAutoCollect || !self.jsBridge) {
        [self recordStage:@"诊断 · 排行榜无可扫描好友，转入找能量续查"];
        [self startTakeLookContinuation];
        return;
    }
    NSUInteger groupCount = (friendIds.count + 19) / 20;
    [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜全量回包：%lu 位好友，分 %lu 组校验", (unsigned long)friendIds.count, (unsigned long)groupCount]];
    [self queryAccount:[[self intArrToStr:friendIds] componentsJoinedByString:@","]];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger index = 0; index < friendIds.count; index += 20) {
        NSRange range = NSMakeRange(index, MIN((NSUInteger)20, friendIds.count - index));
        [groups addObject:[[self intArrToStr:[friendIds subarrayWithRange:range]] componentsJoinedByString:@","]];
    }
    dispatch_async(globalSerialQueueTest, ^{
        for (NSUInteger index = 0; index < groups.count; index++) {
            if (!self.enableAutoCollect || cycle != collectionCycle) break;
            [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜校验：第 %lu/%lu 组", (unsigned long)(index + 1), (unsigned long)groups.count]];
            [self queryRobFlag:groups[index]];
            double rankGroupDelay = 0.18 + (arc4random_uniform(200) / 1000.0);
            [NSThread sleepForTimeInterval:rankGroupDelay];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.enableAutoCollect && cycle == collectionCycle) [self startTakeLookContinuation];
        });
    });
}


// 每隔300秒一次
-(void)autoCollectBubbles {
    @try {
        if (!self.enableAutoCollect || !self.jsBridge) {
            [self recordStage:[NSString stringWithFormat:@"诊断 · 收取未启动：自动收取=%d，桥接=%d", self.enableAutoCollect, self.jsBridge != nil]];
            return;
        }
        if (self.isScanRunning) {
            [self recordStage:@"诊断 · 收取跳过：本轮扫描正在执行中"];
            return;
        }
        self.isScanRunning = YES;
        oceanCleanedInCurrentRound = 0;
        oceanPlanLoggedThisRound = NO;
        lastCollectStartedAt = NSDate.date;
        collectionCycle++;
        NSUInteger cycle = collectionCycle;
        selfPriorityPending = self.enableSelfCollect;
        selfPriorityCycle = cycle;
        [deferredFriendRankIds removeAllObjects];
        deferredRankedFriendIds = nil;
        rankScanPending = YES;
        @synchronized (self) { [pendingCollectBubbles removeAllObjects]; }
        [shieldReportedFriendsInRound removeAllObjects];
        [self recordStage:@"本轮扫描开始"];
        [self queryTotalRank];
        if (self.enableCleanOcean) {
            [self cleanMyOceanThoroughly];
            [self queryOceanFriendList];
        }
        if (self.enableAutoRewardTasks) {
            [self queryVitalityTaskList];
        }
        if (selfPriorityPending) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self releaseSelfPriorityForCycle:cycle reason:@"本人首页回包超时"];
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (rankScanPending && cycle == collectionCycle) {
                rankScanPending = NO;
                [self recordStage:@"诊断 · 排行榜回包超时，转入找能量续查"];
                [self startTakeLookContinuation];
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.isScanRunning && cycle == collectionCycle) {
                self.isScanRunning = NO;
                [self recordStage:@"诊断 · 本轮扫描达到 45 秒安全超时释放锁"];
            }
        });
        self.failedTimes++;
        
    } @catch (NSException *exception) {
        // 捕获异常的代码
        //FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

// 每隔300秒一次
-(void)autoCollectBubblesV1 {
    @try {
        // 查询总排行 获取 AllFriendId MySelfUserId
        [[AntForestManager sharedInstance] queryTotalRank];
        
        // 延时 2 秒，遍历 AllFrinedID 每 20 个一组
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 查询账户名称
            NSArray *allFriendId = [[[AntForestManager sharedInstance] friendsRank] allKeys];
            NSString *alluid = [[self intArrToStr:allFriendId] componentsJoinedByString:@","];
            [[AntForestManager sharedInstance] queryAccount:alluid];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSInteger count = 0;
                NSInteger delay = 0;
                NSMutableArray *arrUid = [NSMutableArray array];  // 确保初始化 arrUid
                
                // 遍历所有好友 ID，每 20 个为一组
                for (NSNumber *userId in allFriendId) {
                    [arrUid addObject:userId];
                    count++;
                    FileLog(@"count:%ld userId:%@", (long)count, userId);
                    
                    // 每 20 个为一组，开始延时执行
                    if (count % 20 == 0) {
                        delay++;
                        FileLog(@"delay:%d", delay);
                        // 创建 arrUid 的副本，并延迟执行任务
                        NSMutableArray *groupArrUid = [arrUid mutableCopy];
                        // 延迟 3 秒执行每组的任务
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay - 1) * 3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (arrUid.count > 0) {
                                NSString *uids = [[self intArrToStr:groupArrUid] componentsJoinedByString:@","];
                                FileLog(@"uids:%@", uids);
                                // 执行查询操作
                                [[AntForestManager sharedInstance] queryRobFlag:uids];
                            }
                        });
                        
                        // 清空 arrUid 数组
                        [arrUid removeAllObjects];
                    }
                }
                //最后一组
                if([arrUid count] > 0) {
                    delay++;
                    FileLog(@"last delay:%d", delay);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay - 1)* 3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSString *uids = [[self intArrToStr:arrUid] componentsJoinedByString:@","];
                        FileLog(@"最后一组uids:%@", uids);
                        // 执行查询操作
                        [[AntForestManager sharedInstance] queryRobFlag:uids];
                        [arrUid removeAllObjects];
                    });
                }
                
                
            });
        });
        
        // 主要是更新标题 失败次数与当前时间间隔
        self.failedTimes++;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}


//自动收集能量每分钟执行一次
-(void)autoCollectBubblesOld{
    @try {
        //1.takeLook 也就是找到一个有能量球的好友 然后查询到这个人的所有能量球(queryFriendBubbles) 能收集的直接一键收集 不能收集的按 uid->bid->{} 存储到 friendBubbles 字典中
        [self takeLook];
        //延时两秒
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            //2.遍历字典树 friendBubbles 中 能领取的执行领取 领取完需要从字典树中移出
            // FileLog(@"anthook friendBubbles: %@",[[AntForestManager sharedInstance] friendsBubbles]);
            NSMutableDictionary *fb = [[AntForestManager sharedInstance] friendsBubbles];
            for(NSString *uid in fb){
                NSMutableDictionary *dict = [fb objectForKey:uid];
                for(NSString *bid in dict) {
                    NSString *overTime = [dict objectForKey:bid]; // 假设获取到的时间戳是字符串类型
                    long long overTimeValue = [overTime longLongValue];
                    // 获取当前时间的毫秒数
                    long long currentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
                    if(overTimeValue < currentTime){
                        //可以执行领取
                        NSString *friendName = [self friendDisplayNameForUser:uid];
                        NSString *targetDesc = [uid isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"拾取%@定时成熟的能量球", targetDesc]];
                        [[AntForestManager sharedInstance] collectBubbles:uid bubblesId:bid];
                        [dict removeObjectForKey:bid]; //从字典树中移除
                    } else {
                        //可以考虑做个开关是否展示 数量有点多 更新频繁
                        //NSString *log = [NSString stringWithFormat:@"%@\n能量球等待中: %@|%@",[[AntForestManager sharedInstance] getUserName:uid],bid,convertTimestampToDateString(overTimeValue)];
                        //[[AntForestManager sharedInstance] addLog:log];
                    }
                }
            }
            //主要是更新标题 失败次数与当前时间间隔
            self.failedTimes++;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
        });
    } @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

-(NSString*)getUserName:(NSString*)uid {
    @try {
        NSString *name = [self friendDisplayNameForUser:uid];
        return name ?: (uid ?: @"");
    } @catch (NSException *exception) {
        return uid ?: @"";
    }
}

- (void)addLog:(NSString *)logMessage {
    if (!logMessage.length) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self addLog:logMessage];
        });
        return;
    }
    
    NSString *cleanMessage = [logMessage stringByReplacingOccurrencesOfString:@"\n收取 · " withString:@"\n"];
    cleanMessage = [cleanMessage stringByReplacingOccurrencesOfString:@"\n收取 ·" withString:@"\n"];
    if ([cleanMessage hasPrefix:@"收取 · "]) {
        cleanMessage = [cleanMessage substringFromIndex:@"收取 · ".length];
    } else if ([cleanMessage hasPrefix:@"收取 ·"]) {
        cleanMessage = [cleanMessage substringFromIndex:@"收取 ·".length];
    }
    
    //日志持久化
    @try {
        // 保留足够的一轮扫描记录，面板仍只显示最近几条。
        NSMutableArray *arrLog = [[AntForestManager sharedInstance] logRecord];
        while(arrLog.count > 100) {
            [arrLog removeObjectAtIndex:0];
        }
        // 添加日志信息到数组中
        [arrLog addObject:cleanMessage];
        
        // 发送通知通知更新文本视图
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LogUpdated" object:nil];
        
        // 异步后台归档落盘，彻底移除主线程 synchronize 强行刷盘导致的 UI 卡顿死锁
        static dispatch_queue_t logSaveQueue = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            logSaveQueue = dispatch_queue_create("com.antforest.logsave", DISPATCH_QUEUE_SERIAL);
        });
        NSArray *copyLogs = [arrLog copy];
        dispatch_async(logSaveQueue, ^{
            @try {
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:copyLogs requiringSecureCoding:NO error:nil];
                if (data) {
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"logRecord"];
                }
            } @catch (NSException *e) {}
        });
    }
    @catch (NSException *exception) {
        // 捕获异常的代码
        FileLog(@"Exception caught: %@", exception);
        [Tool Alert:[exception description]];
    }
}

- (void)recordCollectedEnergyFromResponse:(id)args {
    if (![args isKindOfClass:NSDictionary.class] && ![args isKindOfClass:NSArray.class]) return;
    NSDictionary *rootDict = [args isKindOfClass:NSDictionary.class] ? args : nil;
    NSString *opType = [NSString stringWithFormat:@"%@", rootDict[@"operationType"] ?: @""];
    NSString *handler = [NSString stringWithFormat:@"%@", rootDict[@"handlerName"] ?: @""];
    BOOL isCollectRPC = [opType containsString:@"collect"] || 
                        [opType containsString:@"settlement"] ||
                        [opType containsString:@"revive"] ||
                        [handler containsString:@"collect"] ||
                        [handler containsString:@"settlement"];
    if (rootDict && opType.length > 0 && !isCollectRPC) return;

    NSMutableArray *pending = [NSMutableArray arrayWithObject:args];
    while (pending.count) {
        id value = pending.lastObject; [pending removeLastObject];
        if ([value isKindOfClass:NSArray.class]) { [pending addObjectsFromArray:value]; continue; }
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *bubble = value;
        for (id child in bubble.allValues) if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class]) [pending addObject:child];
        NSNumber *energy = bubble[@"collectedEnergy"];
        BOOL isAnimalEnergy = NO;
        if (!energy || energy.integerValue <= 0) {
            if (isCollectRPC && [bubble[@"energy"] respondsToSelector:@selector(integerValue)]) {
                NSInteger val = [bubble[@"energy"] integerValue];
                if (val > 0 && val <= 2000) {
                    energy = @(val);
                    isAnimalEnergy = YES;
                }
            }
        }
        if (!energy || energy.integerValue <= 0 || energy.integerValue > 2000) continue;
        NSString *userId = [bubble[@"userId"] description] ?: (self.myUserId ?: @"");
        NSString *bubbleId = [bubble[@"id"] description] ?: (isAnimalEnergy ? [NSString stringWithFormat:@"SETTLE_%ld_%ld", (long)[[NSDate date] timeIntervalSince1970], (long)energy.integerValue] : @"");
        NSString *key = [NSString stringWithFormat:@"%@:%@:%ld", userId, bubbleId, (long)energy.integerValue];
        if (bubbleId.length && [recordedCollectedBubbles containsObject:key]) continue;
        if (bubbleId.length) { if (recordedCollectedBubbles.count > 1000) [recordedCollectedBubbles removeAllObjects]; [recordedCollectedBubbles addObject:key]; }
        if (bubbleId.length) {
            @synchronized (self) {
                [pendingCollectBubbles removeObject:[NSString stringWithFormat:@"%@:%@", userId, bubbleId]];
            }
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (![[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:getCurrentDateString()]) {
            self.todayCollectedEnergy = 0;
            [defaults setObject:getCurrentDateString() forKey:@"todayCollectedEnergyDate"];
        }
        self.totalCollectedEnergy += energy.integerValue;
        self.todayCollectedEnergy += energy.integerValue;
        [defaults setInteger:self.totalCollectedEnergy forKey:@"totalCollectedEnergy"];
        [defaults setInteger:self.todayCollectedEnergy forKey:@"todayCollectedEnergy"];
        [defaults synchronize];
        BOOL isSelf = [userId isEqualToString:self.myUserId] || isAnimalEnergy;
        NSString *source = @"自己";
        if (isAnimalEnergy) {
            source = @"保护地巡护动物/能量雨";
        } else if (!isSelf) {
            NSDictionary *contact = [self.friendsName[userId] isKindOfClass:NSDictionary.class] ? self.friendsName[userId] : nil;
            NSString *name = [contact[@"displayName"] isKindOfClass:NSString.class] ? contact[@"displayName"] : nil;
            if (!name.length) name = [contact[@"name"] isKindOfClass:NSString.class] ? contact[@"name"] : nil;
            source = name.length ? [NSString stringWithFormat:@"好友\u201c%@\u201d", name] : @"好友";
        }
        NSString *message = isAnimalEnergy
            ? [NSString stringWithFormat:@"成功收取保护地/能量雨能量：%ld g（今日累计 %ld g）", (long)energy.integerValue, (long)self.todayCollectedEnergy]
            : (isSelf
                ? [NSString stringWithFormat:@"成功收取自己能量：%ld g（今日累计 %ld g）", (long)energy.integerValue, (long)self.todayCollectedEnergy]
                : [NSString stringWithFormat:@"成功收取%@的能量：%ld g（今日累计 %ld g）", source, (long)energy.integerValue, (long)self.todayCollectedEnergy]);
        [self recordStage:message];
    }
}

-(void)matchFriendIdAndBubbles:(id)args {
    @try {
        if ([args isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            NSString *resultCode = [NSString stringWithFormat:@"%@", resData[@"resultCode"] ?: dict[@"resultCode"] ?: resData[@"resultStatus"] ?: dict[@"resultStatus"] ?: @""];
            NSString *memo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: dict[@"memo"] ?: resData[@"resultMsg"] ?: dict[@"resultMsg"] ?: resData[@"errorMessage"] ?: @""];
            if ([memo containsString:@"操作存在异常"] || [memo containsString:@"请稍后再试"] || [memo containsString:@"频繁"] || [resultCode isEqualToString:@"SECURITY_RISK"] || [resultCode isEqualToString:@"USER_OPERATE_LIMIT"]) {
                static NSDate *lastForestRiskLogDate = nil;
                if (!lastForestRiskLogDate || [[NSDate date] timeIntervalSinceDate:lastForestRiskLogDate] > 300) {
                    lastForestRiskLogDate = [NSDate date];
                    [self recordStage:@"⚠️ 警告 · 服务端提示“近期操作存在异常”，已触发安全熔断暂停本轮扫描（保护账号安全）"];
                }
                self.isScanRunning = NO;
                return;
            }
            if ([resultCode isEqualToString:@"LIMIT_EXCEEDED"] || [resultCode isEqualToString:@"ACCESS_DENIED"] || [resultCode isEqualToString:@"FORBIDDEN"] || [memo containsString:@"拒绝"] || [memo containsString:@"代理"] || [memo containsString:@"风控"]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                [self recordStage:@"神奇海洋：收到服务端安全风险拦截，已自动熔断暂停本日清理（保护账号安全）"];
            }
            NSString *resDesc = [NSString stringWithFormat:@"%@", resData[@"resultDesc"] ?: dict[@"resultDesc"] ?: @""];
            BOOL isOceanLimit = [resultCode containsString:@"LIMIT"] || [resData[@"resultCode"] containsString:@"LIMIT"] || [resDesc containsString:@"上限"] || [resDesc containsString:@"已达20次"];
            if (resData && (resData[@"cleanRewardVOS"] || resData[@"canClearFriendSeaToday"] || [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] || [dict[@"operationType"] containsString:@"cleanFriendOcean"] || isOceanLimit)) {
                NSNumber *canClearToday = resData[@"canClearFriendSeaToday"];
                if ((canClearToday && [canClearToday boolValue] == NO) || isOceanLimit) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:@"神奇海洋：服务端确认今日海域清理已达上限（勤劳的你，明天见～）"];
                    [self oceanStopWithReason:nil];
                    return;
                }
                NSArray *rewards = resData[@"cleanRewardVOS"];
                NSString *cleanedUid = resData[@"cleanedUserId"] ?: resData[@"userId"] ?: dict[@"cleanedUserId"] ?: oceanCurrentUserId ?: self.lastCleanedOceanUserId;
                BOOL isSelfOcean = !cleanedUid.length || [cleanedUid isEqualToString:self.myUserId];
                if ([rewards isKindOfClass:NSArray.class] && rewards.count > 0) {
                    NSString *targetName = @"自己";
                    NSInteger currentCleanedCount = 0;
                    if (!isSelfOcean) {
                        NSString *displayName = [self waterDisplayNameForUser:cleanedUid];
                        targetName = displayName.length ? [NSString stringWithFormat:@"好友“%@”", displayName] : @"好友";
                        NSArray *cleanedArr = [[NSUserDefaults standardUserDefaults] arrayForKey:@"oceanCleanedFriendsToday"] ?: @[];
                        NSMutableSet *cleanedSet = [NSMutableSet setWithArray:cleanedArr];
                        if (cleanedUid.length) [cleanedSet addObject:cleanedUid];
                        currentCleanedCount = cleanedSet.count;
                        [[NSUserDefaults standardUserDefaults] setObject:cleanedSet.allObjects forKey:@"oceanCleanedFriendsToday"];
                        if (cleanedSet.count >= 20) {
                            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：今日已帮满 20 位好友清理，已达每日上限"]];
                            [self oceanStopWithReason:nil];
                        }
                        oceanCleanedInCurrentRound++;
                    }
                    NSDictionary *first = rewards.firstObject;
                    NSString *name = first[@"name"] ?: @"垃圾";
                    NSArray *attach = [first[@"attachRewardBOList"] isKindOfClass:NSArray.class] ? first[@"attachRewardBOList"] : nil;
                    if (!isSelfOcean) {
                        if (attach.count > 0) {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：获得%@的拼图碎片与%@（今日帮 %ld/20 位）", targetName, name, (long)currentCleanedCount]];
                        } else {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：清理%@的%@（今日帮 %ld/20 位）", targetName, name, (long)currentCleanedCount]];
                        }
                    } else {
                        if (attach.count > 0) {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：获得自己的拼图碎片与%@", name]];
                        } else {
                            [self recordStage:[NSString stringWithFormat:@"神奇海洋：清理自己的%@", name]];
                        }
                    }
                    if (isSelfOcean) {
                        myOceanCleanCount++;
                        if (myOceanCleanCount < 8) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                                if (self.enableCleanOcean && self.jsBridge) {
                                    [self cleanMyOcean];
                                }
                            });
                        }
                    } else {
                        oceanRunning = NO;
                        oceanCurrentUserId = nil;
                        oceanRequestToken++;
                        double delaySec = 2.5 + (arc4random_uniform(1500) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (self.enableCleanOcean) [self oceanSendNext];
                        });
                    }
                } else if (!isSelfOcean && (oceanRunning || [dict[@"methodName"] isEqualToString:@"cleanFriendsOcean"] || [dict[@"operationType"] containsString:@"cleanFriendOcean"])) {
                    NSString *displayName = [self waterDisplayNameForUser:cleanedUid];
                    NSString *name = displayName.length ? [NSString stringWithFormat:@"好友“%@”", displayName] : @"好友";
                    NSString *failMsg = resData[@"resultDesc"] ?: resData[@"resultMsg"] ?: dict[@"resultDesc"] ?: dict[@"resultMsg"] ?: @"海域暂无可清理垃圾，尝试下一位";
                    if ([failMsg containsString:@"上限"] || [failMsg containsString:@"已达"] || [failMsg containsString:@"20次"] || [resultCode isEqualToString:@"CLEAN_TIMES_EXCEED"] || [resultCode isEqualToString:@"USER_CLEAN_TIRED"] || [resultCode isEqualToString:@"HELP_CLEAN_LIMIT"]) {
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                        [self recordStage:[NSString stringWithFormat:@"神奇海洋：服务端确认今日清理已达上限（%@）", failMsg]];
                        [self oceanStopWithReason:nil];
                    } else {
                        [self recordStage:[NSString stringWithFormat:@"神奇海洋：%@%@", name, failMsg]];
                        oceanRunning = NO;
                        oceanCurrentUserId = nil;
                        oceanRequestToken++;
                        double delaySec = 1.0 + (arc4random_uniform(800) / 1000.0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (self.enableCleanOcean) [self oceanSendNext];
                        });
                    }
                }
            }
            NSArray *list = nil;
            if ([resData isKindOfClass:NSDictionary.class]) {
                list = resData[@"friendList"] ?: resData[@"friendOceanList"] ?: resData[@"friendSeaList"] ?: resData[@"friendListVO"] ?: resData[@"friendInfoList"] ?: resData[@"friends"] ?: resData[@"oceanFriendList"] ?: resData[@"friendUserList"] ?: resData[@"oceanFriends"];
            }
            if (!list && [dict isKindOfClass:NSDictionary.class]) {
                list = dict[@"friendList"] ?: dict[@"friendOceanList"] ?: dict[@"friendSeaList"] ?: dict[@"friendListVO"] ?: dict[@"friendInfoList"] ?: dict[@"friends"] ?: dict[@"oceanFriendList"];
            }
            if ([list isKindOfClass:NSArray.class] && list.count > 0) {
                NSNumber *canClearFriendSeaToday = resData[@"canClearFriendSeaToday"] ?: resData[@"canCleanFriendSea"] ?: resData[@"canClearFriendSea"] ?: resData[@"canClearSea"];
                NSInteger todayCleaned = [resData[@"todayCleanCount"] integerValue] ?: [resData[@"cleanedCount"] integerValue] ?: [resData[@"todayCleanedCount"] integerValue];
                if ((canClearFriendSeaToday && [canClearFriendSeaToday boolValue] == NO) || todayCleaned >= 20) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"oceanLimitReachedToday"];
                    [self recordStage:[NSString stringWithFormat:@"神奇海洋：服务端确认今日清理好友已达上限（%ld/20 位）", (long)MAX(20, todayCleaned)]];
                    [self oceanStopWithReason:nil];
                } else {
                    NSMutableArray<NSString *> *cleanableFriends = [NSMutableArray array];
                    for (id f in list) {
                        if ([f isKindOfClass:NSDictionary.class]) {
                            NSString *uid = [AntForestManager extractUserIdFromDictionary:f];
                            BOOL canClean = [f[@"seaCleanable"] boolValue] || [f[@"canClean"] boolValue] || ([f[@"rubbishNumber"] integerValue] > 0) || ([f[@"cleanStatus"] integerValue] == 1);
                            if (uid.length && (canClean || list.count <= 20)) [cleanableFriends addObject:uid];
                        } else if ([f isKindOfClass:NSString.class]) {
                            [cleanableFriends addObject:f];
                        }
                    }
                    if (cleanableFriends.count) {
                        [self scanOceanForFriends:cleanableFriends];
                    }
                }
            }
        }
        if ([args isKindOfClass:NSDictionary.class]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            [self updateWaterFriendListFromResponse:args];
            if (waterRunning) {
                [self handleWaterResponse:args];
            }
            NSString *opType = [NSString stringWithFormat:@"%@", dict[@"operationType"] ?: (self.lastRpcOperationType ?: @"")];
            if ([opType containsString:@"protectBubble"] || [dict[@"handlerName"] isEqualToString:@"protectBubble"] || resData[@"protectBubble"] || resData[@"userProtectResult"]) {
                [self handleAutoReviveResponse:args];
            }
            NSArray *taskInfoList = [resData[@"taskInfoList"] isKindOfClass:NSArray.class] ? resData[@"taskInfoList"] : ([dict[@"taskInfoList"] isKindOfClass:NSArray.class] ? dict[@"taskInfoList"] : nil);
            if (resData[@"antOceanTaskVOList"] || [dict[@"antOceanTaskVOList"] isKindOfClass:NSArray.class]) {
                [self handleOceanTaskListResponse:resData ?: dict];
            }
            if (![AntForestManager isManorResponse:args]) {
                if (resData[@"forestTasksNew"] || resData[@"energySignVO"] || taskInfoList || resData[@"taskList"] || dict[@"taskList"] || resData[@"drawAsset"] || resData[@"drawEntranceVO"] || resData[@"drawActivity"] || resData[@"drawPrize"] || resData[@"drawPrizes"] || resData[@"finishAwardResultVO"] || resData[@"receiveAwardResultVO"] || resData[@"awardResultVO"] || resData[@"finishVO"] || [opType containsString:@"antiep"] || [opType containsString:@"queryTaskList"] || [opType containsString:@"finishTask"] || [opType containsString:@"receiveTaskAward"] || [opType containsString:@"draw"] || [opType containsString:@"exchangeVitality"] || [resData[@"code"] isEqualToString:@"400000040"] || [resData[@"code"] isEqualToString:@"400000004"] || [resData[@"code"] isEqualToString:@"400000030"] || [resData[@"code"] isEqualToString:@"B000000008"] || [resData[@"desc"] containsString:@"不支持rpc调用"] || [resData[@"desc"] containsString:@"无法领取"] || [dict[@"error"] integerValue] == 3000) {
                    [self handleVitalityTaskListResponse:dict];
                }
                if (self.enableAutoFarmTasks && (resData[@"taskList"] || dict[@"taskList"] || resData[@"limitedTimeChallenge"] || dict[@"limitedTimeChallenge"])) {
                    [self handleFarmResponse:dict ?: resData];
                }
            } else if (self.enableAutoManor) {
                [self handleManorResponse:dict ?: resData];
            }
            
            // 自动识别本人ID
            NSString *curUid = resData[@"userBaseInfo"][@"userId"] ?: dict[@"userBaseInfo"][@"userId"] ?: resData[@"userEnergy"][@"userId"] ?: dict[@"userEnergy"][@"userId"] ?: resData[@"loginUserBaseInfo"][@"userId"] ?: dict[@"loginUserBaseInfo"][@"userId"] ?: resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"] ?: dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
            if (curUid.length) {
                if (!self.myUserId.length) {
                    self.myUserId = curUid;
                    [self recordStage:@"本人账户已识别"];
                }
                [[NSUserDefaults standardUserDefaults] setObject:curUid forKey:@"lastKnownUserId"];
            }
            
            // 巡护动物能量球成功回包校验 (支持新版 collectMonopolyCreatureEnergy 与经典 collectAnimalRobEnergy)
            NSInteger collected = [resData[@"collectedEnergy"] integerValue];
            if (!collected && [dict[@"collectedEnergy"] respondsToSelector:@selector(integerValue)]) {
                collected = [dict[@"collectedEnergy"] integerValue];
            }
            NSString *resResultCode = [NSString stringWithFormat:@"%@", resData[@"resultCode"] ?: dict[@"resultCode"] ?: @""];
            NSString *resMemo = [NSString stringWithFormat:@"%@", resData[@"memo"] ?: dict[@"memo"] ?: resData[@"resultMsg"] ?: dict[@"resultMsg"] ?: @""];
            BOOL isAnimalRpc = [opType containsString:@"collectMonopolyCreatureEnergy"] || 
                               [opType containsString:@"collectAnimalRobEnergy"] ||
                               resData[@"collectedEnergy"] != nil ||
                               dict[@"collectedEnergy"] != nil ||
                               resData[@"creatureCode"] != nil ||
                               dict[@"creatureCode"] != nil;
                               
            if (isAnimalRpc) {
                NSString *respCode = resData[@"creatureCode"] ?: dict[@"creatureCode"];
                BOOL isSuccess = ([resResultCode isEqualToString:@"SUCCESS"] || [resResultCode isEqualToString:@"100"] || [resData[@"success"] boolValue] || [dict[@"success"] boolValue] || collected > 0);
                if (isSuccess) {
                    [self markAnimalEnergyCollectedTodayForCode:respCode name:@"" reason:@"收取成功回包"];
                    NSInteger displayEnergy = (collected > 0) ? collected : 60;
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    if (![[defaults stringForKey:@"todayCollectedEnergyDate"] isEqualToString:getCurrentDateString()]) {
                        self.todayCollectedEnergy = 0;
                        [defaults setObject:getCurrentDateString() forKey:@"todayCollectedEnergyDate"];
                    }
                    self.totalCollectedEnergy += displayEnergy;
                    self.todayCollectedEnergy += displayEnergy;
                    [defaults setInteger:self.totalCollectedEnergy forKey:@"totalCollectedEnergy"];
                    [defaults setInteger:self.todayCollectedEnergy forKey:@"todayCollectedEnergy"];
                    [defaults synchronize];
                    [self recordStage:[NSString stringWithFormat:@"收取 · 保护地巡护动物能量球已成功收取：%ldg（今日累计 %ldg）", (long)displayEnergy, (long)self.todayCollectedEnergy]];
                } else if ([resResultCode isEqualToString:@"ENERGY_CAN_NOT_COLLECT"] || 
                           [resResultCode isEqualToString:@"ENERGY_HAS_COLLECTED"] || 
                           [resResultCode isEqualToString:@"ENERGY_NOT_EXIST"] ||
                           [resMemo containsString:@"已收"] ||
                           [resMemo containsString:@"不可收"] ||
                           [resMemo containsString:@"不存在"]) {
                    [self markAnimalEnergyCollectedTodayForCode:respCode name:@"" reason:resMemo.length ? resMemo : resResultCode];
                }
            }
            
            // 自动检测森林伙伴/巡护动物 (userCreatureVO，来自 queryUsingCreatureInfo 或 queryHomePage)
            NSDictionary *creatureVO = resData[@"userCreatureVO"] ?: dict[@"userCreatureVO"];
            if ([creatureVO isKindOfClass:NSDictionary.class]) {
                NSString *cCode = creatureVO[@"creatureCode"] ?: @"hongshandongwuyuan#dani";
                NSString *cName = creatureVO[@"displayInfo"][@"creatureNameText"] ?: @"大鲵";
                NSDictionary *robVO = [creatureVO[@"robEnergyVO"] isKindOfClass:NSDictionary.class] ? creatureVO[@"robEnergyVO"] : nil;
                NSInteger yesterdayEnergy = [robVO[@"yesterdayRobEnergy"] integerValue];
                NSString *yesterdayShortDay = [robVO[@"yesterdayShortDay"] isKindOfClass:NSString.class] ? robVO[@"yesterdayShortDay"] : @"";
                BOOL energyIsCollect = [robVO[@"energyIsCollect"] boolValue] || [robVO[@"isCollect"] boolValue] || [robVO[@"isCollected"] boolValue];
                
                NSInteger cEnergy = yesterdayEnergy ?: ([creatureVO[@"levelRobEnergy"] integerValue] ?: [creatureVO[@"initialRobEnergy"] integerValue]);
                if (cEnergy <= 0) cEnergy = 30;
                
                if (energyIsCollect || [self isAnimalEnergyCollectedTodayForCode:cCode name:cName]) {
                    // 今日已收，立即锁定防重
                    [self markAnimalEnergyCollectedTodayForCode:cCode name:cName reason:@"伙伴信息标记今日已收"];
                } else if (yesterdayEnergy > 0) {
                    [self recordStage:[NSString stringWithFormat:@"保护地巡护：探测到%@头顶巡护能量（%ldg），正在通过官方专有接口收取...", cName, (long)yesterdayEnergy]];
                    [self collectMonopolyCreatureEnergyWithCode:cCode shortDay:yesterdayShortDay energy:yesterdayEnergy name:cName];
                } else {
                    [self receiveAnimalEnergyWithPropId:cCode propType:cCode animalId:cCode energy:cEnergy name:cName isCollected:NO];
                }
            }
        }
        [self recordCollectedEnergyFromResponse:args];
        if (!self.enableAutoCollect) return;
        if (args != nil && [args isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = args;
            NSDictionary *resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            // 匹配 过期能量球 返回的  signId
            if(resData && resData[@"forestSignVOList"]) {
                NSArray *signList = resData[@"forestSignVOList"];
                for( NSDictionary *sign in signList) {
                    NSString *signId = [sign objectForKey:@"signId"];
                    NSString *userId = [[AntForestManager sharedInstance] myUserId]; //我自己的ID
                    NSArray *signRecords = [sign objectForKey:@"signRecords"];
                    for(NSDictionary *record in signRecords){
                        NSString *signKey = [record objectForKey:@"signKey"];
                        NSString *isSigned = [NSString stringWithFormat:@"%@", [record objectForKey:@"signed"]];
                        if([signKey isEqualToString:getCurrentDateString()] && [isSigned isEqualToString:@"0"]){
                            if(signId){
                                [self recordStage:@"正在复活自己的过期能量球..."];
                                [[AntForestManager sharedInstance] reviveEnergy:userId signId:signId];
                            }
                        }
                    }
                }
            }
            
            // 匹配 takelook 返回的 friendID（仅当插件正在执行后台找能量扫描时才由插件接管并查气泡，避免干扰用户手动找能量跳转）
            if(takeLookRunning && resData && resData[@"friendId"]) {
                NSString *friendId = resData[@"friendId"];
                if (![self consumeTakeLookFriend:friendId]) return;
                NSMutableDictionary* fb = [[AntForestManager sharedInstance] friendsBubbles];
                //如果字典树中没有
                if(![fb objectForKey:friendId]){
                    [fb setObject:[NSMutableDictionary dictionary] forKey:friendId];
                    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fb requiringSecureCoding:NO error:nil];
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsBubbles"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                //继续查这个人的能量球
                dispatch_async(globalSerialQueueQuery, ^{
                    [[AntForestManager sharedInstance] queryFriendsBubbles:friendId];
                });
            }
            // 匹配查询好的返回的所有能量球（兼容 userBaseInfo、userEnergy、loginUserBaseInfo 与 combineHandlerVOMap）
            id bubblesList = dict[@"bubbles"] ?: resData[@"bubbles"];
            id wateringBubblesList = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
            id userInfoMap = dict[@"userBaseInfo"] ?: resData[@"userBaseInfo"] ?: dict[@"loginUserBaseInfo"] ?: resData[@"loginUserBaseInfo"] ?: dict[@"userEnergy"] ?: resData[@"userEnergy"] ?: dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"] ?: resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"];
            
            if((bubblesList || wateringBubblesList) && userInfoMap) {
                // 1. 提取登录账户 UID (loginUserBaseInfo 恒等于当前登录用户)
                NSString *loginUid = dict[@"loginUserBaseInfo"][@"userId"] ?: resData[@"loginUserBaseInfo"][@"userId"];
                if (loginUid.length) {
                    if (!self.myUserId.length || ![self.myUserId isEqualToString:loginUid]) {
                        self.myUserId = loginUid;
                        [self recordStage:@"本人账户已识别"];
                        [[NSUserDefaults standardUserDefaults] setObject:loginUid forKey:@"lastKnownUserId"];
                    }
                }
                
                // 2. 提取当前气泡所属页面用户的 UID (好友页为好友 UID，本人首页为本人 UID)
                NSString *userId = nil;
                if([dict objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([resData objectForKey:@"userBaseInfo"]) {
                    NSDictionary *pDic = [resData objectForKey:@"userBaseInfo"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([dict objectForKey:@"userEnergy"]) {
                    NSDictionary *pDic = [dict objectForKey:@"userEnergy"];
                    userId = [pDic objectForKey:@"userId"];
                } else if ([resData objectForKey:@"userEnergy"]) {
                    NSDictionary *pDic = [resData objectForKey:@"userEnergy"];
                    userId = [pDic objectForKey:@"userId"];
                } else if (resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"]) {
                    userId = resData[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
                } else if (dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"]) {
                    userId = dict[@"combineHandlerVOMap"][@"userInfo"][@"userBaseInfo"][@"userId"];
                }
                
                if (!userId.length) {
                    userId = loginUid ?: self.myUserId;
                }
                if (!userId.length) {
                    [self recordStage:@"诊断 · 气泡回包跳过：账户尚未识别"];
                    return;
                }
                
                NSString *dName = dict[@"userEnergy"][@"displayName"] ?: resData[@"userEnergy"][@"displayName"] ?: dict[@"userBaseInfo"][@"displayName"] ?: resData[@"userBaseInfo"][@"displayName"];
                if (userId.length && [dName isKindOfClass:NSString.class] && dName.length && !self.friendsName[userId]) {
                    self.friendsName[userId] = dName;
                }
                
                // 3. 严格判定是否为本人首页：
                // 如果回包为好友页面（包含 nextAction=="Friend"，或者 userBaseInfo/userEnergy 且不等于本人 UID），则绝非本人首页
                BOOL isFriendPage = [resData[@"nextAction"] isEqualToString:@"Friend"] || 
                                    [dict[@"nextAction"] isEqualToString:@"Friend"] ||
                                    (dict[@"userBaseInfo"][@"userId"] && self.myUserId.length && ![dict[@"userBaseInfo"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (resData[@"userBaseInfo"][@"userId"] && self.myUserId.length && ![resData[@"userBaseInfo"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (dict[@"userEnergy"][@"userId"] && self.myUserId.length && ![dict[@"userEnergy"][@"userId"] isEqualToString:self.myUserId]) ||
                                    (resData[@"userEnergy"][@"userId"] && self.myUserId.length && ![resData[@"userEnergy"][@"userId"] isEqualToString:self.myUserId]);
                
                BOOL mine = !isFriendPage && (
                    (userId.length && self.myUserId.length && [userId isEqualToString:self.myUserId]) ||
                    (!dict[@"userBaseInfo"] && !dict[@"userEnergy"] && !resData[@"userBaseInfo"] && !resData[@"userEnergy"])
                );
                
                if (self.enableAutoRevive && !mine && userId.length) {
                    NSDictionary *userInfo = [dict[@"userBaseInfo"] isKindOfClass:NSDictionary.class] ? dict[@"userBaseInfo"] : nil;
                    NSDictionary *userEnergy = [dict[@"userEnergy"] isKindOfClass:NSDictionary.class] ? dict[@"userEnergy"] : nil;
                    NSDictionary *userForest = [dict[@"userForest"] isKindOfClass:NSDictionary.class] ? dict[@"userForest"] : nil;
                    NSInteger restTimes = extractRestTimesFromDict(dict);
                    if (restTimes >= 0) {
                        NSInteger used = MAX(0, 6 - restTimes);
                        [NSUserDefaults.standardUserDefaults setInteger:used forKey:@"autoReviveCount"];
                    }
                    if (canReviveFriendBubble(dict) || canReviveFriendBubble(userInfo) || canReviveFriendBubble(userEnergy) || canReviveFriendBubble(userForest) || [dict[@"forestSignVOList"] isKindOfClass:NSArray.class]) {
                        [self queueAutoReviveForUser:userId];
                    }
                }
                
                //判断是否有能量保护罩
                if (!mine) {
                    NSArray *pArr = [dict objectForKey:@"usingUserProps"] ?: [dict objectForKey:@"usingUserPropsNew"];
                    if (pArr) {
                        for (NSDictionary *dic in pArr) {
                            NSString *type = [dic objectForKey:@"type"] ?: [dic objectForKey:@"propGroup"] ?: @"";
                            if ([type containsString:@"Shield"] || [type containsString:@"shield"]) {
                                [self recordStage:@"诊断 · 好友气泡回包：检测到保护罩，跳过该好友"];
                                static dispatch_once_t onceToken;
                                dispatch_once(&onceToken, ^{
                                    if (!shieldReportedFriendsInRound) {
                                        shieldReportedFriendsInRound = [NSMutableSet set];
                                    }
                                });
                                if (userId.length && ![shieldReportedFriendsInRound containsObject:userId]) {
                                    [shieldReportedFriendsInRound addObject:userId];
                                    NSString *friendName = nil;
                                    id fInfo = userId.length ? self.friendsName[userId] : nil;
                                    if ([fInfo isKindOfClass:NSString.class] && [(NSString *)fInfo length] > 0) {
                                        friendName = (NSString *)fInfo;
                                    } else if ([fInfo isKindOfClass:NSDictionary.class]) {
                                        friendName = [AntForestManager extractNameFromDictionary:fInfo];
                                    }
                                    if (!friendName.length) {
                                        friendName = dict[@"userEnergy"][@"displayName"] ?: dict[@"userBaseInfo"][@"displayName"];
                                    }
                                    if (!friendName.length) {
                                        friendName = @"好友";
                                    }
                                    [self recordStage:[NSString stringWithFormat:@"好友“%@”开启了能量保护罩，已跳过", friendName]];
                                }
                                [self advanceTakeLookForFriend:userId];
                                return;
                            }
                        }
                    }
                }
                
                NSMutableDictionary *dictBubbles = [dict objectForKey:@"bubbles"] ?: [resData objectForKey:@"bubbles"];
                NSUInteger available = 0, waiting = 0;
                for (NSDictionary *bubble in dictBubbles) {
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]) available++;
                    if ([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"]) waiting++;
                }
                
                if (mine) {
                    // 经典道具形态的动物巡护 (usingUserPropsNew / usingUserProps)
                    NSArray *props = dict[@"usingUserPropsNew"] ?: dict[@"usingUserProps"] ?: dict[@"loginUserUsingPropNew"];
                    if ([props isKindOfClass:NSArray.class]) {
                        for (NSDictionary *prop in props) {
                            NSString *pGroup = [NSString stringWithFormat:@"%@", prop[@"propGroup"] ?: @""];
                            NSString *pType = [NSString stringWithFormat:@"%@", prop[@"propType"] ?: @""];
                            if ([pGroup isEqualToString:@"animal"] || [pType containsString:@"ANIMAL"] || [pType containsString:@"HANLI"] || [pType containsString:@"dani"] || [pType containsString:@"animal"]) {
                                NSString *propId = prop[@"propId"];
                                NSDictionary *extInfo = nil;
                                if ([prop[@"extInfo"] isKindOfClass:NSString.class]) {
                                    NSData *d = [prop[@"extInfo"] dataUsingEncoding:NSUTF8StringEncoding];
                                    if (d) extInfo = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                                } else if ([prop[@"extInfo"] isKindOfClass:NSDictionary.class]) {
                                    extInfo = prop[@"extInfo"];
                                }
                                NSDictionary *animalDict = [extInfo[@"animal"] isKindOfClass:NSDictionary.class] ? extInfo[@"animal"] : nil;
                                NSString *animalId = animalDict[@"animalId"] ?: extInfo[@"animalId"] ?: @"";
                                NSString *animalName = animalDict[@"name"] ?: extInfo[@"name"] ?: prop[@"propName"] ?: @"巡护伙伴";
                                
                                // 全面检查已收状态
                                BOOL isCollected = [extInfo[@"isCollected"] boolValue] || 
                                                   [extInfo[@"collected"] boolValue] || 
                                                   [extInfo[@"hasCollected"] boolValue] || 
                                                   [animalDict[@"isCollected"] boolValue] ||
                                                   [animalDict[@"collected"] boolValue] ||
                                                   [animalDict[@"hasCollected"] boolValue] ||
                                                   [extInfo[@"status"] isEqualToString:@"COLLECTED"] ||
                                                   [extInfo[@"collectStatus"] isEqualToString:@"COLLECTED"] ||
                                                   [prop[@"status"] isEqualToString:@"COLLECTED"] ||
                                                   [prop[@"collectStatus"] isEqualToString:@"COLLECTED"] ||
                                                   ([extInfo[@"canCollect"] respondsToSelector:@selector(boolValue)] && ![extInfo[@"canCollect"] boolValue]);
                                
                                // 检查待收能量字段
                                NSNumber *uncollectedNum = extInfo[@"uncollectedEnergy"] ?: animalDict[@"uncollectedEnergy"];
                                if (uncollectedNum != nil && [uncollectedNum integerValue] == 0) {
                                    isCollected = YES;
                                }
                                
                                NSString *targetCode = animalId.length ? animalId : pType;
                                if (isCollected || [self isAnimalEnergyCollectedTodayForCode:targetCode name:animalName]) {
                                    [self markAnimalEnergyCollectedTodayForCode:targetCode name:animalName reason:@"首页道具标记已收取"];
                                    continue;
                                }
                                
                                NSInteger energy = [extInfo[@"energy"] integerValue];
                                if (energy <= 0) energy = [extInfo[@"leftEnergy"] integerValue];
                                if (energy <= 0 && uncollectedNum != nil) energy = [uncollectedNum integerValue];
                                if (energy <= 0) energy = [animalDict[@"energy"] integerValue];
                                
                                // 仅当未收过且无显式 0 能量时，才以能力容量兜底
                                if (energy <= 0) {
                                    NSInteger capacity = [extInfo[@"robEnergyInRound"] integerValue] ?: [animalDict[@"robAbility"][@"robEnergyInRound"] integerValue];
                                    if (capacity > 0) energy = capacity;
                                }
                                
                                [self receiveAnimalEnergyWithPropId:propId propType:pType animalId:animalId energy:energy name:animalName isCollected:NO];
                            }
                        }
                    }
                    // 独立气泡形态的动物巡护 (wateringBubbles / bubbles 中的 animal/creature)
                    NSArray *wbList = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
                    if ([wbList isKindOfClass:NSArray.class]) {
                        for (NSDictionary *wb in wbList) {
                            if (![wb isKindOfClass:NSDictionary.class]) continue;
                            NSString *bizType = [NSString stringWithFormat:@"%@", wb[@"bizType"] ?: @""];
                            NSString *bId = [NSString stringWithFormat:@"%@", wb[@"id"] ?: wb[@"bubbleId"] ?: @""];
                            if ([bizType containsString:@"animal"] || [bizType containsString:@"creature"] || [bId containsString:@"dani"] || [bId containsString:@"hongshan"]) {
                                if ([self isAnimalEnergyCollectedTodayForCode:@"hongshandongwuyuan#dani" name:@"大鲵"]) {
                                    continue;
                                }
                                NSInteger wEnergy = [wb[@"fullEnergy"] integerValue] ?: [wb[@"energy"] integerValue];
                                [self receiveAnimalEnergyWithPropId:bId propType:@"hongshandongwuyuan#dani" animalId:@"hongshandongwuyuan#dani" energy:wEnergy name:@"大鲵" isCollected:NO];
                            }
                        }
                    }
                }
                [self recordStage:[NSString stringWithFormat:@"诊断 · %@气泡回包：总 %lu 个，可收 %lu 个，等待 %lu 个", mine ? @"本人" : @"好友", (unsigned long)dictBubbles.count, (unsigned long)available, (unsigned long)waiting]];
                if (mine && !self.enableSelfCollect) {
                    [self recordStage:@"已跳过本人能量"];
                    [self releaseSelfPriorityForCycle:collectionCycle reason:@"本人收取已关闭"];
                    return;
                }
                // 初始化一个空的可变数组
                NSMutableArray *bidArr = [NSMutableArray array];
                for (NSDictionary *bubble in dictBubbles) {
                    NSString *bUserId = [bubble objectForKey:@"userId"] ?: userId;
                    NSString *bid = [bubble objectForKey:@"id"];
                    NSString *overTime = [bubble objectForKey:@"overTime"];
                    NSString *remainEnergy = [bubble objectForKey:@"remainEnergy"];
                    
                    //可收取直接收取
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"AVAILABLE"]){
                        [bidArr addObject:bid];
                        NSString *friendName = [self friendDisplayNameForUser:bUserId];
                        NSString *targetDesc = [bUserId isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"收取%@的能量球（%@g）", targetDesc, remainEnergy]];
                        dispatch_async(globalSerialQueueCollect, ^{
                            [[AntForestManager sharedInstance] collectBubbles:bUserId bubblesId:bid];
                        });
                        
                    }
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"INSUFFICIENT"]){
                        // 能量不足只记录调试日志，避免在主日志面板中刷屏
                        NSLog(@"[AntForestPort] 能量不足: %@, 剩%@g, %@", [self friendDisplayNameForUser:bUserId], remainEnergy, bid);
                    }
                    //等待中放入字典树中
                    if([[bubble objectForKey:@"collectStatus"] isEqualToString:@"WAITING"] && overTime){
                        NSMutableDictionary* fb = [[AntForestManager sharedInstance] friendsBubbles];
                        NSDictionary *myBubble = @{bid:overTime};
                        //无论有没有直接覆盖
                        [fb setObject:myBubble forKey:bUserId];
                        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fb requiringSecureCoding:NO error:nil];
                        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsBubbles"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        // 等待能量球入库只进系统日志，避免每颗气泡挤爆用户面板
                        NSLog(@"[AntForestPort] 等待能量球入库: %@, %@g, %@", [self friendDisplayNameForUser:bUserId], remainEnergy, bid);
                    }
                    //可帮助直接帮助
                    if([[bubble objectForKey:@"canHelpCollect"] isEqualToNumber:@1]){
                        NSString *friendName = [self friendDisplayNameForUser:bUserId];
                        NSString *targetDesc = [bUserId isEqualToString:self.myUserId] ? @"自己" : [NSString stringWithFormat:@"好友“%@”", friendName];
                        [self recordStage:[NSString stringWithFormat:@"帮助%@收取能量球（%@g）", targetDesc, remainEnergy]];
                    }
                }
                
                // 匹配 wateringBubbles（包含好友浇水赠能、保护地巡护动物每日巡护能量球）
                NSArray *wateringBubbles = dict[@"wateringBubbles"] ?: resData[@"wateringBubbles"];
                if ([wateringBubbles isKindOfClass:NSArray.class]) {
                    static NSMutableSet *collectedWateringBids = nil;
                    static dispatch_once_t wbOnce;
                    dispatch_once(&wbOnce, ^{
                        collectedWateringBids = [NSMutableSet set];
                    });
                    
                    for (NSDictionary *wb in wateringBubbles) {
                        if (![wb isKindOfClass:NSDictionary.class]) continue;
                        NSNumber *bidNum = wb[@"id"] ?: wb[@"bubbleId"];
                        if (bidNum && [bidNum longLongValue] > 0) {
                            NSString *bid = [bidNum stringValue];
                            NSString *bizType = [NSString stringWithFormat:@"%@", wb[@"bizType"] ?: @""];
                            NSString *fullEnergy = [NSString stringWithFormat:@"%@", wb[@"fullEnergy"] ?: wb[@"energy"] ?: @""];
                            
                            // 严防误收与刷屏：
                            // 仅本人首页的赠能/巡护能量，或动物巡护能量，或好友页明确允许代收(canHelpCollect)才收
                            if (mine || [bizType containsString:@"animal"] || [wb[@"canHelpCollect"] isEqualToNumber:@1]) {
                                if ([collectedWateringBids containsObject:bid]) {
                                    continue;
                                }
                                if (collectedWateringBids.count > 500) {
                                    [collectedWateringBids removeAllObjects];
                                }
                                [collectedWateringBids addObject:bid];
                                
                                NSString *targetUid = (mine || [bizType containsString:@"animal"]) ? (self.myUserId.length ? self.myUserId : userId) : (userId ?: self.myUserId);
                                [self recordStage:[NSString stringWithFormat:@"发现赠能/巡护能量（%@g，ID：%@）并自动收取", fullEnergy, bid]];
                                dispatch_async(globalSerialQueueCollect, ^{
                                    [[AntForestManager sharedInstance] collectBubbles:targetUid bubblesId:bid];
                                });
                            }
                        }
                    }
                }
                
                if (mine && selfPriorityPending) {
                    // 这个串行队列中的屏障排在本人的 collect 请求之后，好友请求只能在此后入队。
                    NSUInteger cycle = selfPriorityCycle;
                    dispatch_async(globalSerialQueueCollect, ^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self releaseSelfPriorityForCycle:cycle reason:@"本人收取请求已提交"];
                        });
                    });
                }
                [self advanceTakeLookForFriend:userId];
                //                //一键收取 能量球多时 提示不合法
                //                if([bidArr count] > 0 && userId) {
                //                    NSString* bidStr = [bidArr componentsJoinedByString:@","];
                //                    NSString *log = [NSString stringWithFormat:@"%@\n一键收取能量球, %@",[[AntForestManager sharedInstance] getUserName:userId],bidStr];
                //                    [[AntForestManager sharedInstance] addLog:log];
                //                    [[AntForestManager sharedInstance] collectBubbles:userId bubblesId:bidStr];
                //                }
            }
            // 匹配用户名
            if([dict objectForKey:@"contactsDicArray"]) {
                NSMutableDictionary* fn = [[AntForestManager sharedInstance] friendsName];
                NSArray *cArr = [dict objectForKey:@"contactsDicArray"];
                for(NSDictionary *cdict in cArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:cdict];
                    if (userId.length) [fn setObject:cdict forKey:userId];
                }
                NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fn requiringSecureCoding:NO error:nil];
                if (data) {
                    [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
            }
            // 先查询本人首页；严格的“本人收取完成后再查好友”由独立修复处理。
            if (!resData) resData = [dict[@"resData"] isKindOfClass:NSDictionary.class] ? dict[@"resData"] : nil;
            if(resData && resData[@"myself"]) {
                NSDictionary *myDict = resData[@"myself"];
                NSString *userIdMy = [AntForestManager extractUserIdFromDictionary:myDict] ?: [myDict objectForKey:@"userId"];
                if (userIdMy.length) {
                    if (!self.myUserId.length) {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                        [self recordStage:@"收取 · 本人账户已识别"];
                    } else {
                        [[AntForestManager sharedInstance] setMyUserId:userIdMy];
                    }
                }
                NSNumber *canCollectEnergy = [myDict objectForKey:@"canCollectEnergy"];
                [self recordStage:[NSString stringWithFormat:@"诊断 · 本人能量状态：%@", [canCollectEnergy isEqualToNumber:@1] ? @"可收" : @"暂无成熟能量"]];
                if (self.isScanRunning) {
                    if(self.enableSelfCollect) {
                        dispatch_async(globalSerialQueueQuery, ^{
                            [[AntForestManager sharedInstance] queryMyBubbles];
                        });
                    }
                    if (self.enableAutoRewardTasks) {
                        dispatch_async(globalSerialQueueQuery, ^{
                            [[AntForestManager sharedInstance] queryVitalityTaskList];
                        });
                    }
                }
            }
            if(resData && (resData[@"friendRanking"] || resData[@"totalDatas"])) {
                NSArray *rankArr = [resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : resData[@"totalDatas"];
                NSUInteger collectable = 0;
                for (NSDictionary *dictRank in rankArr) if ([[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1]) collectable++;
                [self recordStage:[NSString stringWithFormat:@"诊断 · 排行榜校验回包：%lu 位，可收 %lu 位", (unsigned long)rankArr.count, (unsigned long)collectable]];
                if (self.isScanRunning) {
                    for(NSDictionary *dictRank in rankArr) {
                        NSString *userId = [AntForestManager extractUserIdFromDictionary:dictRank] ?: [dictRank objectForKey:@"userId"];
                        if (!userId.length) continue;
                        BOOL isCollectable = [[dictRank objectForKey:@"canCollectEnergy"] isEqualToNumber:@1];
                        BOOL isReviveable = canReviveFriendBubble(dictRank);
                        if (isReviveable) {
                            [self queueAutoReviveForUser:userId];
                        }
                        if (isCollectable || isReviveable){
                            if (selfPriorityPending) {
                                [deferredFriendRankIds addObject:userId];
                            } else {
                                dispatch_async(globalSerialQueueQuery, ^{
                                    [[AntForestManager sharedInstance] queryFriendsBubbles:userId];
                                });
                            }
                        }
                    }
                }
            }
            //匹配排行
            NSArray *rankTotalArr = [resData[@"totalDatas"] isKindOfClass:NSArray.class] ? resData[@"totalDatas"] : ([resData[@"friendRanking"] isKindOfClass:NSArray.class] ? resData[@"friendRanking"] : nil);
            if (rankTotalArr.count > 0) {
                NSMutableDictionary *fr = [[AntForestManager sharedInstance] friendsRank];
                NSMutableDictionary *fn = [[AntForestManager sharedInstance] friendsName];
                BOOL nameUpdated = NO;
                for(NSDictionary *dictTotalRank in rankTotalArr) {
                    NSString *userId = [AntForestManager extractUserIdFromDictionary:dictTotalRank] ?: [dictTotalRank objectForKey:@"userId"];
                    if (!userId.length) continue;
                    if (self.isScanRunning && canReviveFriendBubble(dictTotalRank)) {
                        [self queueAutoReviveForUser:userId];
                    }
                    NSString *rank = [dictTotalRank objectForKey:@"rank"];
                    NSString *uid = [AntForestManager extractUserIdFromDictionary:dictTotalRank];
                    if (uid.length) {
                        if (rank) [fr setObject:rank forKey:uid];
                        NSString *name = [AntForestManager extractNameFromDictionary:dictTotalRank];
                        if (name.length) {
                            NSMutableDictionary *contact = [fn[uid] mutableCopy] ?: [NSMutableDictionary dictionary];
                            contact[@"displayName"] = name;
                            fn[uid] = contact;
                            nameUpdated = YES;
                        }
                    }
                }
                NSData *rankData = [NSKeyedArchiver archivedDataWithRootObject:fr requiringSecureCoding:NO error:nil];
                if (rankData) {
                    [[NSUserDefaults standardUserDefaults] setObject:rankData forKey:@"cachedFriendsRank"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                if (nameUpdated) {
                    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fn requiringSecureCoding:NO error:nil];
                    if (data) {
                        [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"friendsName"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                    }
                }
                if (self.isScanRunning) {
                    if (rankScanPending) {
                        rankScanPending = NO;
                        if (selfPriorityPending) {
                            deferredRankedFriendIds = fr.allKeys;
                        } else {
                            [self scanRankedFriends:fr.allKeys cycle:collectionCycle];
                        }
                    }
                    if (self.enableCleanOcean && fr.allKeys.count > 0) {
                        [self scanOceanForFriends:fr.allKeys];
                    }
                    BOOL hasMore = [resData[@"hasMore"] boolValue] || [resData[@"hasNext"] boolValue];
                    NSInteger nextIndex = [resData[@"nextStartIndex"] integerValue] ?: [resData[@"startIndex"] integerValue] + rankTotalArr.count;
                    if ((hasMore || rankTotalArr.count >= 200) && nextIndex > 0 && nextIndex < 1000) {
                        static NSInteger lastFetchedIndex = 0;
                        if (nextIndex > lastFetchedIndex) {
                            lastFetchedIndex = nextIndex;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                                [self queryRankPage:nextIndex];
                            });
                        }
                    }
                }
            }
            
            
        }
    }
    @catch (NSException *exception) {
        //FileLog(@"Exception caught: %@, reason: %@, stack trace: %@", exception.name, exception.reason, exception.callStackSymbols);
        // 捕获异常的代码
        [Tool Alert:[exception description]];
    }
}



@end
