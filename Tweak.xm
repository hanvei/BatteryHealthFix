/*
 * BatteryHealthFix v1.6 —— 开源实现验证版
 *
 * 签名考证（来自仍在维护的 iOS16 开源插件 Luki120/CycleCount 与 exelban/stats）：
 *   CFTypeRef IORegistryEntryCreateCFProperty(entry, key, allocator, options)
 *   ← 4 参数、按值返回（+1 创建规则）。v1.5 注释里写的 5 参签名是错的（那是
 *     复数版 IORegistryEntryCreateCFProperties 的形状），本版纠正。
 *
 * v1.0.1 翻车真因复盘（对照仓库 v1.4 源码）：
 *   1) 诊断日志用共享 NSMutableSet 记录已打印键，多线程并发读写 → 随机崩溃
 *   2) 全局 hook -[NSUserDefaults objectForKey:] 篡改 PeakPerformance/认证键
 *   3) 伪造 Pairing/IsAppleBattery 键，BatteryService 拿到意外类型 → 数据发布失败
 *   → 三者叠加导致设置页电池项消失。
 *
 * v1.6 原则：零共享状态、零伪造、只改"设计容量"一个语义：
 *   - 单键读取（4参版）：DesignCapacity/DesignedCapacity/AppleBatteryDesignCapacity → 3500
 *   - BatteryData 字典（若内嵌 DesignCapacity）：可变拷贝后只改内嵌值
 *   - 批量读取（5参复数版）：返回字典里的 DesignCapacity → 3500
 *   - 其余一切键原样放行；不 hook NSUserDefaults / 类方法 / 认证配对
 *
 * 编译不使用 ARC（Makefile 已去掉 -fobjc-arc），CF 引用计数全部手工、明确。
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <substrate.h>

/* 手动类型定义（避开 theos vendor IOKit 头与新版 SDK 冲突） */
typedef unsigned int       bhf_io_entry_t;     /* io_registry_entry_t = mach port */
typedef unsigned int       bhf_option_bits_t;  /* IOOptionBits */
typedef int                bhf_kern_return_t;  /* kern_return_t */

static const int32_t kNewCellDesignedCapacity = 3500;

static CFNumberRef bhf_capacity_number(void) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                          &kNewCellDesignedCapacity);
}

static Boolean bhf_key_is_design_capacity(CFStringRef key) {
    return CFStringCompare(key, CFSTR("DesignCapacity"), 0) == kCFCompareEqualTo ||
           CFStringCompare(key, CFSTR("DesignedCapacity"), 0) == kCFCompareEqualTo ||
           CFStringCompare(key, CFSTR("AppleBatteryDesignCapacity"), 0) == kCFCompareEqualTo;
}

/* ============ 单键版：CFTypeRef (*)(entry, key, allocator, options) ============ */

typedef CFTypeRef (*bhf_single_fn)(bhf_io_entry_t, CFStringRef,
                                   CFAllocatorRef, bhf_option_bits_t);
static bhf_single_fn orig_single = NULL;

static CFTypeRef hook_single(bhf_io_entry_t entry, CFStringRef key,
                             CFAllocatorRef allocator, bhf_option_bits_t options) {
    CFTypeRef result = orig_single(entry, key, allocator, options); /* +1 */
    if (!key || !result) return result;

    /* A. 顶层设计容量键 → 3500 */
    if (bhf_key_is_design_capacity(key)) {
        CFRelease(result);
        return bhf_capacity_number(); /* +1 交给调用方 */
    }

    /* B. BatteryData 字典内嵌 DesignCapacity → 拷贝后只改这一个值 */
    if (CFStringCompare(key, CFSTR("BatteryData"), 0) == kCFCompareEqualTo &&
        CFGetTypeID(result) == CFDictionaryGetTypeID() &&
        CFDictionaryContainsKey((CFDictionaryRef)result, CFSTR("DesignCapacity"))) {
        CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault, 0, (CFDictionaryRef)result); /* +1 */
        if (copy) {
            CFNumberRef num = bhf_capacity_number();           /* +1 */
            CFDictionarySetValue(copy, CFSTR("DesignCapacity"), num);
            CFRelease(num);   /* 字典按 kCFType 回调自持一份，这里平衡创建引用 */
            CFRelease(result);
            return copy;      /* +1 交给调用方 */
        }
    }

    /* C. 其余全部原样放行 */
    return result;
}

/* ========= 批量版：kern_return_t (*)(entry, &dict, allocator, options) ========= */

typedef bhf_kern_return_t (*bhf_plural_fn)(bhf_io_entry_t, CFMutableDictionaryRef *,
                                           CFAllocatorRef, bhf_option_bits_t);
static bhf_plural_fn orig_plural = NULL;

static bhf_kern_return_t hook_plural(bhf_io_entry_t entry,
                                     CFMutableDictionaryRef *properties,
                                     CFAllocatorRef allocator,
                                     bhf_option_bits_t options) {
    bhf_kern_return_t kr = orig_plural(entry, properties, allocator, options);
    if (kr == 0 && properties && *properties &&
        CFDictionaryContainsKey(*properties, CFSTR("DesignCapacity"))) {
        CFNumberRef num = bhf_capacity_number();               /* +1 */
        CFDictionarySetValue(*properties, CFSTR("DesignCapacity"), num);
        CFRelease(num);
    }
    return kr;
}

/* ============================== 初始化 ============================== */

__attribute__((constructor))
static void initialize(void) {
    @autoreleasepool {
        void *sym_single = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
        void *sym_plural = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperties");

        if (sym_single)
            MSHookFunction(sym_single, (void *)hook_single, (void **)&orig_single);
        if (sym_plural)
            MSHookFunction(sym_plural, (void *)hook_plural, (void **)&orig_plural);

        NSLog(@"[BHF] v1.6 loaded in %@ (single=%s plural=%s)",
              [NSProcessInfo processInfo].processName,
              sym_single ? "yes" : "no",
              sym_plural ? "yes" : "no");
    }
}
