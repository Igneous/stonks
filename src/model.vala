// Portfolio math. No GTK and no network in here, so `make check` can exercise it.
namespace Stonks {

public enum Range { D1, D7, D30, YTD, Y1, Y5, MAX }
public const string[] RANGE_LABELS = { "1D", "7D", "30D", "YTD", "1Y", "5Y", "Max" };

// A price history: timestamps (unix seconds, ascending) and the value at each.
public class Series {
    int64[] _t = {};
    double[] _v = {};
    public unowned int64[] t { get { return _t; } }
    public unowned double[] v { get { return _v; } }
    public int n { get { return _t.length; } }
    public int unsaved;   // points from this index on are not in the on-disk cache yet (see Cache)

    public void add (int64 ts, double val) { _t += ts; _v += val; }

    // Replace the newest value: the live bar moves with every refresh.
    public void set_last (double val) {
        _v[n - 1] = val;
        unsaved = int.min (unsaved, n - 1);
    }

    // Take over from a fresher stretch: everything of ours from its first point on is replaced by it.
    public void merge (Series fresh) {
        if (fresh.n == 0) return;
        int keep = before (fresh.t[0]) + 1;
        _t.resize (keep);
        _v.resize (keep);
        for (int i = 0; i < fresh.n; i++) add (fresh.t[i], fresh.v[i]);
        unsaved = int.min (unsaved, keep);
    }

    // Whether a re-fetched stretch of daily history still says what ours does: every day the two share
    // within 0.01%. A split or a dividend adjustment rewrites the past, and then they don't. The last
    // bar of each is left out, being live: its is still moving, and ours stopped wherever the price
    // stood when we last asked, mid-session as likely as not. Also false if they share no day at all.
    public bool agrees (Series fresh, int gmtoffset) {
        int shared = 0;
        for (int i = 0; i < fresh.n - 1; i++) {
            int64 day = (fresh.t[i] + gmtoffset) / 86400;
            int j = before ((day + 1) * 86400 - gmtoffset);   // our last bar before that day ends
            if (j < 0 || j == n - 1 || (t[j] + gmtoffset) / 86400 != day) continue;
            if (Math.fabs (v[j] / fresh.v[i] - 1) > 1e-4) return false;
            shared++;
        }
        return shared > 0;
    }

    // Index of the last point strictly before ts, or -1.
    public int before (int64 ts) {
        int lo = 0, hi = n;
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            if (t[mid] < ts) lo = mid + 1; else hi = mid;
        }
        return lo - 1;
    }

    // Value at or before ts; the first value if ts predates the series.
    public double at (int64 ts) { return n == 0 ? double.NAN : v[int.max (before (ts + 1), 0)]; }
}

// What a feed says about an instrument beyond its price history: the figures on a quote page.
// NaN, or "", wherever it says nothing (an index has no P/E, a Hanoi stock has none of this).
public class Stats {
    public double open = double.NAN;
    public double high = double.NAN;             // today's
    public double low = double.NAN;
    public double prev_close = double.NAN;
    public double volume = double.NAN;
    public double avg_volume = double.NAN;       // three months' daily average
    public double cap = double.NAN;
    public double pe = double.NAN;               // trailing
    public double eps = double.NAN;
    public double high52 = double.NAN;
    public double low52 = double.NAN;
    public double dividend_yield = double.NAN;   // percent a year
    public double dividend_rate = double.NAN;    // per share a year
    public double extra_price = double.NAN;      // outside regular hours...
    public double extra_change = double.NAN;     // ...and its change from the close, in percent
    public string extra = "";                    // ...and which: "After hours" or "Pre-market"
    public string exchange = "";
    public string state = "";                    // REGULAR while the market is open
    public string zone = "";                     // the exchange's timezone, as it abbreviates it
    public int64 time;                           // of the last regular trade
}

