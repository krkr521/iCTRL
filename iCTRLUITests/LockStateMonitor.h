#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LockStateMonitor : NSObject

+ (instancetype)sharedMonitor;

@property (nonatomic, readonly) BOOL isLocked;
/// False when registration or initial state read failed. Never assume unlocked.
@property (nonatomic, readonly) BOOL monitorAvailable;
/// Called outside the monitor lock on its independent notification queue.
/// Installing while locked/unknown invokes once immediately; unlock never invokes it.
@property (nonatomic, copy, nullable) void (^onLocked)(void);

- (BOOL)lockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError *__autoreleasing _Nullable * _Nullable)error;
- (BOOL)unlockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError *__autoreleasing _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
