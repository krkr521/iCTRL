#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LockStateMonitor : NSObject

+ (instancetype)sharedMonitor;

@property (nonatomic, readonly) BOOL isLocked;
/// Current registration + known state, not a permanent latch after a transient read failure.
@property (nonatomic, readonly) BOOL monitorAvailable;
/// Refreshes only this monitor's registered token. No UIKit/XCTest or re-registration.
/// generation advances on unknown/locked; old leases must never match a later epoch.
- (NSDictionary<NSString *, NSNumber *> *)refreshHealth;
/// Invoked synchronously outside the monitor lock on invalidation, before refresh returns.
/// The generation lets a delayed callback revoke only older leases, never a newer Begin.
@property (nonatomic, copy, nullable) void (^onLocked)(uint64_t generation);

- (BOOL)lockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError *__autoreleasing _Nullable * _Nullable)error;
- (BOOL)unlockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError *__autoreleasing _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
