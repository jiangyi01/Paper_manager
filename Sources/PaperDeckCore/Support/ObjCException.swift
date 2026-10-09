import Foundation
import PaperDeckObjCSupport

/// An Objective-C exception caught by `ObjCException.catching` (its name and reason only).
package struct CaughtObjCException: Error, Sendable, Equatable {
    package var name: String
    package var reason: String?

    package init(name: String, reason: String?) {
        self.name = name; self.reason = reason
    }
}

/// Catches an Objective-C exception thrown inside one framework call (R-PDFKIT-2). Swift can't
/// catch one, and an uncaught one aborts the process.
///
/// Wrap only the single call that throws: the frames between the throw and the catch are unwound
/// without running their cleanup, so `body` must not take a lock, open a scope (`defer`,
/// `autoreleasepool`, `PDFKitGate.run`) or own anything that needs releasing. Take those outside.
package enum ObjCException {
    package static func catching<T>(_ body: () -> T) -> Result<T, CaughtObjCException> {
        var value: T?
        if let exception = PDCatchException({ value = body() }) {
            return .failure(CaughtObjCException(name: exception.name.rawValue, reason: exception.reason))
        }
        guard let value else { preconditionFailure("ObjCException.catching: body returned without a value") }
        return .success(value)
    }
}
