#import "ICIdlePulse.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import "LockStateMonitor.h"
#import <string.h>

// Ignore Objective-C ownership/direction qualifiers; preserve the underlying ABI.
static const char *ICUnqualified(const char *type) {
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}

@implementation ICIdlePulse
+ (BOOL)isAvailable {
    Class factory = NSClassFromString(@"XCDeviceEvent");
    SEL creation = NSSelectorFromString(@"deviceEventWithPage:usage:duration:");
    SEL submission = NSSelectorFromString(@"performDeviceEvent:error:");
    id device = XCUIDevice.sharedDevice;
    if (!factory || ![factory respondsToSelector:creation] || ![device respondsToSelector:submission]) return NO;
    @try {
        NSMethodSignature *make = [factory methodSignatureForSelector:creation];
        NSMethodSignature *send = [device methodSignatureForSelector:submission];
        if (!make || !send || make.numberOfArguments != 5 || send.numberOfArguments != 4) return NO;
        const char *result = ICUnqualified(send.methodReturnType);
        return strcmp(ICUnqualified(make.methodReturnType), "@") == 0
            && strcmp(ICUnqualified([make getArgumentTypeAtIndex:2]), "I") == 0
            && strcmp(ICUnqualified([make getArgumentTypeAtIndex:3]), "I") == 0
            && strcmp(ICUnqualified([make getArgumentTypeAtIndex:4]), "d") == 0
            && (strcmp(result, "B") == 0 || strcmp(result, "c") == 0)
            && strcmp(ICUnqualified([send getArgumentTypeAtIndex:2]), "@") == 0
            && strcmp(ICUnqualified([send getArgumentTypeAtIndex:3]), "^@") == 0;
    } @catch (__unused NSException *exception) { return NO; }
}

+ (BOOL)isLockedOrUnknown {
    // One authority: successful reads can recover only the existing monitor's
    // registration, while unknown/locked reads advance its invalidation epoch.
    NSDictionary<NSString *, NSNumber *> *health = [LockStateMonitor.sharedMonitor refreshHealth];
    return !health[@"registered"].boolValue || !health[@"state_known"].boolValue || health[@"locked"].boolValue;
}

+ (NSString *)sendF13 { return [self sendF13Authorized:^BOOL { return YES; }]; }

+ (NSString *)sendF13Authorized:(BOOL (^)(void))authorize {
    if (![NSThread isMainThread] || ![self isAvailable] || [self isLockedOrUnknown] || !authorize()) return @"not_admitted";
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
        if (!event || [self isLockedOrUnknown] || !authorize()) return @"not_admitted";
        NSError *error = nil;
        typedef BOOL (*SubmitEvent)(id, SEL, id, NSError **);
        return ((SubmitEvent)objc_msgSend)(device, submission, event, &error) ? nil : @"event_failed";
    } @catch (__unused NSException *exception) {
        return @"event_exception";
    }
}
@end
