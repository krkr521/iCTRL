#import "LockStateMonitor.h"
#import <notify.h>
#import <XCTest/XCTest.h>

@interface XCUIDevice (FBPrivate)
- (void)pressLockButton;
@end

#import "../iCTRLCompat/LockHealth/include/ICLockHealthState.h"

@implementation LockStateMonitor {
    ICLockHealthState _health;
    void (^_onLocked)(uint64_t);
    int _notifyToken;
    dispatch_queue_t _notificationQueue;
}

+ (instancetype)sharedMonitor {
    static LockStateMonitor *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedInstance = [[self alloc] init]; });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _health = ICLockHealthMake(false);
        _notifyToken = NOTIFY_TOKEN_INVALID;
        // No callback may inspect the token before registration initialization finishes.
        _notificationQueue = dispatch_queue_create("com.openminis.ictrl.lock-notifications", DISPATCH_QUEUE_SERIAL);
        dispatch_suspend(_notificationQueue);
        int status = notify_register_dispatch("com.apple.springboard.lockstate", &_notifyToken,
            _notificationQueue, ^(int token) {
                [self refreshHealthForToken:token];
            });
        @synchronized (self) { _health = ICLockHealthMake(status == NOTIFY_STATUS_OK && _notifyToken != NOTIFY_TOKEN_INVALID); }
        [self refreshHealth];
        dispatch_resume(_notificationQueue);
        if (status != NOTIFY_STATUS_OK) NSLog(@"iCTRL: Failed to register lock state notifications");
    }
    return self;
}

- (NSDictionary<NSString *, NSNumber *> *)snapshotLocked {
    return @{@"registered": @(_health.registered), @"state_known": @(_health.stateKnown),
             @"locked": @(_health.locked), @"generation": @(_health.generation)};
}

- (NSDictionary<NSString *, NSNumber *> *)refreshHealthForToken:(int)expectedToken {
    void (^callback)(uint64_t) = nil;
    uint64_t generation = 0;
    NSDictionary *snapshot;
    @synchronized (self) {
        // Ignore queued callbacks from a token that has been invalidated/cancelled.
        if (expectedToken != _notifyToken) return [self snapshotLocked];
        uint64_t value = UINT64_MAX;
        uint32_t result = NOTIFY_STATUS_INVALID_TOKEN;
        if (_health.registered && _notifyToken != NOTIFY_TOKEN_INVALID) result = notify_get_state(_notifyToken, &value);
        bool valid = _notifyToken != NOTIFY_TOKEN_INVALID && result != NOTIFY_STATUS_INVALID_TOKEN;
        ICLockHealthObserve(&_health, valid, result == NOTIFY_STATUS_OK, value != 0);
        if (!valid) _notifyToken = NOTIFY_TOKEN_INVALID;
        if (!ICLockHealthReady(_health)) callback = _onLocked;
        generation = _health.generation;
        snapshot = [self snapshotLocked];
    }
    // Never acquire a session lock while holding the monitor lock. The callback
    // must revoke by generation; a concurrent later recovery can admit a new lease.
    if (callback) callback(generation);
    return snapshot;
}

- (NSDictionary<NSString *, NSNumber *> *)refreshHealth {
    int token;
    @synchronized (self) { token = _notifyToken; }
    return [self refreshHealthForToken:token];
}

- (BOOL)isLocked { @synchronized (self) { return !_health.stateKnown || _health.locked; } }
- (BOOL)monitorAvailable { @synchronized (self) { return _health.registered && _health.stateKnown; } }
- (void (^)(uint64_t))onLocked { @synchronized (self) { return _onLocked; } }
- (void)setOnLocked:(void (^)(uint64_t))callback {
    void (^notifyNow)(uint64_t) = nil;
    uint64_t generation;
    @synchronized (self) {
        _onLocked = [callback copy]; generation = _health.generation;
        if (!ICLockHealthReady(_health)) notifyNow = _onLocked;
    }
    if (notifyNow) notifyNow(generation);
}

- (BOOL)lockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (self.isLocked) return YES;

    [[XCUIDevice sharedDevice] pressLockButton];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([NSDate date].timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate) {
        if (self.isLocked) return YES;
        [NSThread sleepForTimeInterval:0.1];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"LockStateMonitor" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"Lock timeout"}];
    }
    return NO;
}

- (BOOL)unlockScreenWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (!self.isLocked) return YES;

    [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
    [NSThread sleepForTimeInterval:1.0];
    [[XCUIDevice sharedDevice] pressButton:XCUIDeviceButtonHome];
    [NSThread sleepForTimeInterval:1.0];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([NSDate date].timeIntervalSinceReferenceDate < deadline.timeIntervalSinceReferenceDate) {
        if (!self.isLocked) return YES;
        [NSThread sleepForTimeInterval:0.1];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"LockStateMonitor" code:2
                    userInfo:@{NSLocalizedDescriptionKey: @"Unlock timeout (passcode may be required)"}];
    }
    return NO;
}

- (void)dealloc {
    int token;
    @synchronized (self) { token = _notifyToken; _notifyToken = NOTIFY_TOKEN_INVALID; }
    if (token != NOTIFY_TOKEN_INVALID) notify_cancel(token);
}

@end
