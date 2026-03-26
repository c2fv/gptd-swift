#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes the given block inside an Objective-C @try/@catch.
/// Returns the caught NSException, or nil if no exception was thrown.
FOUNDATION_EXPORT NSException * _Nullable GPTDCatchObjCException(NS_NOESCAPE void (^block)(void));

/// Executes the given block while intercepting XCTestCase failure recording.
/// Any call to -[XCTestCase recordIssue:] that occurs on the current thread
/// during execution of the block is silently captured instead of being
/// forwarded to XCTest. Returns YES if one or more failures were intercepted.
///
/// Interception is scoped to the block and guaranteed to be cleaned up even
/// if the block exits early (e.g. via an ObjC exception caught by the caller).
FOUNDATION_EXPORT BOOL GPTDWithInterceptedTestFailures(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
