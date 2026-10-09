import Foundation

/// The reading-assist tables (READING_ASSIST_PLAN §5; DQ §8, LN §7.6): one additive feature,
/// recorded as the row ('assist', 1) of `schema_feature` — `user_version` stays the core's 1 and
/// the mail row is untouched, so an older build (whose gate reads only those two) still opens the
/// library and ignores these tables. Every table hangs off `paper(pk)` with ON DELETE CASCADE /
/// SET NULL, so an older build's hard delete (foreign_keys = ON per connection) cleans up after itself.
///
/// The CHECK lists are frozen once shipped: widening one needs ('assist', 2). Writers by slice:
/// `paper_key`, `paper_fingerprint`, `paper_history`, `dup_review`, `dup_pair`, `reading_cycle` —
/// dedupe (B); `paper_policy` — Slice 0 (`Database+Policy`); `qa_*` — Q&A (C); `explanation` — Explain (A).
extension Migrations {
    /// The tables the feature creates, in creation order (also how an existing set is recognised).
    package static let assistTables = [
        "paper_key", "paper_fingerprint", "paper_history", "dup_review", "dup_pair", "reading_cycle",
        "paper_policy", "qa_thread", "qa_thread_paper", "qa_message", "explanation",
    ]

    /// Its indexes.
    package static let assistIndexes = [
        "ix_paper_key_paper", "ix_history_sha", "ix_history_doi", "ix_history_arxiv", "ix_dup_review_open",
        "ix_dup_review_new", "ix_qa_thread_paper", "ix_qa_message_thread", "ix_explanation_paper",
        "ix_explanation_thread",
    ]

