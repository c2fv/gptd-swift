#import "ObjCExceptionCatcher.h"
#import <objc/runtime.h>

NSException * _Nullable GPTDCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

// MARK: - XCTestCase failure interception via runtime swizzle

static NSString * const kGPTDInterceptKey = @"GPTDInterceptingTestFailures";
static NSString * const kGPTDCapturedKey  = @"GPTDCapturedTestFailures";

static IMP sOriginalRecordIssueIMP = NULL;
static BOOL sSwizzled = NO;

static void gptd_swizzledRecordIssue(id self, SEL _cmd, id issue) {
    NSMutableDictionary *threadDict = NSThread.currentThread.threadDictionary;
    if ([threadDict[kGPTDInterceptKey] boolValue]) {
        threadDict[kGPTDCapturedKey] = @YES;
        return;
    }
    if (sOriginalRecordIssueIMP) {
        ((void (*)(id, SEL, id))sOriginalRecordIssueIMP)(self, _cmd, issue);
    }
}

static void gptd_ensureSwizzled(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"XCTestCase");
        if (!cls) return;

        SEL sel = NSSelectorFromString(@"recordIssue:");
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) return;

        sOriginalRecordIssueIMP = method_setImplementation(method, (IMP)gptd_swizzledRecordIssue);
        sSwizzled = YES;
    });
}

BOOL GPTDWithInterceptedTestFailures(NS_NOESCAPE void (^block)(void)) {
    gptd_ensureSwizzled();
    if (!sSwizzled) {
        block();
        return NO;
    }

    NSMutableDictionary *threadDict = NSThread.currentThread.threadDictionary;
    NSNumber *previousIntercept = threadDict[kGPTDInterceptKey];
    NSNumber *previousCaptured  = threadDict[kGPTDCapturedKey];

    threadDict[kGPTDInterceptKey] = @YES;
    threadDict[kGPTDCapturedKey]  = @NO;

    BOOL captured = NO;
    @try {
        block();
    } @finally {
        captured = [threadDict[kGPTDCapturedKey] boolValue];

        threadDict[kGPTDInterceptKey] = previousIntercept ?: @NO;
        threadDict[kGPTDCapturedKey]  = previousCaptured  ?: @NO;

        // Propagate captured flag to outer scope when calls are nested.
        if (captured && [threadDict[kGPTDInterceptKey] boolValue]) {
            threadDict[kGPTDCapturedKey] = @YES;
        }
    }

    return captured;
}
