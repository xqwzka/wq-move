//
//  WQLocalization.h
//  WQ Files
//
//  Shared runtime localization helpers. English source strings are the keys;
//  the <lang>.lproj tables supply the translations and en.lproj is the
//  identity fallback.
//
//  Keys and presentation text are different things. WQLocalized and every
//  helper that takes a key (wq_alert_controller, wq_alert_action, wq_alert,
//  WQLocalizedNullable) look the text up. Text that is already localized, or
//  raw data (file, plist key, column, app names, error strings), must be
//  wrapped in WQVerbatim so it is shown exactly as it is: in Italian "Date"
//  becomes "Data", which would otherwise be translated again to "Dati".
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *WQLocalized(NSString *key);
NSString *_Nullable WQLocalizedNullable(NSString *_Nullable text);
NSString *WQLocalizedFormat(NSString *key, ...) NS_FORMAT_FUNCTION(1, 2);

// Marks text as final presentation text: the key-taking helpers return it
// unchanged. The mark is kept by -copy but not by derived strings
// (appending, formatting), so wrap the final string.
NSString *_Nullable WQVerbatim(NSString *_Nullable text);
BOOL WQIsVerbatim(NSString *_Nullable text);

NS_ASSUME_NONNULL_END
