/*
 * BatteryHealthFix v1.4 —— 精准修复版
 *
 * 硬件场景（你的情况）：
 *   原装 DESAY 保护板 + F5D9495XVVJPK3AP 序列号
 *   第三方电芯，实际容量 3457 mAh
 *   EEPROM DesignedCapacity 被改成 3156 mAh（比实际小！）
 *   → MaxCapacity / DesignedCapacity = 109.5% 被 Apple 判假！
 *
 * 修复核心：
 *   1. DesignedCapacity 改成 ≥ MaxCapacity 的值（让比值 ≤ 100%）
 *   2. MaxCapacity 保持真实值（3457）
 *   3. PeakPerformance 强制 100%
 *   4. 其他键全部放行
 *
 * 最终效果：
 *   DesignedCapacity = 3500 (新电芯标称值)
 *   MaxCapacity      = 3457 (真实值)
 *   健康度           = 3457/3500 = 98.7% → 显示 99%
 *   充电次数         = 7 (真实值)
 *   序列号           = F5D9495XVVJPK3AP (真实值)
 */

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>

// ============================================================
// 可配置常量
// ============================================================

// 你的第三方电芯标称设计容量（不是 EEPROM 里被写的 3156）
// 根据爱思读数 实际容量 3457 → 建议填 3500（或你电芯包装上标的值）
static const int kNewCellDesignedCapacity = 3500;

// 峰值性能（固定 100%）
static const int kPeakPerformanceCapacity = 100;

// ============================================================
// Hook 函数指针
// ============================================================

static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
);
static CFTypeRef hook_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
);

static id (*orig_NSUD_objectForKey)(id self, SEL _cmd, NSString *key);
static id hook_NSUD_objectForKey(id self, SEL _cmd, NSString *key);

// ============================================================
// IORegistry Hook
// ============================================================

static CFTypeRef hook_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
) {
    CFTypeRef realValue = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    
    if (!key) return realValue;
    NSString *keyStr = (__bridge NSString *)key;
    
    // ---------- 诊断日志 ----------
    static NSMutableSet *printedKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        printedKeys = [NSMutableSet set];
    });
    
    NSArray *batteryKeywords = @[
        @"Battery", @"AppleBattery", @"IOPS", @"Capacity", @"Cycle",
        @"Peak", @"Serial", @"Pairing", @"UUID", @"Verified",
        @"AppleSmartBattery", @"Manufacturer"
    ];
    BOOL isBatteryKey = NO;
    for (NSString *kw in batteryKeywords) {
        if ([keyStr containsString:kw]) { isBatteryKey = YES; break; }
    }
    
    if (isBatteryKey && ![printedKeys containsObject:keyStr]) {
        [printedKeys addObject:keyStr];
        NSLog(@"[BHF/DIAG] %@ → %@",
              keyStr, realValue ? [(__bridge id)realValue description] : @"<nil>");
    }
    
    // ============================================================
    // A. DesignedCapacity —— 强制改成新电芯标称值
    // ============================================================
    // 原始值 3156，但实际 MaxCapacity 3457 > 3156 → Apple 判假！
    // 必须让 DesignedCapacity ≥ MaxCapacity
    
    if ([keyStr isEqualToString:@"BatteryCapacity"] ||
        [keyStr isEqualToString:@"DesignedCapacity"] ||
        [keyStr isEqualToString:@"AppleBatteryDesignCapacity"]) {
        
        if (realValue) CFRelease(realValue);
        NSLog(@"[BHF] 🔒 %@: %d → 强制改为 %d（匹配新电芯）",
              keyStr,
              realValue ? (int)CFNumberGetInt((CFNumberRef)realValue) : 0,
              kNewCellDesignedCapacity);
        return CFRetain((__bridge CFTypeRef)@(kNewCellDesignedCapacity));
    }
    
    // ============================================================
    // B. PeakPerformanceCapacity —— 强制 100%
    // ============================================================
    
    if ([keyStr isEqualToString:@"PeakPerformanceCapacity"] ||
        [keyStr isEqualToString:@"BatteryPeakPerformanceCapacity"] ||
        [keyStr isEqualToString:@"IOPSPeakPerformanceCapacity"]) {
        
        if (realValue) CFRelease(realValue);
        NSLog(@"[BHF] 🔒 PeakPerformance → 100%%");
        return CFRetain((__bridge CFTypeRef)@(kPeakPerformanceCapacity));
    }
    
    // ============================================================
    // C. 认证键 —— 智能伪造
    // ============================================================
    
    if ([keyStr isEqualToString:@"IOPSIsAppleBattery"] ||
        [keyStr isEqualToString:@"IsAppleBattery"] ||
        [keyStr isEqualToString:@"AppleBatteryIsVerified"]) {
        
        if (!realValue || realValue == kCFBooleanFalse) {
            if (realValue) CFRelease(realValue);
            NSLog(@"[BHF] 🔒 认证 %@ → YES（原值: %@）",
                  keyStr, realValue ?: @"nil");
            return CFRetain(kCFBooleanTrue);
        }
        // 原装保护板大概率已经返回 YES，放行
        return realValue;
    }
    
    // 配对键
    if ([keyStr containsString:@"Pairing"] ||
        ([keyStr containsString:@"UUID"] && [keyStr containsString:@"Battery"]) ||
        [keyStr isEqualToString:@"BatteryUUID"] ||
        [keyStr isEqualToString:@"IOPSBatteryPairingStatus"]) {
        
        if (!realValue || realValue == kCFBooleanFalse) {
            if (realValue) CFRelease(realValue);
            NSLog(@"[BHF] 🔒 配对 %@ → 伪造通过", keyStr);
            return CFRetain(kCFBooleanTrue);
        }
        return realValue;
    }
    
    // ============================================================
    // D. 所有其他电池键 —— 完全放行真实值！
    // ============================================================
    // MaxCapacity = 3457 (真实)
    // CycleCount  = 7    (真实)
    // SerialNumber = F5D9495XVVJPK3AP (真实)
    // CurrentCapacity / Manufacturer / ... 全部放行
    
    // 直接返回，不做任何修改
    return realValue;
}

