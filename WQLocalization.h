//
//  WQLocalization.h
//  WQ Files
//
//  Shared runtime localization helpers. English source strings are the keys;
//  zh-Hans.lproj supplies the Chinese translations and en.lproj is the
//  identity fallback.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *WQLocalized(NSString *key);
NSString *_Nullable WQLocalizedNullable(NSString *_Nullable text);
NSString *WQLocalizedFormat(NSString *key, ...) NS_FORMAT_FUNCTION(1, 2);

NS_ASSUME_NONNULL_END
