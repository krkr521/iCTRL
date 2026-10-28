#import "ICFileNotificationBootstrap.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

/// Only handles user-selected file notices before XCTest setUp installs its delegate.
/// No event is generated merely because a notification arrives.
@interface ICFileNotificationBootstrap () <UNUserNotificationCenterDelegate>
@property (nonatomic, weak) id<UNUserNotificationCenterDelegate> previous;
@end
@implementation ICFileNotificationBootstrap
+ (void)install {
    static ICFileNotificationBootstrap *delegate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        delegate = [ICFileNotificationBootstrap new];
        UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
        delegate.previous = center.delegate;
        center.delegate = delegate;
    });
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
        withCompletionHandler:(void (^)(void))completion {
    UNNotificationContent *content = response.notification.request.content;
    NSString *action = response.actionIdentifier;
    if ([content.categoryIdentifier isEqualToString:@"ICTRL_FILE_TRANSFER"]) {
        id value = content.userInfo[@"file_transfer_id"];
        if (([action isEqualToString:UNNotificationDefaultActionIdentifier]
             || [action isEqualToString:@"ICTRL_OPEN_RECEIVED_FILES"])
            && [value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value] != nil) {
            NSURLComponents *parts = [NSURLComponents new];
            parts.scheme = @"ictrl-app"; parts.host = @"files";
            parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:value]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIApplication.sharedApplication openURL:parts.URL options:@{} completionHandler:^(__unused BOOL success) { completion(); }];
            });
        } else { completion(); }
        return;
    }
    id<UNUserNotificationCenterDelegate> prior = self.previous;
    if ([prior respondsToSelector:_cmd]) {
        [prior userNotificationCenter:center didReceiveNotificationResponse:response withCompletionHandler:completion];
    } else { completion(); }
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
      willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    id<UNUserNotificationCenterDelegate> prior = self.previous;
    if ([prior respondsToSelector:_cmd]) {
        [prior userNotificationCenter:center willPresentNotification:notification withCompletionHandler:completion];
    } else { completion(UNNotificationPresentationOptionList); }
}
@end
