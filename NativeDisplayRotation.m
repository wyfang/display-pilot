#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// MonitorPanel's native API is also used by displayplacer (MIT):
// https://github.com/jakehilborn/displayplacer/blob/c23026eb3d73000eb1a14b45d82fd6dd08c921f5/src/MonitorPanel.m
// These minimal declarations are independent of its implementation or headers.
@protocol DPNativeDisplay <NSObject>
- (instancetype)initWithCGSDisplayID:(int)displayID;
- (void)setOrientation:(int)orientation;
- (BOOL)canChangeOrientation;
@end

enum DPNativeRotationStatus {
    DPNativeRotationAccepted = 0,
    DPNativeRotationInvalidArgument = 1,
    DPNativeRotationFrameworkUnavailable = 2,
    DPNativeRotationMethodUnavailable = 3,
    DPNativeRotationIncompatibleABI = 4,
    DPNativeRotationDisplayUnavailable = 5,
    DPNativeRotationUnsupported = 6,
    DPNativeRotationException = 7
};

static BOOL DPMethodHasABI(Method method, const char *returnType, unsigned int argumentCount) {
    if (method == NULL || method_getNumberOfArguments(method) != argumentCount) return NO;
    char *actualReturnType = method_copyReturnType(method);
    BOOL matches = actualReturnType != NULL && strcmp(actualReturnType, returnType) == 0;
    free(actualReturnType);
    if (!matches) return NO;
    if (argumentCount == 3) {
        char *actualArgumentType = method_copyArgumentType(method, 2);
        matches = actualArgumentType != NULL && strcmp(actualArgumentType, @encode(int)) == 0;
        free(actualArgumentType);
    }
    return matches;
}

// Keep MPDisplay alive until Quartz confirms the asynchronous change.
static NSMutableDictionary<NSNumber *, id<DPNativeDisplay>> *DPPendingDisplays;

void DisplayPilotFinishNativeRotation(uint32_t displayID) {
    if ([NSThread isMainThread]) [DPPendingDisplays removeObjectForKey:@(displayID)];
}

// Success acknowledges dispatch only. The Swift controller verifies Quartz's
// actual angle asynchronously, using the same degrees without a 90/270 swap.
int32_t DisplayPilotRequestNativeRotation(uint32_t displayID, int32_t orientation) {
    if (displayID == kCGNullDirectDisplay ||
        !(orientation == 0 || orientation == 90 || orientation == 180 || orientation == 270)) {
        return DPNativeRotationInvalidArgument;
    }
    if (![NSThread isMainThread] || CGDisplayIsActive(displayID) == 0) {
        return DPNativeRotationDisplayUnavailable;
    }

    static void *framework = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY | RTLD_LOCAL);
    });
    if (framework == NULL) return DPNativeRotationFrameworkUnavailable;

    Class displayClass = NSClassFromString(@"MPDisplay");
    if (displayClass == Nil) return DPNativeRotationMethodUnavailable;
    SEL initialize = @selector(initWithCGSDisplayID:);
    SEL rotate = @selector(setOrientation:);
    Method initializeMethod = class_getInstanceMethod(displayClass, initialize);
    Method rotateMethod = class_getInstanceMethod(displayClass, rotate);
    if (initializeMethod == NULL || rotateMethod == NULL) return DPNativeRotationMethodUnavailable;
    // arm64 runtime verified: init @20@0:8i16; setter v20@0:8i16.
    if (!DPMethodHasABI(initializeMethod, @encode(id), 3) ||
        !DPMethodHasABI(rotateMethod, @encode(void), 3)) {
        return DPNativeRotationIncompatibleABI;
    }

    id<DPNativeDisplay> display = nil;
    @try {
        display = [[displayClass alloc] initWithCGSDisplayID:(int)displayID];
        if (display == nil) return DPNativeRotationDisplayUnavailable;
        Method supportedMethod = class_getInstanceMethod(displayClass, @selector(canChangeOrientation));
        if (supportedMethod != NULL) {
            if (!DPMethodHasABI(supportedMethod, @encode(BOOL), 2)) return DPNativeRotationIncompatibleABI;
            if (![display canChangeOrientation]) return DPNativeRotationUnsupported;
        }
        if (CGDisplayIsActive(displayID) == 0) return DPNativeRotationDisplayUnavailable;
        if (DPPendingDisplays == nil) DPPendingDisplays = [NSMutableDictionary new];
        DPPendingDisplays[@(displayID)] = display;
        [display setOrientation:(int)orientation];
        return DPNativeRotationAccepted;
    } @catch (NSException *exception) {
        (void)exception;
        [DPPendingDisplays removeObjectForKey:@(displayID)];
        return DPNativeRotationException;
    } @finally {
#if !__has_feature(objc_arc)
        [display release];
#endif
    }
}
