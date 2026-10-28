#import "LockStateMonitor.h"
#import <notify.h>
#import <XCTest/XCTest.h>

@interface XCUIDevice (FBPrivate)
- (void)pressLockButton;
@end

@implementation LockStateMonitor {
    BOOL _isLocked;
    BOOL _monitorAvailable;
    void (^_onLocked)(void);
    int _notifyToken;
}

+ (instancetype)sharedMonitor {
    static LockStateMonitor *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isLocked = YES;
        _monitorAvailable = NO;
        _notifyToken = NOTIFY_TOKEN_INVALID;
        int status = notify_register_dispatch("com.apple.springboard.lockstate",
                                             &_notifyToken,
                                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                                             ^(int token) {
            void (^callback)(void) = nil;
            @synchronized (self) {
                uint64_t state = UINT64_MAX;
                uint32_t result = notify_get_state(token, &state);
                self->_isLocked = result != NOTIFY_STATUS_OK || state != 0;
                // An unreadable state permanently disables admission until a new monitor.
                if (result != NOTIFY_STATUS_OK) self->_monitorAvailable = NO;
                if (self->_isLocked) callback = self->_onLocked;
            }
            if (callback) callback();
        });
        @synchronized (self) {
            if (status == NOTIFY_STATUS_OK) {
                uint64_t state = UINT64_MAX;
                uint32_t result = notify_get_state(_notifyToken, &state);
                _monitorAvailable = result == NOTIFY_STATUS_OK;
                _isLocked = result != NOTIFY_STATUS_OK || state != 0;
            }
        }
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"iCTRL: Failed to register lock state notifications");
        }
    }
    return self;
}

- (BOOL)isLocked {
    @synchronized (self) { return _isLocked; }
}

- (BOOL)monitorAvailable {
    @synchronized (self) { return _monitorAvailable; }
}

- (void (^)(void))onLocked {
    @synchronized (self) { return _onLocked; }
}

- (void)setOnLocked:(void (^)(void))callback {
    void (^notifyNow)(void) = nil;
    @synchronized (self) {
        _onLocked = [callback copy];
        if (_isLocked) notifyNow = _onLocked;
    }
    if (notifyNow) notifyNow();
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
    if (_notifyToken != NOTIFY_TOKEN_INVALID) notify_cancel(_notifyToken);
}

@end
