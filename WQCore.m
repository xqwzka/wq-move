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

// Stops as soon as a byte beyond maxBytes would be produced, so the output
// never grows past the caller's bound.
static NSData *WQParseHexBounded(NSString *text, BOOL allowAngleBrackets, NSUInteger maxBytes)
{
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableData *out = [NSMutableData dataWithCapacity:MIN(maxBytes, (NSUInteger)4096)];
    int high = -1;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([spaces characterIsMember:c] || (allowAngleBrackets && (c == '<' || c == '>'))) continue;
        uint8_t value = 0;
        if (!WQHexValue(c, &value)) return nil;
        if (high < 0) {
            if (out.length >= maxBytes) return nil;   // a byte past the bound would start here
            high = value;
        } else {
            uint8_t byte = (uint8_t)((high << 4) | value);
            [out appendBytes:&byte length:1];
            high = -1;
        }
    }
    return high < 0 ? out : nil;
}

NSData *WQParseHex(NSString *text, BOOL allowAngleBrackets)
{
    return WQParseHexBounded(text, allowAngleBrackets, NSUIntegerMax);
}

NSUInteger WQHexExactInputCharacterLimit(NSUInteger count)
{
    // Two digits per byte plus generous separators/padding; saturates instead
    // of wrapping for absurd counts.
    if (count > (NSUIntegerMax - 256) / 4) return NSUIntegerMax;
    return count * 4 + 256;
}

NSData *WQParseHexExactly(NSString *text, NSUInteger count)
{
    if (!text || text.length > WQHexExactInputCharacterLimit(count)) return nil;
    NSData *bytes = WQParseHexBounded(text, NO, count);
    return bytes.length == count ? bytes : nil;
}

BOOL WQPatchRangeValid(unsigned long long offset, NSUInteger length, unsigned long long fileSize)
{
    return offset <= fileSize && length <= fileSize - offset;
}

NSDictionary<NSString *, NSNumber *> *WQRestorePlan(BOOL hasDocuments, BOOL hasLibrary)
{
    return @{ @"Documents": @(hasDocuments), @"Library": @(hasLibrary) };
}
