#import "ICIdlePulse.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <notify.h>

@implementation ICIdlePulse
+ (BOOL)isLockedOrUnknown {
    // Query the initial value too: the older monitor defaults to unlocked until
    // its first notification and is unsuitable as a keep-awake admission guard.
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK) return YES;
    uint64_t value = UINT64_MAX;
    uint32_t status = notify_get_state(token, &value);
    notify_cancel(token);
    return status != NOTIFY_STATUS_OK || value != 0;
}

+ (NSString *)sendF13 {
    if (![NSThread isMainThread] || [self isLockedOrUnknown]) return @"not_admitted";
    @try {
        // Private XCTest selectors, discovered at runtime. This is an independent
        // implementation; Apple documents F13 but does not promise idle reset.
        Class factory = NSClassFromString(@"XCDeviceEvent");
        SEL creation = NSSelectorFromString(@"deviceEventWithPage:usage:duration:");
        SEL submission = NSSelectorFromString(@"performDeviceEvent:error:");
        id device = XCUIDevice.sharedDevice;
        if (!factory || ![factory respondsToSelector:creation] || ![device respondsToSelector:submission]) return @"unsupported";
        typedef id (*CreateEvent)(id, SEL, unsigned int, unsigned int, double);
        id event = ((CreateEvent)objc_msgSend)(factory, creation, 7U, 104U, 0.005);
        if (!event || [self isLockedOrUnknown]) return @"not_admitted";
        NSError *error = nil;
        typedef BOOL (*SubmitEvent)(id, SEL, id, NSError **);
        return ((SubmitEvent)objc_msgSend)(device, submission, event, &error) ? nil : @"event_failed";
    } @catch (__unused NSException *exception) {
        return @"event_exception";
    }
}
@end
