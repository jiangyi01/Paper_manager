import Foundation
import PaperDeckCore

// The inspector's full copy of one email (MAIL_DESIGN Part A §3). The inbox list snapshot
// (`Engine.mailSnapshot`) carries no email text, so a periodic refresh never reads or compares
// bodies; the inspector and 「发送给 AI 的内容」 load the whole card with `Engine.mailCard(id:)`
// and load it again whenever that email changes (`LibraryChange.mail(pk:)`, or `.mailBulk` for a
// sync batch, a retention purge, Clear All).

/// What the inspector's 「邮件正文」 section shows.
enum MailBodyDisplay: Equatable {
    /// The full card has not arrived yet (the list's copy has no text): a small placeholder.
    case loading
    /// Retention removed the text (the existing purged note).
    case purged
    /// The sanitized text, ready to show (`[cN]` markers kept).
    case text(String)
    /// The email has no text.
    case empty

    /// `list`: the card's message from the list snapshot (never trusted for the text — it has
    /// none, and a stale copy must not be shown); `full`: the same message from
    /// `Engine.mailCard(id:)`, nil until it is loaded. `bodyPurged` is sticky, so either copy
    /// saying so wins (the list may be newer than the loaded card, or the other way round).
    static func resolve(list: MailMessage?, full: MailMessage?) -> MailBodyDisplay {
        if list?.bodyPurged == true || full?.bodyPurged == true { return .purged }
        guard let full else { return .loading }
        let body = MailInboxRules.text(full.bodyText)
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .text(body)
    }
}

/// Loads one email's full card and keeps it current.
enum MailFullCard {
    /// Whether `change` may have changed the email with primary key `pk` (nil: not known yet —
    /// every mail change counts until the first load says which row it is).
    static func affects(_ change: LibraryChange, pk: Int64?) -> Bool {
        switch change {
        case .mail(let changed): return pk == nil || changed == pk
        case .mailBulk: return true
        default: return false
        }
    }

    /// Loads the card of `id` at once, then again after every change of that email, until the
    /// calling task is cancelled (SwiftUI's `.task(id:)` does that when the selection changes).
    /// Changes that arrive while a load runs collapse into one more load. `deliver` gets every
    /// result, nil when the email no longer exists.
    static func follow(id: String, changes: AsyncStream<LibraryChange>,
                       load: @escaping (String) async -> MailCard?,
                       deliver: @escaping (MailCard?) -> Void) async {
        let (wake, wakeUp) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let row = RowKey()
        let forward = Task {
            for await change in changes where affects(change, pk: row.pk) { wakeUp.yield() }
            wakeUp.finish()
        }
        defer {
            forward.cancel()
            wakeUp.finish()
        }
        wakeUp.yield()                                   // the first load
        for await _ in wake {
            guard !Task.isCancelled else { break }
            let card = await load(id)
            guard !Task.isCancelled else { break }
            row.pk = card?.message.pk
            deliver(card)
        }
    }

    /// The row the follower listens for (set by the first load; main actor).
    private final class RowKey {
        var pk: Int64?
    }
}
