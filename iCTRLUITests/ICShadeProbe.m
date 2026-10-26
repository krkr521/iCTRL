#import "ICShadeProbe.h"
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

@implementation ICShadeProbe

+ (NSDictionary<NSString *, id> *)inspectAndAttemptRestore:(BOOL)attemptRestore {
    static BOOL attemptedInThisProcess = NO;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSMutableDictionary<NSString *, id> *result = [@{
        @"class_available": @NO,
        @"session_available": @NO,
        @"selector_available": @NO,
        @"attempted": @NO,
        @"returned": [NSNull null],
        @"error_domain": [NSNull null],
        @"error_code": [NSNull null],
    } mutableCopy];

    @try {
      do {
        // iOS 26.4 XCTest private header declares this class method. Use the
        // non-initiating variant so inspection cannot create an XPC session.
        Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
        if (!sessionClass) { break; }
        result[@"class_available"] = @YES;

        SEL existingSessionSelector = NSSelectorFromString(@"sharedSessionIfInitiated");
        if (![sessionClass respondsToSelector:existingSessionSelector]) { break; }
        id (*getExistingSession)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id session = getExistingSession(sessionClass, existingSessionSelector);
        if (!session) { break; }
        result[@"session_available"] = @YES;

        // XCUIDeviceAutomationModeInterface (iOS 26.4) declares exactly
        // - (BOOL)enableAutomationModeWithError:(id *)error. Do not invoke any
        // other initialization, disable, or simulated-user-presence method.
        SEL enableSelector = NSSelectorFromString(@"enableAutomationModeWithError:");
        if (![session respondsToSelector:enableSelector]) { break; }
        result[@"selector_available"] = @YES;
        if (!attemptRestore) { break; }

        BOOL mayAttempt = NO;
        @synchronized(self) {
            mayAttempt = !attemptedInThisProcess;
            // Burn the one-shot BEFORE the private synchronous call. If the
            // client times out ambiguously, a retry cannot execute it again.
            if (mayAttempt) { attemptedInThisProcess = YES; }
        }
        if (!mayAttempt) {
            result[@"error_domain"] = @"ICShadeProbe.AlreadyAttempted";
            result[@"error_code"] = @(1);
            break;
        }
        result[@"attempted"] = @YES;
        NSError *error = nil;
        BOOL (*enableOnce)(id, SEL, NSError **) = (BOOL (*)(id, SEL, NSError **))objc_msgSend;
        BOOL returned = enableOnce(session, enableSelector, &error);
        result[@"returned"] = @(returned);
        if (error) {
            result[@"error_domain"] = error.domain ?: [NSNull null];
            result[@"error_code"] = @(error.code);
        }
      } while (NO);
    } @catch (NSException *exception) {
        // No exception reason/name/userInfo: they may contain implementation
        // details and are not needed by this one-shot probe.
        result[@"returned"] = [NSNull null];
        result[@"error_domain"] = @"ICShadeProbe.Exception";
        result[@"error_code"] = @(-1);
    }

    result[@"elapsed_ms"] = @((CFAbsoluteTimeGetCurrent() - start) * 1000.0);
    return [result copy];
}

@end