// One instrument as its feed quotes it. `daily` always has at least one bar.
public class Quote {
    public string symbol = "";
    public string name = "";
    public string currency = "";
    public string kind = "";                 // EQUITY, ETF, INDEX, CURRENCY, CRYPTOCURRENCY, FUTURE, MUTUALFUND
    public int gmtoffset;                    // exchange timezone, seconds east of UTC
    public double price;
    public double prev_close = double.NAN;   // previous session's close when the feed states one; NaN = derive it from daily
    public Series daily = new Series ();     // full history, 1d bars; the last bar is the live session
    public Series intra = new Series ();     // last 7 days, 5m bars
    public Stats stats = new Stats ();       // empty until the feed has been asked (see Feed.load_stats)
    public int64 opens;                      // the regular session the feed last reported, unix time (0 = unknown)
    public int64 closes;
    public int64 refreshed;                  // when we last asked the feed about it
    public int64 checked;                    // when its daily history was last compared with the feed's

    // Whether it is worth asking the feed about this again: every time while its market is in session,
    // otherwise only once a quarter of an hour (which is also how a new session gets noticed).
    public bool due (int64 now) {
        bool trading = now >= opens - 60 && now <= closes + 600;
        // Currencies report a session round the clock, weekends included: go by their bars instead.
        if (closes - opens > 20 * 3600) trading = intra.n > 0 && now - intra.t[intra.n - 1] < 1800;
        return trading || now - refreshed >= 900;
    }

    // One company's shares, as opposed to an index, a fund, a currency pair or a commodity.
    public bool is_stock { get { return kind == "" || kind == "EQUITY"; } }

    // Where a range begins. 1D is the exchange's latest session, not the last 24 hours.
    public int64 start (Range r, int64 now) {
        switch (r) {
        case Range.D1:
            int64 local = daily.t[daily.n - 1] + gmtoffset;
            return local - local % 86400 - gmtoffset;
        case Range.D7: return now - 7 * 86400;
        case Range.D30: return now - 30 * 86400;
        case Range.YTD:
            int year = new DateTime.from_unix_utc (now + gmtoffset).get_year ();
            return new DateTime.utc (year, 1, 1, 0, 0, 0).to_unix () - gmtoffset;
        case Range.Y1: return now - 365 * 86400;
        case Range.Y5: return now - 1826 * 86400;
        default: return int64.MIN / 2;       // halved so start - 1 can't overflow
        }
    }

    // Price a range's change is measured from: the last close before the range starts.
    public double basis (Range r, int64 now) {
        if (r == Range.D1 && prev_close.is_finite ()) return prev_close;
        return daily.at (start (r, now) - 1);
    }

    public double change (Range r, int64 now) { return price / basis (r, now) - 1; }

    // Points to chart for a range: 5m bars up to a week, daily closes beyond (or when there are no 5m bars).
    public Series view (Range r, int64 now) {
        int64 from = start (r, now);
        var src = intra;
        if (r > Range.D7 || intra.n - intra.before (from) - 1 < 2) src = daily;
        var s = new Series ();
        for (int i = src.before (from) + 1; i < src.n; i++) s.add (src.t[i], src.v[i]);
        return s;
    }

    // The lowest and highest close since `from`, out of a series: what stands in for a day's range or
    // a 52-week range when the feed gives none. NaN if there is nothing that recent.
    public static void extremes (Series s, int64 from, out double lowest, out double highest) {
        lowest = highest = double.NAN;
        for (int i = s.before (from) + 1; i < s.n; i++) {
            lowest = lowest.is_finite () ? double.min (lowest, s.v[i]) : s.v[i];
            highest = highest.is_finite () ? double.max (highest, s.v[i]) : s.v[i];
        }
    }

    // Index of the daily bar for the day starting at `day`, or the nearest earlier one (weekends, holidays).
    public int bar (int64 day) { return int.max (daily.before (day + 86400), 0); }

    // Fold a fresh price into the daily series: a new bar once the exchange's day rolls over.
    public void tick (double p, int64 t) {
        price = p;
        int last = daily.n - 1;
        if ((t + gmtoffset) / 86400 > (daily.t[last] + gmtoffset) / 86400) daily.add (t, p);
        else daily.set_last (p);
    }

    // FX rate at a moment: 5m bars where they reach, else that day's close.
    double rate (int64 t) {
        int i = intra.before (t + 1);
        return i >= 0 ? intra.v[i] : daily.at (t);
    }

