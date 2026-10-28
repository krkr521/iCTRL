#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ICIdlePulse : NSObject
/// Read-only runtime ABI check. Does not create or submit an event.
+ (BOOL)isAvailable;
/// nil means the event returned success, not proof of cross-app Auto-Lock behavior.
+ (nullable NSString *)sendF13;
/// Authorization is rechecked on main immediately before the private event.
+ (nullable NSString *)sendF13Authorized:(BOOL (^)(void))authorize NS_SWIFT_NAME(sendF13(authorize:));
/// Fresh lock notification state; failure is treated as locked. Never unlocks.
+ (BOOL)isLockedOrUnknown;
@end
NS_ASSUME_NONNULL_END
