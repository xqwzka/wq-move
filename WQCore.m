//
//  WQCore.m
//  WQ Files
//
//  GPL-3.0-or-later.
//

#import "WQCore.h"

@implementation WQEditState

- (void)noteChange
{
    _revision++;
    _dirty = YES;
}

- (NSUInteger)beginSave
{
    _saving = YES;
    return _revision;
}

- (void)finishSave:(BOOL)success revision:(NSUInteger)savedRevision
{
    _saving = NO;
    if (success && _revision == savedRevision) _dirty = NO;
}

- (void)discard
{
    _revision++;
    _dirty = NO;
}

@end

static BOOL WQHexValue(unichar c, uint8_t *value)
{
    if (c >= '0' && c <= '9') *value = (uint8_t)(c - '0');
    else if (c >= 'a' && c <= 'f') *value = (uint8_t)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') *value = (uint8_t)(c - 'A' + 10);
    else return NO;
    return YES;
}

NSData *WQParseHex(NSString *text, BOOL allowAngleBrackets)
{
    NSMutableData *out = [NSMutableData new];
    int high = -1;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c] ||
            (allowAngleBrackets && (c == '<' || c == '>'))) continue;
        uint8_t value = 0;
        if (!WQHexValue(c, &value)) return nil;
        if (high < 0) high = value;
        else {
            uint8_t byte = (uint8_t)((high << 4) | value);
            [out appendBytes:&byte length:1];
            high = -1;
        }
    }
    return high < 0 ? out : nil;
}

BOOL WQPatchRangeValid(unsigned long long offset, NSUInteger length, unsigned long long fileSize)
{
    return offset <= fileSize && length <= fileSize - offset;
}

NSDictionary<NSString *, NSNumber *> *WQRestorePlan(BOOL hasDocuments, BOOL hasLibrary)
{
    return @{ @"Documents": @(hasDocuments), @"Library": @(hasLibrary) };
}