    // This quote repriced through an FX quote: multiplied by its rate, or divided by it if `invert`.
    // ponytail: a daily bar takes the FX close of the same UTC date, so exchanges that open before
    // 00:00 UTC (Sydney, Wellington) convert with the previous day's rate. Fine for US/Asia.
    public Quote times (Quote fx, bool invert) {
        var c = new Quote () { symbol = symbol, name = name, currency = currency, kind = kind, gmtoffset = gmtoffset };
        c.price = scale (price, fx.price, invert);
        for (int i = 0; i < daily.n; i++) c.daily.add (daily.t[i], scale (daily.v[i], fx.daily.at (daily.t[i]), invert));
        for (int i = 0; i < intra.n; i++) c.intra.add (intra.t[i], scale (intra.v[i], fx.rate (intra.t[i]), invert));
        c.daily.set_last (c.price);   // the live bar is worth what it converts to right now
        // Yesterday's close converts at yesterday's rate: reuse the one applied to that daily bar.
        int b = daily.before (start (Range.D1, 0));
        if (b >= 0) c.prev_close = prev_close * c.daily.v[b] / daily.v[b];
        return c;
    }

    static double scale (double v, double rate, bool invert) { return invert ? v / rate : v * rate; }
}

// A tracked stock: a theoretical purchase, or with no shares just one to watch.
// GObject properties so json-glib can (de)serialize it and a ColumnView can list it.
public class Lot : Object {
    public string symbol { get; set; default = ""; }
    public double shares { get; set; }                // 0 = watched only: date and price mean nothing
    public double price { get; set; }                // paid per share, in the instrument's own currency
    public string date { get; set; default = ""; }   // YYYY-MM-DD
    public string group { get; set; default = ""; }  // the heatmap folder its symbol is filed in, if any

    // Midnight of the buy date at an exchange `gmtoffset` seconds east of UTC.
    public int64 ts (int gmtoffset) {
        var d = new DateTime.from_iso8601 (date + "T00:00:00Z", null);
        return d == null ? 0 : d.to_unix () - gmtoffset;
    }
}

// How a folder lays out what is in it. Saved by number: add new ones at the end.
public enum Arrange {
    VALUE,       // a treemap: each tile as big as the holding is worth
    ROW,         // a horizontal strip: side by side, every stock the same size
    COLUMN,      // a vertical strip
    GRID,        // equal cells, in as many rows and columns as keeps them nearest to square
    FIBONACCI    // the first takes half, the next half of what is left, and so on round a spiral
}

// Where a folder sits in the one it is in: in line with the rest, or pinned along an edge. Saved by number.
public enum Dock { FLOW, TOP, BOTTOM, LEFT, RIGHT }

// A heatmap folder. They nest; the root, which has no name, is the heatmap itself.
public class Group {
    public string id = "";      // what a lot names it by; "" is the root
    public string name = "";
    public weak Group? parent;
    public GenericArray<Group> children = new GenericArray<Group> ();
    public Arrange arrange;
    public Dock dock;
    public double size;         // pinned: the share of its parent's height (or width) it takes; 0 leaves that to tiles()
    public bool scroll;         // a strip: keep its tiles a readable size and scroll, rather than squeeze them all in
    public double offset;       // how far it is scrolled and, set by tiles(), how far it can be. Neither is saved.
    public double overflow;

    // Whether this is `other` or somewhere inside it.
    public bool within (Group other) {
        for (unowned Group? g = this; g != null; g = g.parent) if (g == other) return true;
        return false;
    }
}

public enum TileKind {
    STOCK,       // labelled by its ticker
    BENCHMARK,   // an index, fund, pair or commodity that is only watched: labelled by its name and level
    GROUP        // a folder: the frame its contents are laid out in
}

public struct Box {
    public double x;
    public double y;
    public double w;
    public double h;
}

// A treemap cell: one tracked symbol, or a folder of them.
public class Tile {
    public TileKind kind;
    public string symbol;   // a GROUP's is the folder's name
    public string name;
    public Group folder;    // the folder it is in; a GROUP's is the folder itself
    public string currency = "";
    public double price;    // the instrument's own
    public double shares;
    public double value;    // held, in the portfolio currency; 0 if only watched
    public double weight;   // what sizes the tile by value: its value, or a stand-in for watched symbols
    public double change;   // the instrument's own price change over the range; a GROUP's is its stocks' average
    public int count;       // a GROUP's stocks, however deep
    public double x;
    public double y;
    public double w;
    public double h;
    public Box clip;        // the part of the heatmap it may show in: less than all of it inside a strip that scrolls

