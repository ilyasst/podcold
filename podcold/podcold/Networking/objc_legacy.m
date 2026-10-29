#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

// Swift 5.6 emits this allocation entry point even for a pre-iOS-7 target.
// iOS 6's Objective-C runtime provides the equivalent message instead.
id podcold_objc_allocWithZone(Class cls) __asm__("_objc_allocWithZone") NS_RETURNS_RETAINED;
id podcold_objc_allocWithZone(Class cls) {
    return ((id (*)(id, SEL, void *))objc_msgSend)((id)cls,
                                                 sel_registerName("allocWithZone:"),
                                                 (void *)0);
}

// Swift Data's Foundation bridge assumes this iOS 7 method is present. NSData
// on iOS 6 exposes contiguous bytes, so one range implements the same contract.
static void podcold_enumerateByteRanges(NSData *data, SEL selector,
                                      void (^block)(const void *, NSRange, BOOL *)) {
    BOOL stop = NO;
    block([data bytes], NSMakeRange(0, [data length]), &stop);
}

__attribute__((constructor))
static void podcold_installDataCompatibility(void) {
    Class data = objc_getClass("NSData");
    SEL selector = sel_registerName("enumerateByteRangesUsingBlock:");
    if (!class_getInstanceMethod(data, selector)) {
        class_addMethod(data, selector, (IMP)podcold_enumerateByteRanges, "v@:@?");
    }
}
