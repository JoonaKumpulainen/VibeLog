#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns any NSException it raised. AVFoundation reports invalid
/// capture settings by raising, which Swift cannot catch.
FOUNDATION_EXPORT NSException *_Nullable VLTryCatch(NS_NOESCAPE void (^block)(void));

/// Lists selectors and properties of loaded classes whose name starts with `classPrefix`
/// when the member or class name matches the case-insensitive `pattern`. Read-only.
FOUNDATION_EXPORT NSArray<NSString *> *VLRuntimeScan(NSString *classPrefix, NSString *pattern);

NS_ASSUME_NONNULL_END