// ============================================================
// NSUserDefaults Hook —— 拦截偏好设置缓存
// ============================================================

static id hook_NSUD_objectForKey(id self, SEL _cmd, NSString *key) {
    id result = orig_NSUD_objectForKey(self, _cmd, key);
    
    // PeakPerformance
    if ([key containsString:@"PeakPerformance"]) {
        NSLog(@"[BHF/Defaults] %@ → 100", key);
        return @100;
    }
    // 认证/配对
    if ([key containsString:@"isAppleBattery"] ||
        [key containsString:@"AppleBatteryVerified"] ||
        [key containsString:@"BatteryPairing"]) {
        if (!result || [result boolValue] == NO) {
            NSLog(@"[BHF/Defaults] %@ → YES", key);
            return @YES;
        }
    }
    
    return result;
}

// ============================================================
// SpringBoard Hook —— 强制显示设置入口
// ============================================================

static BOOL (*orig_SB_showHealthEntry)(id self, SEL _cmd);
static BOOL hook_SB_showHealthEntry(id self, SEL _cmd) {
    return YES;
}

// ============================================================
// 初始化
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if ([procName hasPrefix:@"systemd"] || [procName hasPrefix:@"launchd"]) return;
        
        NSLog(@"========================================");
        NSLog(@"[BatteryHealthFix v1.4] 精准修复版");
        NSLog(@"[BHF] 目标 DesignedCapacity → %d mAh", kNewCellDesignedCapacity);
        NSLog(@"[BHF] 进程: %@ (PID %d)", procName, getpid());
        NSLog(@"========================================");
        
        // IORegistry（核心）
        MSHookFunction(
            (void *)IORegistryEntryCreateCFProperty,
            (void *)hook_IORegistryEntryCreateCFProperty,
            (void **)&orig_IORegistryEntryCreateCFProperty
        );
        NSLog(@"[BHF] ✅ Hooked IORegistryEntryCreateCFProperty");
        
        // NSUserDefaults
        MSHookMessageEx(
            [NSUserDefaults class], @selector(objectForKey:),
            (IMP)hook_NSUD_objectForKey, (IMP *)&orig_NSUD_objectForKey
        );
        NSLog(@"[BHF] ✅ Hooked NSUserDefaults");
        
        // SpringBoard
        if ([procName isEqualToString:@"SpringBoard"]) {
            NSArray *classes = @[
                @"BatteryHealthViewController",
                @"BatteryDetailViewController",
                @"BatterySettingsController",
                @"PSSettingsController"
            ];
            NSArray *methods = @[
                @"shouldShowBatteryHealth",
                @"showBatteryHealth",
                @"isBatteryHealthAvailable"
            ];
            for (NSString *cls in classes) {
                Class c = NSClassFromString(cls);
                if (!c) continue;
                for (NSString *m in methods) {
                    SEL s = NSSelectorFromString(m);
                    if ([c instancesRespondToSelector:s]) {
                        MSHookMessageEx(c, s, (IMP)hook_SB_showHealthEntry, NULL);
                        NSLog(@"[BHF/SB] ✅ Hooked %@.%@", cls, m);
                    }
                }
            }
        }
        
        NSLog(@"[BHF] 初始化完成");
    }
}
