//
//  WQLocalization.m
//  WQ Files
//

#import "WQLocalization.h"

NSString *WQLocalized(NSString *key)
{
    if (!key.length) return key;
    return NSLocalizedString(key, nil);
}

NSString *WQLocalizedNullable(NSString *text)
{
    return text ? WQLocalized(text) : nil;
}

NSString *WQLocalizedFormat(NSString *key, ...)
{
    va_list args;
    va_start(args, key);
    NSString *format = WQLocalized(key);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return text;
}
