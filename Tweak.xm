/*
 * BatteryHealthFix v1.4 —— 精准修复版
 * 适用：iPhone XS Max, iOS 16.5 (已越狱)
 */

#import <Foundation/Foundation.h>
#import <substrate.h>

extern CFTypeRef IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
);

static CFTypeRef (*orig_IORegistryEntryCreateCFProperty)(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
);

static const int kNewCellDesignedCapacity = 3500;
static const int kPeakPerformanceCapacity = 100;

static CFTypeRef hook_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key,
    CFAllocatorRef allocator, IOOptionBits options
) {
    CFTypeRef realValue = orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (!key) return realValue;
    NSString *keyStr = (__bridge NSString *)key;
    
    // --- 诊断日志 ---
    static NSMutableSet *printedKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ printedKeys = [NSMutableSet set]; });
    
    NSArray *kw = @[@"Battery", @"AppleBattery", @"IOPS", @"Capacity",
                    @"Cycle", @"Peak", @"Serial", @"Pairing", @"UUID"];
    BOOL isBatteryKey = NO;
    for (NSString *k in kw) { if ([keyStr containsString:k]) { isBatteryKey = YES; break; } }
    
    if (isBatteryKey && ![printedKeys containsObject:keyStr]) {
        [printedKeys addObject:keyStr];
        NSLog(@"[BHF/DIAG] %@ → %@", keyStr, realValue ? [(__bridge id)realValue description] : @"nil");
    }
    
    // --- A. DesignedCapacity → 强制改成新电芯标称值 ---
    if ([keyStr isEqualToString:@"BatteryCapacity"] ||
        [keyStr isEqualToString:@"DesignedCapacity"] ||
        [keyStr isEqualToString:@"AppleBatteryDesignCapacity"]) {
        if (realValue) CFRelease(realValue);
        NSLog(@"[BHF] 🔒 %@ → %d", keyStr, kNewCellDesignedCapacity);
        return CFRetain((__bridge CFTypeRef)@(kNewCellDesignedCapacity));
    }
    
    // --- B. PeakPerformance → 强制 100% ---
    if ([keyStr isEqualToString:@"PeakPerformanceCapacity"] ||
        [keyStr isEqualToString:@"BatteryPeakPerformanceCapacity"]) {
        if (realValue) CFRelease(realValue);
        return CFRetain((__bridge CFTypeRef)@(kPeakPerformanceCapacity));
    }
    
    // --- C. 认证键 ---
    if ([keyStr isEqualToString:@"IOPSIsAppleBattery"] ||
        [keyStr isEqualToString:@"IsAppleBattery"] ||
        [keyStr isEqualToString:@"AppleBatteryIsVerified"]) {
        if (!realValue || realValue == kCFBooleanFalse) {
            if (realValue) CFRelease(realValue);
            return CFRetain(kCFBooleanTrue);
        }
        return realValue;
    }
    
    // --- D. 配对键 ---
    if ([keyStr containsString:@"Pairing"] ||
        ([keyStr containsString:@"UUID"] && [keyStr containsString:@"Battery"])) {
        if (!realValue || realValue == kCFBooleanFalse) {
            if (realValue) CFRelease(realValue);
            return CFRetain(kCFBooleanTrue);
        }
        return realValue;
    }
    
    // --- E. 其他键 → 全部放行！---
    return realValue;
}

// NSUserDefaults Hook
static id (*orig_NSUD_objectForKey)(id self, SEL _cmd, NSString *key);
static id hook_NSUD_objectForKey(id self, SEL _cmd, NSString *key) {
    id result = orig_NSUD_objectForKey(self, _cmd, key);
    if ([key containsString:@"PeakPerformance"]) return @100;
    if (([key containsString:@"isAppleBattery"] ||
         [key containsString:@"AppleBatteryVerified"]) &&
        ![key containsString:@"Serial"]) {
        if (!result || [result boolValue] == NO) return @YES;
    }
    return result;
}

// SpringBoard 设置入口
static BOOL hook_SB_showHealthEntry(id self, SEL _cmd) { return YES; }

// 初始化
__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        NSString *procName = [NSProcessInfo processInfo].processName;
        if ([procName hasPrefix:@"systemd"] || [procName hasPrefix:@"launchd"]) return;
        
        NSLog(@"[BatteryHealthFix] v1.4 loaded in %@", procName);
        
        MSHookFunction(
            (void *)IORegistryEntryCreateCFProperty,
            (void *)hook_IORegistryEntryCreateCFProperty,
            (void **)&orig_IORegistryEntryCreateCFProperty
        );
        
        MSHookMessageEx(
            [NSUserDefaults class], @selector(objectForKey:),
            (IMP)hook_NSUD_objectForKey,
            (IMP *)&orig_NSUD_objectForKey
        );
        
        if ([procName isEqualToString:@"SpringBoard"]) {
            NSArray *classes = @[@"BatteryHealthViewController", @"BatteryDetailViewController",
                                  @"BatterySettingsController", @"PSSettingsController"];
            NSArray *methods = @[@"shouldShowBatteryHealth", @"showBatteryHealth",
                                 @"isBatteryHealthAvailable"];
            static BOOL (*orig_show)(id, SEL);
            for (NSString *clsName in classes) {
                Class c = NSClassFromString(clsName);
                if (!c) continue;
                for (NSString *m in methods) {
                    SEL s = NSSelectorFromString(m);
                    if ([c instancesRespondToSelector:s]) {
                        MSHookMessageEx(c, s, (IMP)hook_SB_showHealthEntry, (IMP *)&orig_show);
                        NSLog(@"[BHF/SB] Hooked %@.%@", clsName, m);
                    }
                }
            }
        }
    }
}