    // A GROUP's room for what is in it: inside its frame, below its label.
    public Box inside () {
        double head = double.min (Portfolio.GROUP_HEADER, h / 3), edge = double.min (Portfolio.GROUP_BORDER, w / 8);
        Box room = { x + edge, y + head, w - 2 * edge, h - head - edge };
        return room;
    }

    // Whether a point is on the part of it that shows.
    public bool covers (double px, double py) {
        return px >= double.max (x, clip.x) && px < double.min (x + w, clip.x + clip.w)
            && py >= double.max (y, clip.y) && py < double.min (y + h, clip.y + clip.h);
    }
}

public class Portfolio {
    public GLib.ListStore lots = new GLib.ListStore (typeof (Lot));
    // Quotes as the feed gives them, in their own currencies; includes the FX pairs (JPYUSD=X).
    public HashTable<string, Quote> quotes = new HashTable<string, Quote> (str_hash, str_equal);
    // The held ones repriced into `currency`. Derived: call rebase() after quotes or currency change.
    public HashTable<string, Quote> converted = new HashTable<string, Quote> (str_hash, str_equal);
    public string currency = "USD";
    // The heatmap's folders: a tree, in the user's order. A lot names its folder by id; the root's is "".
    public Group root = new Group ();

    public const double GROUP_HEADER = 22;    // pixels kept free at the top of a folder's region for its label
    public const double GROUP_BORDER = 3;     // ...and around its other three sides, so it reads as a frame
    public const double STRIP_HEIGHT = 64;    // the tiles of a strip pinned along the top or bottom are this high,
    public const double STRIP_WIDTH = 150;    // and down a side this wide, unless the user sized it
    public const double SCROLL_WIDTH = 110;   // the least a strip that scrolls lets its tiles shrink to
    public const double SCROLL_HEIGHT = 48;

    // Whether a symbol is on the list itself, as opposed to an FX pair we only convert totals through.
    public bool tracks (string symbol) {
        for (uint i = 0; i < lots.get_n_items (); i++) if (((Lot) lots.get_item (i)).symbol == symbol) return true;
        return false;
    }

    // Every folder but the root, each before the ones inside it, in the user's order.
    public GenericArray<Group> folders () {
        var all = new GenericArray<Group> ();
        collect (root, all);
        return all;
    }

    static void collect (Group g, GenericArray<Group> into) {
        for (int i = 0; i < g.children.length; i++) {
            into.add (g.children[i]);
            collect (g.children[i], into);
        }
    }

    // The folder with an id; the root for "" or for one that no longer exists.
    public Group folder (string id) {
        var all = folders ();
        for (int i = 0; i < all.length; i++) if (all[i].id == id) return all[i];
        return root;
    }

    public Group add_group (string name, Group parent) {
        var g = new Group () { id = Uuid.string_random (), name = name, parent = parent };
        parent.children.add (g);
        return g;
    }

    // Put a folder in another (or the root): next to `beside`, one of those already there, or at the end.
    // Not into itself. It comes back in line; pinning it somewhere is dock_group()'s to do after.
    public void move_group (Group g, Group into, Group? beside = null, bool after = false) {
        if (g == root || into.within (g) || beside == g) return;
        g.parent.children.remove (g);
        uint at = 0;   // set apart from the test below: valac's flow analysis can't see through an `out` in a condition
        bool found = beside != null && into.children.find (beside, out at);
        if (!found) at = into.children.length;
        else if (after) at++;
        into.children.insert ((int) at, g);
        g.parent = into;
        g.dock = Dock.FLOW;
        g.size = 0;
    }

    // Pin a folder along an edge of the one it is in, or (FLOW) put it back in line. A strip turns to
    // run along the edge it is pinned to.
    public void dock_group (Group g, Dock dock) {
        bool side = dock == Dock.LEFT || dock == Dock.RIGHT;
        if (g.arrange == Arrange.ROW && side) g.arrange = Arrange.COLUMN;
        else if (g.arrange == Arrange.COLUMN && dock != Dock.FLOW && !side) g.arrange = Arrange.ROW;
        g.dock = dock;
        g.size = 0;
    }