    static let schemaAssist = """
    CREATE TABLE paper_key(paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK(kind IN('doi','arxiv','preprint_doi','published_doi','version_doi','openalex','pmid','pmcid')),
      value TEXT NOT NULL COLLATE NOCASE, source TEXT NOT NULL,
      PRIMARY KEY(kind, value, paper_pk)) WITHOUT ROWID;
    CREATE INDEX ix_paper_key_paper ON paper_key(paper_pk);
    CREATE TABLE paper_fingerprint(paper_pk INTEGER PRIMARY KEY REFERENCES paper(pk) ON DELETE CASCADE,
      algo INTEGER NOT NULL, title_norm TEXT NOT NULL, first_surname TEXT, surnames_json TEXT NOT NULL DEFAULT '[]',
      year INTEGER, version_rank INTEGER, minhash BLOB, embedding BLOB, embed_model TEXT,
      source_updated_at TEXT NOT NULL, computed_at TEXT NOT NULL);
    CREATE TABLE paper_history(pk INTEGER PRIMARY KEY, paper_id TEXT NOT NULL, sha256 TEXT,
      doi TEXT COLLATE NOCASE, arxiv_id TEXT, published_doi TEXT COLLATE NOCASE, keys_json TEXT NOT NULL DEFAULT '[]',
      title TEXT NOT NULL, title_norm TEXT NOT NULL, first_surname TEXT, year INTEGER, minhash BLOB,
      last_status TEXT NOT NULL, read_count INTEGER NOT NULL DEFAULT 0, done_at TEXT, added_at TEXT, purged_at TEXT NOT NULL);
    CREATE INDEX ix_history_sha ON paper_history(sha256);
    CREATE INDEX ix_history_doi ON paper_history(doi) WHERE doi IS NOT NULL;
    CREATE INDEX ix_history_arxiv ON paper_history(arxiv_id) WHERE arxiv_id IS NOT NULL;
    CREATE TABLE dup_review(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      new_paper_pk INTEGER REFERENCES paper(pk) ON DELETE CASCADE,
      pending_id TEXT, staged_name TEXT,
      existing_paper_pk INTEGER REFERENCES paper(pk) ON DELETE CASCADE,
      history_pk INTEGER REFERENCES paper_history(pk) ON DELETE CASCADE,
      band TEXT NOT NULL CHECK(band IN('certain','likely','possible')), relation TEXT NOT NULL, score REAL NOT NULL,
      evidence_json TEXT NOT NULL, newer_side TEXT CHECK(newer_side IN('new','existing') OR newer_side IS NULL),
      origin TEXT NOT NULL CHECK(origin IN('intake','enrich','scan','mail')), batch_id TEXT,
      held_schedule_json TEXT, ai_state TEXT NOT NULL DEFAULT 'none', ai_verdict_json TEXT,
      state TEXT NOT NULL DEFAULT 'open' CHECK(state IN('open','resolved','expired','dismissed')),
      choice TEXT, created_at TEXT NOT NULL, resolved_at TEXT);
    CREATE INDEX ix_dup_review_open ON dup_review(state, created_at) WHERE state = 'open';
    CREATE INDEX ix_dup_review_new ON dup_review(new_paper_pk);
    CREATE TABLE dup_pair(a_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      b_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      decision TEXT NOT NULL CHECK(decision IN('distinct','related')),
      relation TEXT, decided_by TEXT NOT NULL CHECK(decided_by IN('user','ai')), decided_at TEXT NOT NULL,
      PRIMARY KEY(a_pk, b_pk), CHECK(a_pk < b_pk)) WITHOUT ROWID;
    CREATE TABLE reading_cycle(paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE, n INTEGER NOT NULL,
      started_at TEXT NOT NULL, done_at TEXT, reason TEXT, PRIMARY KEY(paper_pk, n)) WITHOUT ROWID;
    CREATE TABLE paper_policy(paper_pk INTEGER PRIMARY KEY REFERENCES paper(pk) ON DELETE CASCADE,
      confidential INTEGER NOT NULL DEFAULT 0, never_ai INTEGER NOT NULL DEFAULT 0,
      set_by TEXT NOT NULL, set_at TEXT NOT NULL);
    CREATE TABLE qa_thread(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      scope TEXT NOT NULL CHECK(scope IN('paper','multi')),
      title TEXT NOT NULL, lang TEXT NOT NULL DEFAULT 'auto', context_mode TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE qa_thread_paper(thread_pk INTEGER NOT NULL REFERENCES qa_thread(pk) ON DELETE CASCADE,
      paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE, ord INTEGER NOT NULL,
      PRIMARY KEY(thread_pk, paper_pk)) WITHOUT ROWID;
    CREATE INDEX ix_qa_thread_paper ON qa_thread_paper(paper_pk);
    CREATE TABLE qa_message(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      thread_pk INTEGER NOT NULL REFERENCES qa_thread(pk) ON DELETE CASCADE, ord INTEGER NOT NULL,
      role TEXT NOT NULL CHECK(role IN('user','assistant')), text TEXT NOT NULL, citations_json TEXT, lang TEXT,
      provider TEXT, model TEXT, depth TEXT, context_json TEXT,
      state TEXT NOT NULL DEFAULT 'done' CHECK(state IN('streaming','done','failed','cancelled')), error_kind TEXT,
      duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL, created_at TEXT NOT NULL);
    CREATE INDEX ix_qa_message_thread ON qa_message(thread_pk, ord);
    CREATE TABLE explanation(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      paper_pk INTEGER REFERENCES paper(pk) ON DELETE SET NULL,
      thread_id TEXT NOT NULL, turn INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL CHECK(source IN('services','clipboard','screenshot','region','lens','reader','drop')),
      action TEXT NOT NULL, lang TEXT NOT NULL CHECK(lang IN('en','zh')),
      page INTEGER, match_via TEXT, match_score REAL,
      excerpt TEXT, question TEXT, answer TEXT NOT NULL, had_image INTEGER NOT NULL DEFAULT 0, thumb_path TEXT,
      provider TEXT NOT NULL, model TEXT, duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER, cost_usd REAL,
      pinned INTEGER NOT NULL DEFAULT 0, saved_to_notes_at TEXT, created_at TEXT NOT NULL);
    CREATE INDEX ix_explanation_paper ON explanation(paper_pk, created_at);
    CREATE INDEX ix_explanation_thread ON explanation(thread_id, turn);
    """
}
