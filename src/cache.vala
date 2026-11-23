// The on-disk cache: what the feeds have told us, kept so that the next launch and the next refresh
// only ask for what is new. A SQLite file under ~/.cache/stonks; deleting it costs nothing but one
// full download. Positions and folders are not in here (see Window.save).
namespace Stonks {

public class Cache {
    const int VERSION = 1;
    Sqlite.Database? db;

    public Cache (string path) {
        DirUtils.create_with_parents (Path.get_dirname (path), 0700);
        if (Sqlite.Database.open (path, out db) != Sqlite.OK) {
            db = null;   // no cache: everything still works, it just asks the feeds for more
            return;
        }
        // WAL with synchronous=NORMAL keeps commits off the disk's fsync path without risking the file.
        db.exec ("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL");
        var version = query ("PRAGMA user_version");
        if (version != null && version.step () == Sqlite.ROW && version.column_int (0) != VERSION)
            db.exec (@"DROP TABLE IF EXISTS quotes; DROP TABLE IF EXISTS bars; DROP TABLE IF EXISTS names; DROP TABLE IF EXISTS facts; PRAGMA user_version = $VERSION");
        db.exec ("""
            CREATE TABLE IF NOT EXISTS quotes (symbol TEXT PRIMARY KEY, name TEXT, currency TEXT, kind TEXT, gmtoffset INTEGER, checked INTEGER) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS bars (symbol TEXT, intraday INTEGER, t INTEGER, close REAL, PRIMARY KEY (symbol, intraday, t)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS names (symbol TEXT PRIMARY KEY, name TEXT) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS facts (key TEXT PRIMARY KEY, value INTEGER) WITHOUT ROWID;
        """);
    }

    Sqlite.Statement? query (string sql) {
        Sqlite.Statement statement;
        return db.prepare_v2 (sql, -1, out statement) == Sqlite.OK ? (owned) statement : null;
    }

    // A quote as last stored, or null. 5-minute bars more than a week old are left behind.
    public Quote? load (string symbol, int64 now) {
        if (db == null) return null;
        var row = query ("SELECT name, currency, kind, gmtoffset, checked FROM quotes WHERE symbol = ?");
        row.bind_text (1, symbol);
        if (row.step () != Sqlite.ROW) return null;
        var q = new Quote () {
            symbol = symbol, name = row.column_text (0) ?? symbol, currency = row.column_text (1) ?? "", kind = row.column_text (2) ?? "",
            gmtoffset = row.column_int (3), checked = row.column_int64 (4)
        };
        var bars = query ("SELECT intraday, t, close FROM bars WHERE symbol = ? AND (intraday = 0 OR t >= ?) ORDER BY intraday, t");
        bars.bind_text (1, symbol);
        bars.bind_int64 (2, now - 7 * 86400);
        while (bars.step () == Sqlite.ROW) {
            if (bars.column_int (0) == 0) q.daily.add (bars.column_int64 (1), bars.column_double (2));
            else q.intra.add (bars.column_int64 (1), bars.column_double (2));
        }
        if (q.daily.n == 0) return null;   // Quote promises at least one daily bar
        q.daily.unsaved = q.daily.n;
        q.intra.unsaved = q.intra.n;
        q.price = q.daily.v[q.daily.n - 1];   // the live bar, as of the last refresh
        return q;
    }

    // Store a quote: its details, and whichever of its bars are not on disk yet.
    public void save (Quote q, int64 now) {
        if (db == null) return;
        db.exec ("BEGIN");
        var row = query ("INSERT OR REPLACE INTO quotes (symbol, name, currency, kind, gmtoffset, checked) VALUES (?, ?, ?, ?, ?, ?)");
        row.bind_text (1, q.symbol);
        row.bind_text (2, q.name);
        row.bind_text (3, q.currency);
        row.bind_text (4, q.kind);
        row.bind_int (5, q.gmtoffset);
        row.bind_int64 (6, q.checked);
        row.step ();
        save_bars (q.symbol, 0, q.daily);
        save_bars (q.symbol, 1, q.intra);
        var stale = query ("DELETE FROM bars WHERE symbol = ? AND intraday = 1 AND t < ?");
        stale.bind_text (1, q.symbol);
        stale.bind_int64 (2, now - 8 * 86400);
        stale.step ();
        db.exec ("COMMIT");
    }

    void save_bars (string symbol, int intraday, Series s) {
        if (s.unsaved >= s.n) return;
        // Everything from the first unsaved bar on is replaced: the series may have been cut back to
        // there and continued differently (Series.merge), or be a fresh download altogether.
        var cut = query ("DELETE FROM bars WHERE symbol = ? AND intraday = ? AND t >= ?");
        cut.bind_text (1, symbol);
        cut.bind_int (2, intraday);
        cut.bind_int64 (3, s.unsaved > 0 ? s.t[s.unsaved] : int64.MIN);
        cut.step ();
        var put = query ("INSERT OR REPLACE INTO bars (symbol, intraday, t, close) VALUES (?, ?, ?, ?)");
        for (int i = s.unsaved; i < s.n; i++) {
            put.bind_text (1, symbol);
            put.bind_int (2, intraday);
            put.bind_int64 (3, s.t[i]);
            put.bind_double (4, s.v[i]);
            put.step ();
            put.reset ();
        }
        s.unsaved = s.n;
    }

    // Full names of US securities (see Feed.load_names), or null if there are none or they are over a week old.
    public HashTable<string, string>? load_names (int64 now) {
        if (db == null) return null;
        var age = query ("SELECT value FROM facts WHERE key = 'names'");
        if (age.step () != Sqlite.ROW || now - age.column_int64 (0) > 7 * 86400) return null;
        var names = new HashTable<string, string> (str_hash, str_equal);
        var rows = query ("SELECT symbol, name FROM names");
        while (rows.step () == Sqlite.ROW) names[rows.column_text (0)] = rows.column_text (1);
        return names.size () > 0 ? names : null;
    }

    public void save_names (HashTable<string, string> names, int64 now) {
        if (db == null) return;
        db.exec ("BEGIN; DELETE FROM names");
        var put = query ("INSERT OR REPLACE INTO names (symbol, name) VALUES (?, ?)");
        names.foreach ((symbol, name) => {
            put.bind_text (1, symbol);
            put.bind_text (2, name);
            put.step ();
            put.reset ();
        });
        var fetched = query ("INSERT OR REPLACE INTO facts (key, value) VALUES ('names', ?)");
        fetched.bind_int64 (1, now);
        fetched.step ();
        db.exec ("COMMIT");
    }
}

}
