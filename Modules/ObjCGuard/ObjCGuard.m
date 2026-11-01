#import "ObjCGuard.h"
#import <objc/runtime.h>

NSException *VLTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

static void VLScanMethods(Class cls, const char *marker, NSString *className,
                          NSRegularExpression *regex, BOOL classMatches,
                          NSMutableArray<NSString *> *out) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSRange range = NSMakeRange(0, name.length);
        if (classMatches || [regex firstMatchInString:name options:0 range:range]) {
            [out addObject:[NSString stringWithFormat:@"%s[%@ %@]", marker, className, name]];
        }
    }
    free(methods);
}

NSArray<NSString *> *VLRuntimeScan(NSString *classPrefix, NSString *pattern) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:nil];
    if (regex == nil) {
        return out;
    }
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        NSString *className = [NSString stringWithUTF8String:class_getName(classes[i])];
        if (className == nil || ![className hasPrefix:classPrefix]) {
            continue;
        }
        BOOL classMatches =
            [regex firstMatchInString:className options:0 range:NSMakeRange(0, className.length)] != nil;
        if (classMatches) {
            [out addObject:[NSString stringWithFormat:@"class %@", className]];
        }
        VLScanMethods(classes[i], "-", className, regex, classMatches, out);
        VLScanMethods(object_getClass(classes[i]), "+", className, regex, classMatches, out);
    }
    free(classes);
    return [out sortedArrayUsingSelector:@selector(compare:)];
}
