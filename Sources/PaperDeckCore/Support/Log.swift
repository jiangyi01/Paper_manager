import Foundation
import os
import PaperDeckShared

/// os_log categories under the build's subsystem (`BuildIdentity.current.logSubsystem`: the app's
/// bundle id, so a build with the script's defaults logs under the same subsystem as before).
/// Inspect with: log show --last 10m --info --predicate 'subsystem == "<bundle id>"'
/// (`PaperDeck --config` prints the bundle id).
package enum Log {
    package static let subsystem = BuildIdentity.current.logSubsystem
    package static let app = Logger(subsystem: subsystem, category: "app")
    package static let db = Logger(subsystem: subsystem, category: "db")
    package static let importer = Logger(subsystem: subsystem, category: "import")
    package static let metadata = Logger(subsystem: subsystem, category: "metadata")
    package static let agent = Logger(subsystem: subsystem, category: "agent")
    package static let plan = Logger(subsystem: subsystem, category: "plan")
    package static let reminder = Logger(subsystem: subsystem, category: "reminder")
    package static let widget = Logger(subsystem: subsystem, category: "widget")
    package static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Interactive reading assist (gate verdicts, lane); never content.
    package static let assist = Logger(subsystem: subsystem, category: "assist")
}