    // Delete a folder. What was in it, folders and stocks, moves up into the one it was in.
    public void remove_group (Group g) {
        var up = g.parent;
        uint at = 0;
        if (up == null || !up.children.find (g, out at)) return;
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            if (l.group == g.id) l.group = up.id;
        }
        for (int i = 0; i < g.children.length; i++) {
            g.children[i].parent = up;
            up.children.insert ((int) at + 1 + i, g.children[i]);
        }
        up.children.remove_index (at);
    }

    // File a symbol (every lot of it) in a folder, by id; "" takes it out.
    public void assign (string symbol, string group) {
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            if (l.symbol == symbol) l.group = group;
        }
    }

    // Move a symbol (every lot of it) to just before another, or just after. The order of the list is
    // the order things appear in everywhere: the table, the sidebar, and within a folder on the heatmap.
    public void move (string symbol, string target, bool after) {
        if (symbol == target) return;
        Lot[] moved = {};
        for (int i = (int) lots.get_n_items () - 1; i >= 0; i--) {
            var l = (Lot) lots.get_item (i);
            if (l.symbol != symbol) continue;
            moved += l;
            lots.remove (i);
        }
        uint at = lots.get_n_items ();   // no such target: the end
        for (uint i = 0; i < lots.get_n_items (); i++) {
            if (((Lot) lots.get_item (i)).symbol != target) continue;
            at = after ? i + 1 : i;
            if (!after) break;           // before its first lot; after its last
        }
        for (int i = moved.length - 1; i >= 0; i--) lots.insert (at++, moved[i]);   // collected backwards
    }

    static string? usd_pair (string cur) { return cur == "USD" ? null : cur + "USD=X"; }

    // Symbols to keep fresh: everything tracked, plus the FX pairs that bring holdings into our currency.
    public string[] wanted () {
        string[] symbols = {};
        var seen = new GenericSet<string> (str_hash, str_equal);
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            var q = quotes[l.symbol];
            string?[] need = { l.symbol, null, null };
            if (l.shares > 0 && q != null && q.currency != "" && q.currency != currency) {
                need[1] = usd_pair (q.currency);
                need[2] = usd_pair (currency);
            }
            foreach (var s in need) if (s != null && seen.add (s)) symbols += s;
        }
        return symbols;
    }

    // ponytail: converts through USD because Yahoo has no direct pair for most crosses (no KRWVND=X).
    // Pence-quoted currencies (GBp, ZAc, ILA) would come out 100x high; scale them here if you hold one.
    public void rebase () {
        converted.remove_all ();
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            Quote? c = quotes[l.symbol];
            if (c == null || l.shares <= 0 || converted.contains (l.symbol)) continue;
            if (c.currency != "" && c.currency != currency) {
                var into_usd = usd_pair (c.currency), from_usd = usd_pair (currency);
                if (into_usd != null) c = quotes[into_usd] != null ? c.times (quotes[into_usd], false) : null;
                if (from_usd != null && c != null) c = quotes[from_usd] != null ? c.times (quotes[from_usd], true) : null;
            }
            if (c != null) converted[l.symbol] = c;   // else: waiting on an FX pair, left out of totals
        }
    }

    // What a lot cost per share in our currency, at the FX rate of its buy date.
    double cost (Lot l) {
        var q = quotes[l.symbol];
        int i = q.bar (l.ts (q.gmtoffset));
        return l.price * converted[l.symbol].daily.v[i] / q.daily.v[i];
    }

    // A lot's gain over a range and the capital that earned it, in our currency: measured from its cost
    // if it was bought within the range, otherwise from the price when the range began.
    // False (and zeros) for a watched stock, or while its quote or FX rate hasn't loaded.
    public bool lot_gain (Lot l, Range r, int64 now, out double earned, out double capital) {
        earned = 0;
        capital = 0;
        var c = converted[l.symbol];
        if (c == null || l.shares <= 0) return false;
        double from = l.ts (c.gmtoffset) >= c.start (r, now) ? cost (l) : c.basis (r, now);
        capital = l.shares * from;
        earned = l.shares * c.price - capital;
        return true;
    }

    // The same summed over the portfolio, so gain / capital is its return for the range.
    // Range.MAX gives total gain and cost basis; capital + gain is always the current value.
    public void gain (Range r, int64 now, out double earned, out double capital) {
        earned = 0;
        capital = 0;
        for (uint i = 0; i < lots.get_n_items (); i++) {
            double g, k;
            lot_gain ((Lot) lots.get_item (i), r, now, out g, out k);
            earned += g;
            capital += k;
        }
    }

    // Portfolio value over a range, from the first moment it held anything, and (`opening`) what the
    // lots already held when the range began were worth then.
    public Series history (Range r, int64 now, out double opening) {
        Series[] views = {};
        double[] shares = {};
        double[] basis = {};
        int64[] bought = {};
        opening = 0;
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            var c = converted[l.symbol];
            if (c == null || l.shares <= 0) continue;
            views += c.view (r, now);
            shares += l.shares;
            basis += c.basis (r, now);
            bought += l.ts (c.gmtoffset);
            if (l.ts (c.gmtoffset) < c.start (r, now)) opening += l.shares * c.basis (r, now);
        }
        // Merge on every timestamp any lot has, carrying each lot's last known price forward.
        var s = new Series ();
        var pos = new int[views.length];
        while (true) {
            int64 t = int64.MAX;
            for (int i = 0; i < views.length; i++)
                if (pos[i] < views[i].n && views[i].t[pos[i]] < t) t = views[i].t[pos[i]];
            if (t == int64.MAX) break;
            double total = 0;
            for (int i = 0; i < views.length; i++) {
                while (pos[i] < views[i].n && views[i].t[pos[i]] <= t) pos[i]++;
                if (bought[i] <= t) total += shares[i] * (pos[i] > 0 ? views[i].v[pos[i] - 1] : basis[i]);
            }
            if (total > 0 || s.n > 0) s.add (t, total);
        }
        return s;
    }

    // The heatmap, laid out to fill w x h: one tile per tracked symbol, and one (a GROUP, listed just
    // before what is in it) per folder that holds any. Each folder lays out its own contents: folders
    // pinned to an edge first, then the folders in line, then its own stocks in the order of the list.
    // Only Arrange.VALUE sizes by value; there a watched stock, which has none, gets the average
    // holding's size (equal sizes if nothing is held).
    public GenericArray<Tile> tiles (Range r, int64 now, double w, double h) {
        var homes = new HashTable<string, Group> (str_hash, str_equal);
        var all = folders ();
        for (int i = 0; i < all.length; i++) homes[all[i].id] = all[i];
        var by_symbol = new HashTable<string, Tile> (str_hash, str_equal);
        leaves = new GenericArray<Tile> ();
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            var q = quotes[l.symbol];
            if (q == null) continue;
            var t = by_symbol[l.symbol];
            if (t == null) {
                t = new Tile () { symbol = l.symbol, name = q.name, currency = q.currency, price = q.price, change = q.change (r, now) };
                t.kind = q.is_stock ? TileKind.STOCK : TileKind.BENCHMARK;
                t.folder = homes[l.group] ?? root;   // a folder that no longer exists is no folder
                by_symbol[l.symbol] = t;
                leaves.add (t);
            }
            t.shares += l.shares;
            if (l.shares > 0) t.kind = TileKind.STOCK;   // held: a position like any other
            var c = converted[l.symbol];
            if (c != null) t.value += l.shares * c.price;
        }
        double total = 0;
        int held = 0;
        for (int i = 0; i < leaves.length; i++) if (leaves[i].value > 0) { total += leaves[i].value; held++; }
        for (int i = 0; i < leaves.length; i++) leaves[i].weight = leaves[i].value > 0 ? leaves[i].value : (held > 0 ? total / held : 1);

        laid = new GenericArray<Tile> ();
        blocks = new HashTable<Group, Tile> (direct_hash, direct_equal);
        if (summarize (root) != null) fill (root, { 0, 0, w, h }, { 0, 0, w, h });
        return laid;
    }

    // What tiles() is working on, for the steps below.
    GenericArray<Tile> leaves;
    GenericArray<Tile> laid;
    HashTable<Group, Tile> blocks;

    // A folder's tile: the totals of everything in it, however deep. None for a folder with nothing
    // in it, which gets no room on the heatmap.
    Tile? summarize (Group g) {
        var b = new Tile () { kind = TileKind.GROUP, symbol = g.name, name = "", folder = g };
        for (int i = 0; i < leaves.length; i++) if (leaves[i].folder == g) add (b, leaves[i], 1);
        for (int i = 0; i < g.children.length; i++) {
            var inner = summarize (g.children[i]);
            if (inner != null) add (b, inner, inner.count);
        }
        if (b.count == 0) return null;
        b.change /= b.weight;
        blocks[g] = b;
        return b;
    }

    static void add (Tile sum, Tile t, int count) {
        sum.value += t.value;
        sum.weight += t.weight;
        sum.change += t.weight * t.change;
        sum.count += count;
    }

    // Lay out what is in a folder over `area`, of which `clip` is the part that shows.
    void fill (Group g, Box area, Box clip) {
        double x = area.x, y = area.y, w = area.w, h = area.h;
        var items = new GenericArray<Tile> ();
        var pinned = new GenericArray<Tile> ();
        for (int i = 0; i < g.children.length; i++) {
            var b = blocks[g.children[i]];
            if (b == null) continue;
            if (g.children[i].dock == Dock.FLOW) items.add (b); else pinned.add (b);
        }
        for (int i = 0; i < leaves.length; i++) if (leaves[i].folder == g) items.add (leaves[i]);

        // The pinned folders, in order: each takes a slice off its edge of what is left. As thick as the
        // user dragged it to; otherwise a strip along its edge is one tile thick, anything else gets
        // room in proportion to what it holds, up to a third.
        for (int i = 0; i < pinned.length; i++) {
            var b = pinned[i];
            var c = b.folder;
            bool across = c.dock == Dock.TOP || c.dock == Dock.BOTTOM;
            double room = across ? h : w, thick;
            if (c.size > 0) thick = double.min (c.size * (across ? area.h : area.w), room * 0.8);
            else if (c.arrange == (across ? Arrange.ROW : Arrange.COLUMN)) thick = double.min (across ? STRIP_HEIGHT + GROUP_HEADER + GROUP_BORDER : STRIP_WIDTH + 2 * GROUP_BORDER, room / 3);
            else thick = double.min (room * b.weight / blocks[g].weight, room / 3);
            if (items.length == 0 && i == pinned.length - 1) thick = room;   // nothing else to leave room for
            b.x = c.dock == Dock.RIGHT ? x + w - thick : x;
            b.y = c.dock == Dock.BOTTOM ? y + h - thick : y;
            b.w = across ? w : thick;
            b.h = across ? thick : h;
            if (c.dock == Dock.TOP) y += thick;
            if (c.dock == Dock.LEFT) x += thick;
            if (across) h -= thick; else w -= thick;
            enter (b, clip);
        }

        g.overflow = 0;
        switch (g.arrange) {
        case Arrange.ROW:
        case Arrange.COLUMN: strip (g, items, x, y, w, h); break;
        case Arrange.GRID: grid (items, x, y, w, h); break;
        case Arrange.FIBONACCI: spiral (items, x, y, w, h); break;
        default: layout (items, 0, items.length, x, y, w, h); break;
        }
        // Nothing shows outside the folder's own room: that is what a scrolled strip is cut off by.
        double left = double.max (clip.x, x), top = double.max (clip.y, y);
        Box inside = { left, top, double.max (double.min (clip.x + clip.w, x + w) - left, 0), double.max (double.min (clip.y + clip.h, y + h) - top, 0) };
        for (int i = 0; i < items.length; i++) {
            if (items[i].kind == TileKind.GROUP) {
                enter (items[i], inside);
            } else {
                items[i].clip = inside;
                laid.add (items[i]);
            }
        }
    }

    // A folder's tile has its place: list it, then lay out what is in it, inside its frame.
    void enter (Tile b, Box clip) {
        b.clip = clip;
        laid.add (b);
        fill (b.folder, b.inside (), clip);
    }

    // A strip: side by side (or one above the other), every stock the same size. A folder among them
    // is as long as the stocks in it, or as one stock if it is itself a strip running the other way.
    // A strip that scrolls stops shrinking its tiles at a readable size and runs on past its end.
    static void strip (Group g, GenericArray<Tile> items, double x, double y, double w, double h) {
        bool row = g.arrange == Arrange.ROW;
        double units = 0;
        double[] span = {};
        for (int i = 0; i < items.length; i++) {
            bool lengthwise = items[i].kind == TileKind.GROUP && items[i].folder.arrange != (row ? Arrange.COLUMN : Arrange.ROW);
            span += lengthwise ? items[i].count : 1;
            units += span[i];
        }
        double room = row ? w : h, unit = room / units, least = row ? SCROLL_WIDTH : SCROLL_HEIGHT;
        if (g.scroll && unit < least) {
            unit = least;
            g.overflow = unit * units - room;
        }
        g.offset = g.offset.clamp (0, g.overflow);
        double at = (row ? x : y) - g.offset;
        for (int i = 0; i < items.length; i++) {
            var t = items[i];
            t.x = row ? at : x;
            t.y = row ? y : at;
            t.w = row ? unit * span[i] : w;
            t.h = row ? h : unit * span[i];
            at += unit * span[i];
        }
    }

    // A grid of equal cells: as many across as brings them nearest to a little wider than tall, which
    // is what a label wants. A last row that comes up short is stretched to fill it.
    static void grid (GenericArray<Tile> items, double x, double y, double w, double h) {
        int n = items.length, across = 1;
        double best = double.MAX;
        for (int c = 1; c <= n; c++) {
            double off = Math.fabs (Math.log ((w / c) / (h / ((n + c - 1) / c)) / 1.3));
            if (off < best) { best = off; across = c; }
        }
        int rows = (n + across - 1) / across;
        for (int i = 0; i < n; i++) {
            int row = i / across, here = row == rows - 1 ? n - row * across : across;
            items[i].x = x + w * (i % across) / here;
            items[i].y = y + h * row / rows;
            items[i].w = w / here;
            items[i].h = h / rows;
        }
    }

    // Fibonacci: the first takes half, the next half of what is left, and so on round a spiral (left,
    // top, right, bottom); the last takes what remains.
    static void spiral (GenericArray<Tile> items, double x, double y, double w, double h) {
        int turn = w >= h ? 0 : 1;
        for (int i = 0; i < items.length; i++, turn++) {
            var t = items[i];
            t.x = x; t.y = y; t.w = w; t.h = h;
            if (i == items.length - 1) break;
            if (turn % 2 == 0) {
                t.w = w = w / 2;
                if (turn % 4 == 0) x += w; else t.x = x + w;
            } else {
                t.h = h = h / 2;
                if (turn % 4 == 1) y += h; else t.y = y + h;
            }
        }
    }

    // ponytail: binary split (halve the list by weight where it stands, cut the longer side). It keeps
    // the list's order, which a squarified treemap would not; expect slivers if a tiny holding sits
    // between two huge ones, and drag it elsewhere.
    static void layout (GenericArray<Tile> t, int lo, int hi, double x, double y, double w, double h) {
        if (hi - lo < 1) return;
        if (hi - lo == 1) {
            t[lo].x = x; t[lo].y = y; t[lo].w = w; t[lo].h = h;
            return;
        }
        double total = 0;
        for (int i = lo; i < hi; i++) total += t[i].weight;
        // Take items while that brings the first half closer to half the weight.
        int mid = lo + 1;
        double acc = t[lo].weight;
        while (mid < hi - 1 && Math.fabs (acc + t[mid].weight - total / 2) < Math.fabs (acc - total / 2)) acc += t[mid++].weight;
        double f = acc / total;
        if (w >= h) {
            layout (t, lo, mid, x, y, w * f, h);
            layout (t, mid, hi, x + w * f, y, w * (1 - f), h);
        } else {
            layout (t, lo, mid, x, y, w, h * f);
            layout (t, mid, hi, x, y + h * f, w, h * (1 - f));
        }
    }
}

}
