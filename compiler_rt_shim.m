
#import <Foundation/Foundation.h>
#import <stdint.h>
// compiler-rt availability builtin（Linux 无 darwin compiler-rt，手写等价实现）
// 语义：当前系统版本 >= (major,minor,patch) 返回 1；本 tweak 仅 rootless Dopamine（iOS 15+）
// 供 @available(iOS 16.0, *) 等检查链接使用，两个下划线拼写都提供
static int32_t af_platform_at_least(int32_t major, int32_t minor, int32_t patch) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (v.majorVersion != major) return v.majorVersion > major ? 1 : 0;
    if (v.minorVersion != minor) return v.minorVersion > minor ? 1 : 0;
    return v.patchVersion >= patch ? 1 : 0;
}
int32_t __isPlatformVersionAtLeast(const char *platformName, int32_t major, int32_t minor, int32_t patch) {
    (void)platformName;
    return af_platform_at_least(major, minor, patch);
}
int32_t ___isPlatformVersionAtLeast(const char *platformName, int32_t major, int32_t minor, int32_t patch) {
    (void)platformName;
    return af_platform_at_least(major, minor, patch);
}
