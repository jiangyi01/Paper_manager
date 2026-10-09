#import "PaperDeckObjCSupport.h"

#if !__has_feature(objc_arc)
#error "PaperDeckObjCSupport needs ARC: the caught exception is returned to Swift as a strong reference."
#endif

NSException * _Nullable PDCatchException(NS_NOESCAPE void (^body)(void)) {
    @try {
        body();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
