//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>
#import "WQLocalization.h"

NS_ASSUME_NONNULL_BEGIN

static inline UIBarButtonItemStyle wq_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
// Settings → Allow Deleting (on by default). When off, every delete, clear and
// clean action is hidden or refused.
BOOL wq_deleting_allowed(void);
void wq_set_deleting_allowed(BOOL allowed);
// Settings → Keep Data Before Restore (on by default). When off, the safety
// backup an app restore makes first is deleted once the restore succeeded.
BOOL wq_keep_before_restore(void);
void wq_set_keep_before_restore(BOOL keep);
// YES (after telling the user) when deleting is turned off.
BOOL wq_refuse_if_deleting_off(UIViewController *host);
UIAlertController *wq_alert_controller(NSString *_Nullable title, NSString *_Nullable message, UIAlertControllerStyle style);
UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^_Nullable handler)(UIAlertAction *));
NSString *wq_size_text(unsigned long long size);
UIView *wq_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *wq_device_line(void);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);

NS_ASSUME_NONNULL_END
