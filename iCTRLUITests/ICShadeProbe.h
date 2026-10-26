#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Development-only probe. Never starts a new XCTest session or schedules retries.
@interface ICShadeProbe : NSObject
+ (NSDictionary<NSString *, id> *)inspectAndAttemptRestore:(BOOL)attemptRestore;
@end

NS_ASSUME_NONNULL_END
