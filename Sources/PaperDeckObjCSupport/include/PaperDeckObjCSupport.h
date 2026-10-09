// Objective-C shims Swift can't express (R-PDFKIT-2). Swift can't catch an Objective-C exception,
// and an uncaught one aborts the process.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `body` and returns the Objective-C exception it threw, or nil when it returned normally.
/// For a single framework call known to throw under a race (PDFKit's `PDFPage.attributedString`:
/// "object cannot be nil (key: NSFont)"). The frames between the throw and this catch are unwound
/// without running their cleanup, so `body` must not take locks, open scopes or own resources itself.
NSException * _Nullable PDCatchException(NS_NOESCAPE void (^body)(void));

NS_ASSUME_NONNULL_END
