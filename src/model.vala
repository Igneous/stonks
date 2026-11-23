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
    // (its last aside, that being the live bar) within 0.01%. A split or a dividend adjustment rewrites
    // the past, and then they don't. Also false if they share no day at all.
    public bool agrees (Series fresh, int gmtoffset) {
        int shared = 0;
        for (int i = 0; i < fresh.n - 1; i++) {
            int64 day = (fresh.t[i] + gmtoffset) / 86400;
            int j = before ((day + 1) * 86400 - gmtoffset);   // our last bar before that day ends
            if (j < 0 || (t[j] + gmtoffset) / 86400 != day) continue;
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

public enum TileKind {
    STOCK,       // in the body of the treemap
    BENCHMARK,   // an index, fund, currency pair or commodity that is only watched: the row along the top
    GROUP        // a folder: the region its stocks are laid out in
}

// A treemap cell: one tracked symbol, or a folder of them.
public class Tile {
    public TileKind kind;
    public string symbol;   // a GROUP's is the folder name
    public string name;
    public string group = "";
    public string currency = "";
    public double price;    // the instrument's own
    public double shares;
    public double value;    // held, in the portfolio currency; 0 if only watched
    public double weight;   // what sizes the tile: value, or a stand-in for watched symbols
    public double change;   // the instrument's own price change over the range; a GROUP's is its stocks' average
    public double x;
    public double y;
    public double w;
    public double h;
}

public class Portfolio {
    public GLib.ListStore lots = new GLib.ListStore (typeof (Lot));
    // Quotes as the feed gives them, in their own currencies; includes the FX pairs (JPYUSD=X).
    public HashTable<string, Quote> quotes = new HashTable<string, Quote> (str_hash, str_equal);
    // The held ones repriced into `currency`. Derived: call rebase() after quotes or currency change.
    public HashTable<string, Quote> converted = new HashTable<string, Quote> (str_hash, str_equal);
    public string currency = "USD";
    // Heatmap folders, in the user's order. Kept here as well as on the lots so an empty one survives.
    public GenericArray<string> groups = new GenericArray<string> ();

    public const double GROUP_HEADER = 22;    // pixels kept free at the top of a folder's region for its label
    public const double GROUP_BORDER = 3;     // ...and around its other three sides, so it reads as a frame
    public const double BENCHMARK_ROW = 64;   // height of the row along the top

    // Whether a symbol is on the list itself, as opposed to an FX pair we only convert totals through.
    public bool tracks (string symbol) {
        for (uint i = 0; i < lots.get_n_items (); i++) if (((Lot) lots.get_item (i)).symbol == symbol) return true;
        return false;
    }

    // File a symbol (every lot of it) in a folder; "" takes it out.
    public void assign (string symbol, string group) {
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            if (l.symbol == symbol) l.group = group;
        }
    }

    // Rename a folder, or with "" as the new name delete it and unfile its stocks.
    public void rename_group (string old, string name) {
        uint at;
        if (!groups.find_with_equal_func (old, str_equal, out at)) return;
        if (name == "") groups.remove_index (at); else groups[at] = name;
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            if (l.group == old) l.group = name;
        }
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

    static int by_weight (Tile a, Tile b) {
        return a.weight < b.weight ? 1 : (a.weight > b.weight ? -1 : strcmp (a.symbol, b.symbol));
    }

    // The heatmap, laid out to fill w x h: one tile per tracked symbol.
    //  - Indices, funds, currency pairs and commodities that are only watched are context rather than
    //    positions: they sit side by side in a row along the top.
    //  - Everything else fills the rest, sized by value. A watched stock has no value, so it gets the
    //    average holding's size (equal sizes if nothing is held).
    //  - If any stock is filed in a folder, each folder becomes a region (a GROUP tile, listed just
    //    before its stocks) with unfiled stocks sharing one called "Ungrouped".
    public GenericArray<Tile> tiles (Range r, int64 now, double w, double h) {
        var by_symbol = new HashTable<string, Tile> (str_hash, str_equal);
        var all = new GenericArray<Tile> ();
        for (uint i = 0; i < lots.get_n_items (); i++) {
            var l = (Lot) lots.get_item (i);
            var q = quotes[l.symbol];
            if (q == null) continue;
            var t = by_symbol[l.symbol];
            if (t == null) {
                t = new Tile () { symbol = l.symbol, name = q.name, group = l.group, currency = q.currency, price = q.price, change = q.change (r, now) };
                by_symbol[l.symbol] = t;
                all.add (t);
            }
            t.shares += l.shares;
            var c = converted[l.symbol];
            if (c != null) t.value += l.shares * c.price;
        }

        var result = new GenericArray<Tile> ();
        var body = new GenericArray<Tile> ();
        for (int i = 0; i < all.length; i++) {
            all[i].kind = !quotes[all[i].symbol].is_stock && all[i].shares <= 0 ? TileKind.BENCHMARK : TileKind.STOCK;
            if (all[i].kind == TileKind.BENCHMARK) result.add (all[i]); else body.add (all[i]);
        }
        double top = result.length > 0 ? double.min (BENCHMARK_ROW, h / 4) : 0;
        for (int i = 0; i < result.length; i++) {
            result[i].x = w * i / result.length;
            result[i].w = w / result.length;
            result[i].h = top;
        }

        double total = 0;
        int held = 0;
        bool grouped = false;
        for (int i = 0; i < body.length; i++) {
            grouped |= body[i].group != "";
            if (body[i].value > 0) { total += body[i].value; held++; }
        }
        for (int i = 0; i < body.length; i++) body[i].weight = body[i].value > 0 ? body[i].value : (held > 0 ? total / held : 1);
        if (!grouped) {
            body.sort (by_weight);
            layout (body, 0, body.length, 0, top, w, h - top);
            for (int i = 0; i < body.length; i++) result.add (body[i]);
            return result;
        }

        var regions = new GenericArray<Tile> ();
        var by_group = new HashTable<string, Tile> (str_hash, str_equal);
        for (int i = 0; i < body.length; i++) {
            var t = body[i];
            var g = by_group[t.group];
            if (g == null) {
                g = new Tile () { kind = TileKind.GROUP, symbol = t.group != "" ? t.group : "Ungrouped", name = "", group = t.group };
                by_group[t.group] = g;
                regions.add (g);
            }
            g.value += t.value;
            g.weight += t.weight;
            g.change += t.weight * t.change;
        }
        regions.sort (by_weight);
        layout (regions, 0, regions.length, 0, top, w, h - top);
        for (int i = 0; i < regions.length; i++) {
            var g = regions[i];
            g.change /= g.weight;
            result.add (g);
            var members = new GenericArray<Tile> ();
            for (int k = 0; k < body.length; k++) if (body[k].group == g.group) members.add (body[k]);
            members.sort (by_weight);
            double head = double.min (GROUP_HEADER, g.h / 3), edge = double.min (GROUP_BORDER, g.w / 8);
            layout (members, 0, members.length, g.x + edge, g.y + head, g.w - 2 * edge, g.h - head - edge);
            for (int k = 0; k < members.length; k++) result.add (members[k]);
        }
        return result;
    }

    // ponytail: binary split (halve the list by weight, cut the longer side). Tiles stay reasonably
    // square; switch to a squarified treemap if a long tail of tiny holdings turns into slivers.
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
