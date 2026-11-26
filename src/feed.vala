// Where prices come from. Keyless and unofficial sources, so any of them can change or throttle:
//
//   Yahoo Finance   everything but Vietnam. These are the chart and search endpoints finance.yahoo.com
//                   itself calls; Yahoo retired its official API in 2017 and there is no key to get.
//   SSI iBoard      every .VN symbol, indices included (^VNINDEX.VN, ^VN30.VN, ^HNXINDEX.VN: Yahoo has
//                   one day of history for them). Yahoo lists Ho Chi Minh (HOSE) only; this broker's web
//                   terminal also has Hanoi (HNX) and UPCoM, with history back to 2006.
//                   Drop-in alternatives that returned identical bars when this was written:
//                   services.entrade.com.vn/chart-api/v2/ohlcs/stock and dchart-api.vndirect.com.vn/dchart/history.
//   CNBC            only the past of an index Yahoo has no history for (see with_past).
//   Entrade         only Vietnam's hourly bars (see hours): SSI keeps a month of them, this broker's
//                   chart service a year and more.
//
// Yahoo is also where a stock's earnings history comes from (see past) and its trading outside
// regular hours (see extend), and it has the one feed that isn't asked but listened to: the socket
// its own pages keep open for live prices (see follow).
//
// Search also reads Nasdaq Trader's public symbol directory, for the full names of US securities, and
// logos come from wherever logo() says.
//
// Being a polite guest of them all: everything fetched goes into the on-disk Cache, so a symbol's
// whole history is downloaded once and after that only the bars since the last ones we have; a quote
// is refreshed only when Quote.due() says its market could have moved, twenty symbols to a request
// where the feed allows (see refresh); and the name directory is fetched once a week. What only a
// pinned point of a chart needs (see past) is asked for when one is first pinned, not before.
namespace Stonks {

// A search result.
public class Hit {
    public string symbol;
    public string name = "";     // as full as we can get it: "Alphabet Inc. - Class C Capital Stock"
    public string detail = "";   // exchange, type, sector, industry
    public string currency = "";
    public double price = double.NAN;   // NaN where the source has none
    public double cap = double.NAN;     // market capitalisation, in `currency`
    public double rate = double.NAN;    // times this is the totals currency; NaN if it already is, or unknown
}

public class Feed : Object {
    // Markets a search can be kept to (the add dialog's dropdown): a label, then how the market's
    // symbols are told apart. That is a Yahoo suffix (".T"); "US" for unsuffixed stocks and funds; or
    // "=" and an instrument type as Yahoo's lookup names it. The first is no constraint at all.
    public const string[] MARKETS = {
        "Auto", "",
        "United States", "US",
        "Tokyo", ".T",
        "Korea (KOSPI)", ".KS",
        "Korea (KOSDAQ)", ".KQ",
        "Shanghai", ".SS",
        "Shenzhen", ".SZ",
        "Hong Kong", ".HK",
        "Vietnam", ".VN",
        "Taiwan", ".TW",
        "Singapore", ".SI",
        "India (NSE)", ".NS",
        "India (BSE)", ".BO",
        "Indonesia", ".JK",
        "Thailand", ".BK",
        "Malaysia", ".KL",
        "Australia", ".AX",
        "London", ".L",
        "Xetra", ".DE",
        "Frankfurt", ".F",
        "Paris", ".PA",
        "Amsterdam", ".AS",
        "Milan", ".MI",
        "Madrid", ".MC",
        "Switzerland", ".SW",
        "Stockholm", ".ST",
        "Toronto", ".TO",
        "Sao Paulo", ".SA",
        "ETFs", "=etf",
        "Mutual funds", "=mutualfund",
        "Indices", "=index",
        "Crypto", "=cryptocurrency",
        "Currencies", "=currency",
        "Futures", "=future"
    };

    const string YAHOO = "https://query1.finance.yahoo.com";
    const string SSI_BARS = "https://iboard-api.ssi.com.vn/statistics/charts/history";
    const string SSI_INFO = "https://iboard-query.ssi.com.vn/stock";
    const string CNBC_BARS = "https://ts-api.cnbc.com/harmony/app/bars";
    const string ENTRADE_BARS = "https://services.entrade.com.vn/chart-api/v2/ohlcs";
    const string STREAM = "wss://streamer.finance.yahoo.com/?version=2";
    const int BATCH = 20;   // the most symbols Yahoo's spark endpoint takes in one request
    const string[] REACHES = { "1d", "7d", "1mo", "3mo", "1y" };   // how far back a spark request can ask
    const string VERSION = "1.2";   // `make check` holds the metainfo's newest release to this
    Soup.Session session = new Soup.Session () { timeout = 30 };   // no user_agent here: it would override agent()'s
    HashTable<string, string>? names;   // US symbol -> full security name, once load_names() has run
    string? crumb;                      // see quote_batch()
    HashTable<string, double?> per_usd = new HashTable<string, double?> (str_hash, str_equal);   // see rate_hits()
    HashTable<string, Found> found = new HashTable<string, Found> (str_hash, str_equal);          // see search()
    Cache cache;
    GenericArray<Listed>? vietnam;   // see load_vietnam()
    HashTable<string, Past> pasts = new HashTable<string, Past> (str_hash, str_equal);           // see past()
    // The live price stream, see follow().
    Soup.WebsocketConnection? socket;
    Quote? followed;
    bool connecting;
    uint tuned;                           // counts connections, so that the handlers of an old one stand down
    int64 heard_at;                       // when its last price came, on the monotonic clock
    public bool live;                     // connected, and subscribed to the quote followed
    public double pace = double.NAN;      // seconds between the prices it has been sending, smoothed
    public signal void heard ();          // a price came in, or the connection came or went

    // A company on a list we search ourselves.
    class Listed {
        public string symbol;
        public string name;
        public string board;
        public string words;   // everything it might be searched by: ticker, names, nickname
    }

    class Found {
        public Hit[] hits;
        public int64 at;
    }

    public Feed (Cache cache) {
        this.cache = cache;
        session.add_feature (new Soup.CookieJar ());   // for the cookie quote_batch() needs
        session.request_queued.connect ((msg) => { msg.request_headers.replace ("User-Agent", agent (msg.uri.get_host ())); });
    }

    // Who we say we are: ourselves, except to Yahoo, which answers 429 to agents that don't look like a browser.
    static string agent (string host) {
        bool yahoo = host == "yahoo.com" || host.has_suffix (".yahoo.com");
        return yahoo ? "Mozilla/5.0 (X11; Linux x86_64)" : @"Stonks/$VERSION (+https://github.com/igneous/stonks)";
    }

    async Json.Object get_json (string url) throws Error {
        var msg = new Soup.Message ("GET", url);
        // Download here, parse there: json-glib parses on a worker thread (a full history is over a
        // megabyte), and libsoup's own stream must not be read from one.
        var body = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
        var parser = new Json.Parser ();
        try {
            yield parser.load_from_stream_async (new MemoryInputStream.from_bytes (body), null);
        } catch (Error e) {
            parser = new Json.Parser ();   // not JSON: a throttling or outage page
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new IOError.FAILED ("%s answered HTTP %u %s", msg.uri.get_host (), msg.status_code, Soup.Status.get_phrase (msg.status_code));
        return root.get_object ();
    }

    // Parallel timestamp and close arrays as a Series, minus the bars a source leaves null
    // (halts, holidays, lunch breaks).
    static Series series (Json.Array ts, Json.Array close, double scale) {
        var s = new Series ();
        for (uint i = 0; i < uint.min (ts.get_length (), close.get_length ()); i++)
            if (!close.get_null_element (i) && close.get_double_element (i) > 0) s.add (ts.get_int_element (i), close.get_double_element (i) * scale);
        return s;
    }

    static bool from_ssi (string symbol) { return symbol.has_suffix (".VN"); }

    // A symbol as the cache last had it, without asking anyone; null if it was never fetched.
    // refresh() brings it up to date.
    public Quote? cached (string symbol) {
        return cache.load (symbol, get_real_time () / 1000000);
    }

    // A symbol from scratch: its whole daily history, a year of hourly bars and the last week of
    // 5-minute ones. The one big download per symbol; afterwards it lives in the cache.
    public async Quote download (string symbol) throws Error {
        var now = get_real_time () / 1000000;
        Quote q;
        if (from_ssi (symbol)) q = yield fetch_ssi (symbol); else q = yield fetch_yahoo (symbol);
        q.checked = q.refreshed = now;
        cache.save (q, now);
        return q;
    }

    // Bring quotes up to date: the price, and the 5-minute bars since the last ones each has. Twice a
    // day at most a quote's daily history is also held against the feed's, and its hourly bars topped up.
    // In as few requests as the feeds allow, and one after another: Yahoo answers for twenty symbols
    // at a time, so a hundred of them cost five requests a round rather than a hundred. SSI has to be
    // asked about each on its own, and so do small exchange rates (see coarse). Trouble reaching a
    // feed ends that feed's round there (one that is refusing us isn't asked nineteen more times).
    // `thorough` holds every history against its feed now, however lately that was done: what the
    // user's own Refresh asks for. Returns the first thing that went wrong, or null.
    public async string? refresh (GenericArray<Quote> quotes, bool thorough = false) {
        var now = get_real_time () / 1000000;
        string? wrong = null;
        for (int i = 0; thorough && i < quotes.length; i++) quotes[i].checked = 0;
        var yahoo = new GenericArray<Quote> ();
        var exact = new GenericArray<Quote> ();
        bool ssi_down = false;
        for (int i = 0; i < quotes.length; i++) {
            var q = quotes[i];
            if (!from_ssi (q.symbol)) (coarse (q) ? exact : yahoo).add (q);
            if (!from_ssi (q.symbol) || ssi_down) continue;
            try {
                if (now - q.checked > 12 * 3600) {
                    q.hourly.merge (yield hours (q.symbol, hours_from (q, now)));
                    var tail = yield ssi_bars (q.symbol, "1D", q.daily.t[q.daily.n - 1] - 12 * 86400);
                    yield reconcile (q, tail, now);
                }
                yield refresh_ssi (q);
                q.refreshed = now;
                cache.save (q, now);
            } catch (Error e) {
                wrong = wrong ?? @"$(q.symbol): $(e.message)";
                ssi_down = true;
            }
        }
        try {
            // Histories first: the prices that follow go into each one's last bar. And hourly bars
            // before daily ones: checking those is what marks a quote as checked.
            foreach (unowned string interval in new string[] { "1h", "1d", "5m" }) {
                var missing = yield spark (yahoo, interval, now);
                if (missing != null) wrong = wrong ?? @"$missing: Yahoo has no data for it";
            }
            for (int i = 0; i < exact.length; i++) {
                var q = exact[i];
                if (now - q.checked > 12 * 3600) {
                    q.hourly.merge (yield hours (q.symbol, hours_from (q, now)));
                    int64 from = q.daily.t[q.daily.n - 1] - 12 * 86400;
                    var tail = yield chart (q.symbol, @"period1=$from&period2=$now&interval=1d");
                    yield reconcile (q, closes (tail), now);
                }
                var bars = yield chart (q.symbol, @"period1=$(bars_from (q, now))&period2=$now&interval=5m");
                apply (q, bars, now);
                q.refreshed = now;
                cache.save (q, now);
            }
        } catch (Error e) {
            wrong = wrong ?? e.message;
        }
        return wrong;
    }

    // Whether spark's figures are too rough for a quote. It rounds prices the way Yahoo's pages print
    // them, which loses nothing on a share, a fund, an index or a coin, but a currency pair gets four
    // decimals whatever its size: fine for USD/JPY at 159.3250, no use for JPY/USD at 0.0063 (and
    // VND/USD comes out as 0). Those are asked about one at a time through chart(), which is exact.
    static bool coarse (Quote q) { return q.kind == "CURRENCY" && q.price < 100; }

    // One pass over Yahoo's quotes through its "spark" endpoint, which is chart() for up to twenty
    // symbols in a request and wants no key either. `interval` says which pass: "1h" or "1d", the
    // twice-daily top-up of hourly bars and check of each history, or "5m", prices and 5-minute bars.
    // Quotes that need the same reach back share requests, so that nobody's is bigger than it has to
    // be. Returns a symbol Yahoo no longer answers for, if there is one; throws if Yahoo can't be had.
    async string? spark (GenericArray<Quote> quotes, string interval, int64 now) throws Error {
        string? missing = null;
        string[] reach = {};
        for (int i = 0; i < quotes.length; i++) {
            var q = quotes[i];
            string r = "";
            if (interval == "5m") {
                // The latest session is all we lack if it is the one we last saw, or if we saw that one
                // out and at most one more can have begun. Otherwise (a first refresh since launch
                // included: none of this is kept on disk) the week of 5-minute bars is asked for whole.
                bool same = now <= q.closes;
                bool next = q.refreshed >= q.closes && now - q.refreshed < 20 * 3600;
                r = same || next ? "1d" : "7d";
            } else if (now - q.checked > 12 * 3600) {
                var have = interval == "1h" ? q.hourly : q.daily;
                int64 gap = have.n > 0 ? now - have.t[have.n - 1] : int64.MAX;
                r = "1y";   // away longer than that and nothing overlaps: reconcile() starts over
                if (gap < 80 * 86400) r = "3mo";
                if (gap < 20 * 86400) r = "1mo";
            }
            reach += r;
        }
        foreach (unowned string r in REACHES) {
            var group = new GenericArray<Quote> ();
            for (int i = 0; i < quotes.length; i++) if (reach[i] == r) group.add (quotes[i]);
            for (int at = 0; at < group.length; at += BATCH) {
                int end = int.min (at + BATCH, group.length);
                string[] symbols = {};
                for (int i = at; i < end; i++) symbols += group[i].symbol;
                var root = yield get_json (@"$YAHOO/v7/finance/spark?symbols=$(Uri.escape_string (string.joinv (",", symbols), ",="))&range=$r&interval=$interval");
                var body = root.has_member ("spark") ? root.get_object_member ("spark") : null;
                if (body == null) throw new IOError.FAILED ("unexpected answer from Yahoo");
                var results = body.has_member ("result") && !body.get_null_member ("result") ? body.get_array_member ("result") : null;
                if (results == null) {
                    // "Not Found" is a request none of whose symbols Yahoo knows: they are all
                    // missing, and the round goes on. Any other refusal ends it.
                    var refusal = body.has_member ("error") && !body.get_null_member ("error") ? body.get_object_member ("error") : null;
                    if (refusal == null || refusal.get_string_member_with_default ("code", "") != "Not Found")
                        throw new IOError.FAILED ("Yahoo: %s", refusal != null ? refusal.get_string_member_with_default ("description", "unexpected answer") : "unexpected answer");
                }
                var answers = new HashTable<string, Json.Object> (str_hash, str_equal);
                for (uint k = 0; results != null && k < results.get_length (); k++) {
                    var o = results.get_object_element (k);
                    if (o.has_member ("response") && o.get_array_member ("response").get_length () > 0)
                        answers[o.get_string_member_with_default ("symbol", "")] = o.get_array_member ("response").get_object_element (0);
                }
                for (int i = at; i < end; i++) {
                    var q = group[i];
                    var result = answers[q.symbol];
                    if (result == null) {
                        // Delisted, or renamed: Yahoo just leaves it out. (Having no hourly bars is no news.)
                        if (interval != "1h") missing = missing ?? q.symbol;
                        continue;
                    }
                    if (interval == "1h") {
                        q.hourly.merge (closes (result));
                    } else if (interval == "1d") {
                        var theirs = closes (result);
                        var tail = yield with_past (q.symbol, theirs, q.daily.t[q.daily.n - 1] - 12 * 86400, q.gmtoffset);
                        // If CNBC supplied the past here and we hold nothing older than this stretch,
                        // ours is only what Yahoo had (a cache from before CNBC was asked): start over.
                        if (tail.n > theirs.n && q.daily.t[0] >= tail.t[0]) tail = new Series ();
                        yield reconcile (q, tail, now);
                    } else {
                        apply (q, result, now);
                        q.refreshed = now;
                        if (q == followed) yield extend (q);
                    }
                    cache.save (q, now);
                }
            }
        }
        return missing;
    }

    // Hold a fresh stretch of daily bars against ours. Normally they agree and any new days are
    // appended. If a split or a dividend adjustment has rewritten the past, they don't, and the whole
    // history is downloaded again; likewise if the stretch is empty or shares no day with ours.
    async void reconcile (Quote q, Series tail, int64 now) throws Error {
        if (q.daily.agrees (tail, q.gmtoffset)) {
            q.daily.merge (tail);
        } else {
            Quote again;
            if (from_ssi (q.symbol)) again = yield fetch_ssi (q.symbol); else again = yield fetch_yahoo (q.symbol);
            q.daily = again.daily;
            q.intra = again.intra;
            q.hourly = again.hourly;
            q.name = again.name;
            q.currency = again.currency;
            q.kind = again.kind;
            q.gmtoffset = again.gmtoffset;
        }
        q.checked = now;
    }

    // From when to ask for 5-minute bars: a little before the last one we have, or a week back.
    static int64 bars_from (Quote q, int64 now) {
        int64 week = now - 7 * 86400;
        return q.intra.n > 0 && q.intra.t[q.intra.n - 1] > week ? q.intra.t[q.intra.n - 1] - 1800 : week;
    }

    // From when to ask for hourly bars: a day before the last one we have, or a year back.
    static int64 hours_from (Quote q, int64 now) {
        int64 year = now - 365 * 86400;
        return q.hourly.n > 0 ? int64.max (q.hourly.t[q.hourly.n - 1] - 86400, year) : year;
    }

    // Hourly closes since `from`, for the charts between a week and a year long. Nobody's refresh
    // fails for want of them: empty if they can't be had, and daily closes are charted instead.
    // Vietnam's are Entrade's, whose hours close where SSI's days do (both adjust for dividends).
    async Series hours (string symbol, int64 from) {
        var now = get_real_time () / 1000000;
        try {
            if (!from_ssi (symbol)) return closes (yield chart (symbol, @"period1=$from&period2=$now&interval=1h"));
            var code = ssi_code (symbol);
            if (code == "HNXINDEX") code = "HNX";   // the one name the two don't share
            var root = yield get_json (@"$ENTRADE_BARS/$(symbol.has_prefix ("^") ? "index" : "stock")?from=$from&to=$now&symbol=$(Uri.escape_string (code))&resolution=1H");
            if (root.has_member ("t") && !root.get_null_member ("t") && root.has_member ("c") && !root.get_null_member ("c"))
                return series (root.get_array_member ("t"), root.get_array_member ("c"), symbol.has_prefix ("^") ? 1 : 1000);
        } catch (Error e) {}
        return new Series ();
    }

    // A US security's full name ("Alphabet Inc. - Class C Capital Stock") if we know it, else null.
    public string? full_name (string symbol) {
        return names != null ? names[symbol] : null;
    }

    // Full names of US-listed securities, from Nasdaq Trader's symbol directory. Yahoo calls every share
    // class of a company the same thing ("Alphabet Inc." for GOOG, GOOGL, GOOGM and GOOGN alike); these
    // say which is which. Two small files, downloaded once a week and kept in the cache.
    public async void load_names () {
        if (names != null) return;
        var now = get_real_time () / 1000000;
        names = cache.load_names (now);
        if (names != null) return;
        var found = new HashTable<string, string> (str_hash, str_equal);
        foreach (var file in new string[] { "nasdaqlisted", "otherlisted" }) {
            try {
                var msg = new Soup.Message ("GET", @"https://www.nasdaqtrader.com/dynamic/symdir/$file.txt");
                var body = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                if (msg.status_code != 200 || body.get_size () == 0) continue;
                // Lines are Symbol|Security Name|...; class shares are BRK.B there and BRK-B on Yahoo.
                foreach (var line in ((string) body.get_data ()).substring (0, (long) body.get_size ()).split ("\n")) {
                    var field = line.split ("|");
                    if (field.length > 1) found[field[0].replace (".", "-")] = field[1];
                }
            } catch (Error e) {}
        }
        if (found.size () > 0) {   // else offline: try again next time
            names = found;
            cache.save_names (found, now);
        }
    }

    // The exact ticker in Vietnam if there is one (on any of its three boards), then up to five Yahoo
    // matches by name or ticker.
    // With no market chosen, Vietnamese companies are found by exact ticker only (plus whatever Yahoo's
    // search knows of Ho Chi Minh); choosing Vietnam searches the full list by name, see find_in().
    // Prices and market caps come in the security's own currency, with `into` as a second opinion.
    // `market` is one of MARKETS' codes: "" searches everywhere, anything else only there.
    public async Hit[] search (string text, string into, string market = "") {
        var now = get_real_time () / 1000000;
        var key = into + "\n" + market + "\n" + text.down ();
        var seen = found[key];
        if (seen != null && now - seen.at < 900) return seen.hits;   // typed again within a quarter of an hour
        Hit[] hits;
        if (market == "") hits = yield find (text); else hits = yield find_in (text, market);
        yield rate_hits (hits, into);
        found[key] = new Found () { hits = hits, at = now };
        return hits;
    }

    async Hit[] find (string text) {
        Hit[] hits = {};
        yield load_names ();   // normally there already; this retries if we started offline

        // A pair written the way people write them, USD->VND or BTC/USD: Yahoo files currencies as
        // USDVND=X and crypto as BTC-USD, so offer whichever of the two it actually quotes.
        var sides = text.up ().replace ("->", "/").replace ("→", "/").replace (" ", "").split ("/");
        if (sides.length == 2 && sides[0].length >= 3 && sides[1].length >= 3) {
            Hit[] pair = { new Hit () { symbol = sides[0] + sides[1] + "=X" }, new Hit () { symbol = sides[0] + "-" + sides[1] } };
            yield price_hits (pair);
            foreach (var hit in pair) if (hit.price.is_finite ()) hits += hit;
            if (hits.length > 0) return hits;
        }
        var vietnamese = yield ssi_hit (text);
        if (vietnamese != null) hits += vietnamese;
        try {
            var root = yield get_json (@"$YAHOO/v1/finance/search?q=$(Uri.escape_string (text))&quotesCount=5&newsCount=0");
            var quotes = root.has_member ("quotes") ? root.get_array_member ("quotes") : new Json.Array ();
            for (uint i = 0; i < quotes.get_length (); i++) {
                var o = quotes.get_object_element (i);
                if (!o.has_member ("symbol")) continue;
                var symbol = o.get_string_member ("symbol");
                if (hits.length > 0 && hits[0].symbol == symbol) continue;   // the Vietnamese match, already listed
                string? full = names != null ? names[symbol] : null;
                string[] facts = {};
                foreach (var key in new string[] { "exchDisp", "typeDisp", "sectorDisp", "industryDisp" })
                    if (o.get_string_member_with_default (key, "") != "") facts += o.get_string_member (key);
                hits += new Hit () {
                    symbol = symbol,
                    name = full ?? o.get_string_member_with_default ("longname", o.get_string_member_with_default ("shortname", symbol)),
                    detail = string.joinv (" · ", facts)
                };
            }
        } catch (Error e) {}
        yield price_hits (hits);
        return hits;
    }

    // Fill in price and market cap for the Yahoo hits, all in one request. Unlike Yahoo's other
    // endpoints this one wants a cookie plus a matching "crumb" token; Yahoo hands both to anyone who
    // asks, no account involved. If it stops working the hits simply come without numbers.
    // Vietnam's listed stocks and funds, all three boards, so they can be searched by name: English,
    // Vietnamese (with or without the accents) or nickname ("Vinamilk"). One download of Vietcap's
    // symbol directory, kept for a week.
    async void load_vietnam () {
        if (vietnam != null) return;
        var now = get_real_time () / 1000000;
        var body = cache.kept ("vietnam", 7 * 86400, now);
        bool fresh = body == null;
        try {
            string where;
            if (body == null) body = yield fetch ("https://trading.vietcap.com.vn/api/price/symbols/getAll", out where);
            if (body == null) return;
            var parser = new Json.Parser ();
            yield parser.load_from_stream_async (new MemoryInputStream.from_bytes (body), null);
            var list = new GenericArray<Listed> ();
            var all = parser.get_root ().get_array ();
            for (uint i = 0; i < all.get_length (); i++) {
                var o = all.get_object_element (i);
                var type = o.get_string_member_with_default ("type", ""), board = o.get_string_member_with_default ("board", "");
                if ((type != "STOCK" && type != "ETF") || (board != "HSX" && board != "HNX" && board != "UPCOM")) continue;   // not warrants, bonds or the delisted
                var code = o.get_string_member_with_default ("symbol", "");
                var english = o.get_string_member_with_default ("enOrganName", ""), local = o.get_string_member_with_default ("organName", "");
                list.add (new Listed () {
                    symbol = code + ".VN", name = english != "" ? english : local, board = board == "HSX" ? "HOSE" : board,
                    words = "%s %s %s %s".printf (code, english, o.get_string_member_with_default ("organShortName", ""), local)
                });
            }
            if (list.length == 0) return;
            // Ho Chi Minh's first, then Hanoi's, then UPCoM: roughly biggest first, as matches are taken in order.
            list.sort ((a, b) => a.board != b.board ? "HOSE HNX UPCOM".index_of (a.board) - "HOSE HNX UPCOM".index_of (b.board) : strcmp (a.symbol, b.symbol));
            vietnam = list;
            if (fresh) cache.keep ("vietnam", body, now);
        } catch (Error e) {}
    }

    // Text that is exactly a Vietnamese ticker (or one of the indices), on any of the three boards: SSI
    // knows them all, where Yahoo only lists Ho Chi Minh. Null if it isn't one.
    async Hit? ssi_hit (string text) {
        var code = text.up ();
        if (code.has_suffix (".VN")) code = code[0:code.length - 3];
        bool plausible = code.length >= 3 && code.length <= 8;
        for (int i = 0; i < code.length; i++) plausible &= code[i].isalnum ();
        if (!plausible) return null;
        var info = yield ssi_info (code);
        bool index = code == "VNINDEX" || code == "VN30" || code == "HNXINDEX";
        if (info == null && !index) return null;
        var hit = new Hit () { symbol = index ? "^" + code + ".VN" : code + ".VN", name = code, detail = "Index · Vietnam", currency = "VND" };
        if (info != null) {
            hit.name = info.get_string_member_with_default ("companyNameEn", code);
            hit.detail = "%s · Vietnam".printf (info.get_string_member_with_default ("exchange", "").up ());
            hit.price = info.get_double_member_with_default ("refPrice", double.NAN);   // yesterday's close, unless...
        }
        try {
            var bars = yield ssi_bars (hit.symbol, "5", get_real_time () / 1000000 - 7 * 86400);
            if (bars.n > 0) hit.price = bars.v[bars.n - 1];                               // ...it has traded since
        } catch (Error e) {}
        if (info != null) hit.cap = hit.price * info.get_double_member_with_default ("listedShare", double.NAN);
        return hit;
    }

    // Search one market only. Yahoo's search endpoint gives seven results at most and can't be
    // narrowed, so this asks its lookup endpoint instead: up to a hundred matches for the text, each
    // with its symbol and type, of which we keep the first six that belong to the market.
    async Hit[] find_in (string text, string market) {
        Hit[] hits = {};
        string[] industries = {};
        yield load_names ();
        if (market == ".VN") {
            // Vietnam we search ourselves: Yahoo's lookup stops at a hundred matches worldwide, which
            // few Vietnamese companies ever make, and it knows only Ho Chi Minh's.
            var exact = yield ssi_hit (text);   // the ticker itself, priced by SSI whatever its board
            if (exact != null) hits += exact;
            yield load_vietnam ();
            var code = text.up ();
            // Tickers that start with what was typed, then anything whose names match it.
            for (int pass = 0; vietnam != null && pass < 2; pass++) {
                for (int i = 0; i < vietnam.length && hits.length < 6; i++) {
                    var listed = vietnam[i];
                    bool starts = listed.symbol.has_prefix (code);
                    bool match = starts;
                    if (pass == 1) match = !starts && text.match_string (listed.words, true);
                    if (!match || (exact != null && exact.symbol == listed.symbol)) continue;
                    hits += new Hit () { symbol = listed.symbol, name = listed.name, detail = @"$(listed.board) · Vietnam", currency = "VND" };
                }
            }
            if (vietnam != null) {
                yield price_hits (hits);   // Yahoo can price the Ho Chi Minh ones; the others go without
                return hits;
            }
            foreach (var hit in hits) industries += "";   // no list (offline?): fall back on Yahoo's lookup
        }
        try {
            var type = market.has_prefix ("=") ? market.substring (1) : "all";
            var root = yield get_json (@"$YAHOO/v1/finance/lookup?query=$(Uri.escape_string (text))&type=$type&count=100&start=0&formatted=false&fetchPricingData=false&lang=en-US&region=US");
            var result = root.has_member ("finance") && root.get_object_member ("finance").has_member ("result") && !root.get_object_member ("finance").get_null_member ("result")
                ? root.get_object_member ("finance").get_array_member ("result") : new Json.Array ();
            var found = result.get_length () > 0 && result.get_object_element (0).has_member ("documents")
                ? result.get_object_element (0).get_array_member ("documents") : new Json.Array ();
            for (uint i = 0; i < found.get_length () && hits.length < 6; i++) {
                var o = found.get_object_element (i);
                var symbol = o.get_string_member_with_default ("symbol", "");
                var kind = o.get_string_member_with_default ("quoteType", "").up ();
                bool there = market.has_prefix ("=");   // the lookup was asked for that type alone
                if (market.has_prefix (".")) there = symbol.has_suffix (market);
                if (market == "US") there = !symbol.contains (".") && (kind == "EQUITY" || kind == "ETF" || kind == "MUTUALFUND");
                if (symbol == "" || !there || (hits.length > 0 && hits[0].symbol == symbol)) continue;
                // Its name: the full one for a US security if we have it, else Yahoo's long name, which
                // price_hits fetches along with the exchange; the lookup's own is cut short at 31 letters.
                string? full = names != null ? names[symbol] : null;
                hits += new Hit () { symbol = symbol, name = full ?? "" };
                industries += o.get_string_member_with_default ("industryName", "");
            }
            yield price_hits (hits);
            for (int i = 0; i < hits.length; i++) {
                if (hits[i].name == "") hits[i].name = hits[i].symbol;
                if (industries[i] != "") hits[i].detail += " · " + industries[i];
            }
        } catch (Error e) {}
        return hits;
    }

    async void price_hits (Hit[] hits) {
        string[] symbols = {};
        foreach (var hit in hits) if (!hit.price.is_finite ()) symbols += hit.symbol;
        var quotes = yield quote_batch (symbols, "regularMarketPrice,currency,marketCap,longName,shortName,fullExchangeName,typeDisp");
        for (uint i = 0; quotes != null && i < quotes.get_length (); i++) {
            var o = quotes.get_object_element (i);
            foreach (var hit in hits) {
                if (hit.symbol != o.get_string_member_with_default ("symbol", "")) continue;
                hit.currency = o.get_string_member_with_default ("currency", "");
                hit.price = o.get_double_member_with_default ("regularMarketPrice", double.NAN);
                hit.cap = o.get_double_member_with_default ("marketCap", double.NAN);   // funds and warrants have none
                // Hits that didn't come from the search endpoint arrive without these: a pair whose
                // symbol we guessed, or a lookup result (which may bring a better name of its own).
                if (hit.name == "") hit.name = o.get_string_member_with_default ("longName", o.get_string_member_with_default ("shortName", hit.symbol));
                if (hit.detail == "") hit.detail = "%s · %s".printf (o.get_string_member_with_default ("fullExchangeName", ""), o.get_string_member_with_default ("typeDisp", ""));
            }
        }
    }

    // A Yahoo endpoint that wants the cookie-and-crumb handshake (no account involved: Yahoo hands both
    // to anyone who asks). `url` ends in its query string. Null if it can't be had right now.
    async Json.Object? authed (string url) {
        try {
            if (crumb == null) {
                yield session.send_and_read_async (new Soup.Message ("GET", "https://fc.yahoo.com"), Priority.DEFAULT, null);   // a 404 that sets the cookie
                var reply = yield session.send_and_read_async (new Soup.Message ("GET", "https://query2.finance.yahoo.com/v1/test/getcrumb"), Priority.DEFAULT, null);
                crumb = reply.get_size () > 0 ? ((string) reply.get_data ()).substring (0, (long) reply.get_size ()) : "";
            }
            var root = yield get_json (@"$url&crumb=$(Uri.escape_string (crumb))");
            if (!root.has_member ("finance")) return root;   // {"finance": {"error": ...}} is the refusal
        } catch (Error e) {}
        crumb = null;   // refused or unreachable: the crumb may have gone stale, so get a new one next time
        return null;
    }

    // Yahoo's quote endpoint for several symbols at once; null if it can't be had right now.
    async Json.Array? quote_batch (string[] symbols, string fields) {
        if (symbols.length == 0) return null;
        var root = yield authed (@"$YAHOO/v7/finance/quote?fields=$fields&symbols=$(Uri.escape_string (string.joinv (",", symbols), ",="))");
        return root != null && root.has_member ("quoteResponse") ? root.get_object_member ("quoteResponse").get_array_member ("result") : null;
    }

    // Fill in the statistics of several quotes at once (day's range, market cap, P/E, dividend, trading
    // outside hours...): one request, whatever their number. Quotes Yahoo doesn't know keep what they had.
    public async void load_stats (GenericArray<Quote> quotes) {
        var now = get_real_time () / 1000000;
        string[] symbols = {};
        for (int i = 0; i < quotes.length; i++) {
            // Not Vietnam's indices: Yahoo answers for them, but out of a single day of history (a
            // "52-week range" a few points wide). Better none, and the ranges worked out from SSI's bars.
            if (!(quotes[i].symbol.has_prefix ("^") && from_ssi (quotes[i].symbol))) symbols += quotes[i].symbol;
        }
        var answers = yield quote_batch (symbols, "regularMarketOpen,regularMarketDayHigh,regularMarketDayLow,regularMarketPreviousClose,regularMarketVolume,averageDailyVolume3Month,marketCap,trailingPE,epsTrailingTwelveMonths,fiftyTwoWeekHigh,fiftyTwoWeekLow,dividendYield,dividendRate,trailingAnnualDividendRate,postMarketPrice,postMarketChangePercent,preMarketPrice,preMarketChangePercent,regularMarketTime,marketState,exchangeTimezoneShortName,fullExchangeName");
        for (uint i = 0; answers != null && i < answers.get_length (); i++) {
            var o = answers.get_object_element (i);
            for (int k = 0; k < quotes.length; k++) {
                if (quotes[k].symbol != o.get_string_member_with_default ("symbol", "")) continue;
                var s = new Stats ();
                s.open = o.get_double_member_with_default ("regularMarketOpen", double.NAN);
                if (s.open <= 0) s.open = double.NAN;   // Yahoo sends 0 for "not yet"
                s.high = o.get_double_member_with_default ("regularMarketDayHigh", double.NAN);
                s.low = o.get_double_member_with_default ("regularMarketDayLow", double.NAN);
                s.prev_close = o.get_double_member_with_default ("regularMarketPreviousClose", double.NAN);
                s.volume = o.get_double_member_with_default ("regularMarketVolume", double.NAN);
                s.avg_volume = o.get_double_member_with_default ("averageDailyVolume3Month", double.NAN);
                s.cap = o.get_double_member_with_default ("marketCap", double.NAN);
                s.pe = o.get_double_member_with_default ("trailingPE", double.NAN);
                s.eps = o.get_double_member_with_default ("epsTrailingTwelveMonths", double.NAN);
                s.high52 = o.get_double_member_with_default ("fiftyTwoWeekHigh", double.NAN);
                s.low52 = o.get_double_member_with_default ("fiftyTwoWeekLow", double.NAN);
                // Yahoo works that range out of whatever history it has, which for some indices is a
                // week (^SPXXAI). A real one holds every close of the year; one that doesn't is dropped,
                // and the card works it out from our bars instead. Not SSI's bars, which are adjusted
                // for dividends where Yahoo's range isn't.
                double low, high;
                Quote.extremes (quotes[k].daily, now - 360 * 86400, out low, out high);
                if (!from_ssi (quotes[k].symbol) && (s.low52 > low * 1.001 || s.high52 < high * 0.999)) s.low52 = s.high52 = double.NAN;
                s.dividend_yield = o.get_double_member_with_default ("dividendYield", double.NAN);
                s.dividend_rate = o.get_double_member_with_default ("dividendRate", o.get_double_member_with_default ("trailingAnnualDividendRate", double.NAN));
                s.state = o.get_string_member_with_default ("marketState", "");
                s.zone = o.get_string_member_with_default ("exchangeTimezoneShortName", "");
                s.exchange = o.get_string_member_with_default ("fullExchangeName", "");
                s.time = o.get_int_member_with_default ("regularMarketTime", 0);
                if (s.state.has_prefix ("PRE") && o.has_member ("preMarketPrice")) {
                    s.extra = "Pre-market";
                    s.extra_price = o.get_double_member ("preMarketPrice");
                    s.extra_change = o.get_double_member_with_default ("preMarketChangePercent", double.NAN);
                } else if (s.state != "REGULAR" && o.has_member ("postMarketPrice")) {
                    s.extra = "After hours";
                    s.extra_price = o.get_double_member ("postMarketPrice");
                    s.extra_change = o.get_double_member_with_default ("postMarketChangePercent", double.NAN);
                }
                quotes[k].stats = s;
            }
        }
    }

    // ---- A point in the past ----

    // A symbol's every day in full and its earnings history, for describing a point of its past (see
    // Past.at). Two requests, made the first time one of its points is pinned; the answer is kept for
    // the session, until the quote has a day it doesn't (and a quarter of an hour at the least, however
    // the two feeds' days compare). Null if it can't be had right now.
    public async Past? past (Quote q) {
        var now = get_real_time () / 1000000;
        var kept = pasts[q.symbol];
        bool whole = kept != null && (kept.close.t[kept.close.n - 1] + q.gmtoffset) / 86400 >= (q.daily.t[q.daily.n - 1] + q.gmtoffset) / 86400;
        if (kept != null && (whole || now - kept.fetched < 900)) return kept;
        var past = new Past () { fetched = now };
        int64 split = 0;   // when its shares were last split
        try {
            Json.Object bars;
            Json.Array times;
            double scale = 1;
            if (from_ssi (q.symbol)) {
                var root = yield get_json (@"$SSI_BARS?resolution=1D&symbol=$(Uri.escape_string (ssi_code (q.symbol)))&from=0&to=$now");
                if (!root.has_member ("data") || root.get_null_member ("data") || !root.get_object_member ("data").has_member ("t")) return null;
                bars = root.get_object_member ("data");
                times = bars.get_array_member ("t");
                if (!q.symbol.has_prefix ("^")) scale = 1000;
            } else {
                // Split-adjusted like our closes, and (also like them) not adjusted for dividends.
                var result = yield chart (q.symbol, @"period1=$(now - 36000 * (int64) 86400)&period2=$now&interval=1d&events=div,splits");
                if (!result.has_member ("timestamp")) return null;   // nothing ever traded
                bars = result.get_object_member ("indicators").get_array_member ("quote").get_object_element (0);
                times = result.get_array_member ("timestamp");
                var events = result.has_member ("events") ? result.get_object_member ("events") : new Json.Object ();
                if (events.has_member ("dividends")) events.get_object_member ("dividends").foreach_member ((o, name, node) => {
                    past.dividends.put (node.get_object ().get_int_member_with_default ("date", 0), node.get_object ().get_double_member_with_default ("amount", 0));
                });
                if (events.has_member ("splits")) events.get_object_member ("splits").foreach_member ((o, name, node) => {
                    split = int64.max (split, node.get_object ().get_int_member_with_default ("date", 0));
                });
            }
            // Both feeds call the columns by their initials or their names; neither has every cell.
            Json.Array[] columns = {};
            foreach (unowned string name in new string[] { "open", "high", "low", "close", "volume" }) {
                var key = bars.has_member (name) ? name : name.substring (0, 1);
                if (!bars.has_member (key) || bars.get_null_member (key)) return null;
                columns += bars.get_array_member (key);
            }
            Series[] into = { past.open, past.high, past.low, past.close, past.volume };
            for (uint i = 0; i < times.get_length (); i++) {
                if (i >= columns[3].get_length () || columns[3].get_null_element (i)) continue;   // a day without a close: no bar
                for (int k = 0; k < 5; k++) {
                    bool there = i < columns[k].get_length () && !columns[k].get_null_element (i);
                    into[k].add (times.get_int_element (i), there ? columns[k].get_double_element (i) * (k < 4 ? scale : 1) : double.NAN);
                }
            }
        } catch (Error e) {
            return null;
        }
        if (past.close.n == 0) return null;
        try {
            // What it reported, as far back as Yahoo gives it out: four fiscal years, the last few
            // quarters in more detail. Figures in another currency than it trades in (an ADR's) are
            // left out, as are trailing earnings from before a split: only some of those are restated
            // for it, and nothing says which. The yearly figures all are.
            var root = yield get_json (@"$YAHOO/ws/fundamentals-timeseries/v1/finance/timeseries/$(Uri.escape_string (q.symbol, "="))?type=trailingDilutedEPS,annualDilutedEPS,quarterlyOrdinarySharesNumber,annualOrdinarySharesNumber&period1=0&period2=$now");
            var results = root.get_object_member ("timeseries").get_array_member ("result");
            reported (results, "trailingDilutedEPS", q.currency, split, past.eps);
            reported (results, "annualDilutedEPS", q.currency, 0, past.eps);
            reported (results, "quarterlyOrdinarySharesNumber", q.currency, 0, past.shares);
            reported (results, "annualOrdinarySharesNumber", q.currency, 0, past.shares);
        } catch (Error e) {}   // an index, a fund, a coin: nothing to report
        pasts[q.symbol] = past;
        return past;
    }

    // One kind of figure out of Yahoo's fundamentals, a point per period end, for those ending after `after`.
    static void reported (Json.Array results, string type, string currency, int64 after, Series into) {
        for (uint i = 0; i < results.get_length (); i++) {
            var o = results.get_object_element (i);
            if (!o.has_member (type) || o.get_null_member (type)) continue;
            var rows = o.get_array_member (type);
            for (uint k = 0; k < rows.get_length (); k++) {
                if (rows.get_null_element (k)) continue;
                var row = rows.get_object_element (k);
                var day = new DateTime.from_iso8601 (row.get_string_member_with_default ("asOfDate", "") + "T00:00:00Z", null);
                if (day == null || day.to_unix () <= after || !row.has_member ("reportedValue")) continue;
                if (row.get_string_member_with_default ("currencyCode", currency) != currency) continue;
                into.put (day.to_unix (), row.get_object_member ("reportedValue").get_double_member_with_default ("raw", double.NAN));
            }
        }
    }

    // ---- Live prices ----

    // Have one quote's price follow its trades as they happen, or none (null). Yahoo's pages keep a
    // socket open for this: subscribed to a symbol, it sends that symbol's price whenever it changes,
    // every few seconds while it trades. `heard` fires as prices come in and as the connection comes
    // and goes; `live` and `pace` say how it stands. Safe to call again and again: it only acts on a
    // change, or to try again after the connection was lost.
    // Not Vietnam's symbols, which Yahoo doesn't price for us, and not the pairs it rounds (see coarse).
    public void follow (Quote? q) {
        if (q != null && (from_ssi (q.symbol) || coarse (q))) q = null;
        if (q == followed && (q == null || socket != null)) return;
        if (q != followed) {
            followed = q;
            live = false;
            pace = double.NAN;
            heard_at = 0;
            if (socket != null) {
                var old = socket;
                socket = null;
                tuned++;
                old.close (Soup.WebsocketCloseCode.NORMAL, null);
            }
            heard ();
            if (q != null) extend.begin (q);
        }
        if (q != null) listen.begin ();
    }

    // What the followed quote has traded outside regular hours since its last regular bar, for its 1D
    // chart to go on with (see Quote.carry): pre-market, after hours, and the night between. One small
    // request, when its card opens and each time the quote is refreshed (every quarter of an hour, out
    // of session); the stream fills in between. Nothing is asked for an instrument Yahoo has no such
    // prices for (anything but US shares and funds), nor while its regular session is on.
    async void extend (Quote q) {
        var now = get_real_time () / 1000000;
        var late = new Series ();
        if (q.extended && q.intra.n > 0 && !(now >= q.opens && now < q.closes)) {
            try {
                int64 last = q.intra.t[q.intra.n - 1];
                var bars = closes (yield chart (q.symbol, @"period1=$last&period2=$now&interval=5m&includePrePost=true"));
                for (int i = 0; i < bars.n; i++) {
                    // ponytail: "regular hours" are the last session's, on any day. A half day or a clock
                    // change can be an hour or three out, for the quarter of an hour until the next refresh.
                    bool regular = (bars.t[i] - q.opens) % 86400 < q.closes - q.opens;
                    if (bars.t[i] > last && !regular) late.add (bars.t[i], bars.v[i]);
                }
            } catch (Error e) {
                return;   // can't be had right now: what we have stands
            }
        }
        q.late = late;
        heard ();
    }

    async void listen () {
        if (connecting) return;
        connecting = true;
        while (followed != null && socket == null) {
            var q = followed;
            try {
                var ws = yield session.websocket_connect_async (new Soup.Message ("GET", STREAM), null, null, Priority.DEFAULT, null);
                if (followed != q) {   // the user moved on while it connected
                    ws.close (Soup.WebsocketCloseCode.NORMAL, null);
                    continue;
                }
                socket = ws;
                uint mine = ++tuned;
                // Quiet markets send nothing for hours: pings keep the connection up meanwhile.
                // ponytail: one that dies without a word (a suspended laptop) is only noticed when TCP
                // gives up on it; libsoup 3.6's keepalive_pong_timeout would notice within seconds.
                ws.keepalive_interval = 20;
                ws.message.connect ((type, body) => { if (mine == tuned) hear (q, body); });
                ws.closed.connect (() => {
                    if (mine != tuned) return;
                    socket = null;   // lost: the next follow() connects again
                    live = false;
                    heard ();
                });
                ws.send_text ("{\"subscribe\":[\"%s\"]}".printf (q.symbol));
                live = true;
            } catch (Error e) {
                break;   // can't be had right now: the next follow() tries again
            }
        }
        connecting = false;
        heard ();
    }

    // A message off the stream: {"type": "pricing", "message": a PricingData, in base64}.
    void hear (Quote q, Bytes body) {
        try {
            var node = Json.from_string ((string) body.get_data ());   // libsoup ends a message with a NUL
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) return;
            var trade = Trade.decode (Base64.decode (node.get_object ().get_string_member_with_default ("message", "")));
            if (trade.symbol != q.symbol || !(trade.price > 0)) return;
            if (trade.session == 1) {
                q.trade (trade.price, trade.time);
            } else {
                // Before or after hours: the price stays the regular session's. This is the card's
                // other line, and the grey end of its 1D chart.
                if (q.extended) Quote.fold (q.late, trade.price, trade.time);
                if (q.stats.extra != "") {
                    q.stats.extra_price = trade.price;
                    q.stats.extra_change = trade.change;
                }
            }
            int64 at = get_monotonic_time ();
            if (heard_at > 0) pace = pace.is_finite () ? pace * 0.7 + (at - heard_at) / 1e6 * 0.3 : (at - heard_at) / 1e6;
            heard_at = at;
            heard ();
        } catch (Error e) {}
    }

    // Seconds since the stream last sent a price; NaN if it hasn't yet.
    public double quiet () {
        return heard_at > 0 ? (get_monotonic_time () - heard_at) / 1e6 : double.NAN;
    }

    // ---- Logos ----
    // Looked up once per symbol and then kept for good, "there is none" included: nothing here is
    // asked for a second time unless the user says to (forget_logos).

    // What the cache has: the image file's bytes, or null. `known` is whether we ever looked.
    public Bytes? cached_logo (string symbol, out bool known) {
        return cache.logo (symbol, out known);
    }

    public void forget_logos () {
        cache.forget_logos ();
    }

    // Record that what we found for a symbol is no use (not an image we can draw), so it isn't fetched again.
    public void no_logo (string symbol) {
        cache.save_logo (symbol, null);
    }

    // Find a symbol's logo and remember the answer. Null if it has none; throws if we couldn't find out,
    // in which case nothing is remembered and it can be tried another day.
    //   an index, pair or future   none, without asking anyone: there is no such logo
    //   a Vietnamese ticker        Simplize's logo CDN, by ticker
    //   everything else            Financial Modeling Prep's logo images, by ticker: proper brand logos
    //                              for stocks, funds and coins on every exchange we use, at 100px and up
    //   ...and if it has none      EODHD's logo images, then Finnhub's (stocks on the exchanges each covers)
    //   ...and if they have none   a coin: the image Yahoo's quote links to
    //                              a company: an icon from its own website (see site_icon), the last resort
    public async Bytes? logo (string symbol, string kind) throws Error {
        Bytes? image = null;
        bool unsure = false;   // a source couldn't be reached, so "none" would be a guess
        if (kind == "INDEX" || kind == "CURRENCY" || kind == "FUTURE") {
        } else if (from_ssi (symbol)) {
            image = yield image_at (@"https://cdn.simplize.vn/simplizevn/logo/$(Uri.escape_string (ssi_code (symbol))).jpeg");
        } else {
            string?[] hosts = { @"https://financialmodelingprep.com/image-stock/$(Uri.escape_string (symbol, "=")).png", null, null };
            if (kind != "CRYPTOCURRENCY") {
                hosts[1] = eodhd_logo (symbol);
                // Finnhub takes Yahoo's tickers as they are, bar the dot in a US share class (BRK.B).
                hosts[2] = "https://static2.finnhub.io/file/publicdatany/finnhubimage/stock_logo/%s.png".printf (symbol.contains (".") ? symbol : symbol.replace ("-", "."));
            }
            foreach (var host in hosts) {
                if (image != null || host == null) continue;
                try {
                    image = yield image_at (host);
                } catch (Error e) {
                    unsure = true;
                }
            }
            if (image == null && kind == "CRYPTOCURRENCY") {
                var quotes = yield quote_batch ({ symbol }, "logoUrl");
                if (quotes == null) throw new IOError.FAILED ("Yahoo's quote can't be reached");
                if (quotes.get_length () > 0) image = yield image_at (quotes.get_object_element (0).get_string_member_with_default ("logoUrl", ""));
            }
            if (image == null && (kind == "EQUITY" || kind == "")) image = yield site_icon (symbol);
        }
        if (image == null && unsure) throw new IOError.FAILED ("the logo source can't be reached");
        cache.save_logo (symbol, image);
        return image;
    }

    // Where EODHD keeps a symbol's logo: under its own code for the exchange, by the bare ticker
    // (lower-case for the US). Null for an exchange it doesn't have or we haven't mapped, and for US
    // share classes and funds, which it lacks: no point asking.
    static string? eodhd_logo (string symbol) {
        string[] folders = { ".T", "TSE", ".KS", "KO", ".SS", "SHG", ".SZ", "SHE", ".HK", "HK", ".L", "LSE", ".TO", "TO", ".DE", "XETRA", ".PA", "PA", ".AS", "AS" };
        if (!symbol.contains (".")) return symbol.contains ("-") ? null : @"https://eodhd.com/img/logos/US/$(symbol.down ()).png";
        for (int i = 0; i < folders.length; i += 2)
            if (symbol.has_suffix (folders[i])) return @"https://eodhd.com/img/logos/$(folders[i + 1])/$(symbol[0:symbol.length - folders[i].length]).png";
        return null;
    }

    // The icon of the company's own website, for when nobody has its logo. Yahoo's profile names the
    // site; the site's front page says where its icons are. A site that declares nothing large is also
    // asked for /apple-touch-icon.png, which many keep without mentioning it (apple.com does). Plenty of
    // big companies really do publish nothing over 16 to 48 pixels, though.
    async Bytes? site_icon (string symbol) throws Error {
        var root = yield authed (@"$YAHOO/v10/finance/quoteSummary/$(Uri.escape_string (symbol, "="))?modules=assetProfile");
        if (root == null) throw new IOError.FAILED ("Yahoo's company profile can't be reached");
        string site = "";
        var summary = root.has_member ("quoteSummary") ? root.get_object_member ("quoteSummary") : null;
        if (summary != null && summary.has_member ("result") && !summary.get_null_member ("result")) {
            var result = summary.get_array_member ("result");
            if (result.get_length () > 0 && result.get_object_element (0).has_member ("assetProfile"))
                site = result.get_object_element (0).get_object_member ("assetProfile").get_string_member_with_default ("website", "");
        }
        if (site == "") return null;
        // Yahoo answered, so the network is fine: if the company's site won't play, that is its answer.
        try {
            string where = site, icon = "/favicon.ico";
            int score = -1;
            var page = yield fetch (site, out where);
            if (page != null) icon = best_icon (((string) page.get_data ()).substring (0, (long) page.get_size ()), out score);
            Bytes? image = null;
            if (score < 64) image = yield image_at (Uri.resolve_relative (where, "/apple-touch-icon.png", UriFlags.NONE));
            if (image == null) image = yield image_at (Uri.resolve_relative (where, icon, UriFlags.NONE));
            if (image == null && icon != "/favicon.ico") image = yield image_at (Uri.resolve_relative (where, "/favicon.ico", UriFlags.NONE));
            return image;
        } catch (Error e) {
            return null;
        }
    }

    // The best icon a page declares: an apple-touch-icon if it has one (large, and drawn to stand on its
    // own), otherwise its largest rel=icon, otherwise the conventional /favicon.ico. `best_score` is
    // roughly its declared size in pixels (1000 and up for a touch icon, -1 if the page declares none).
    static string best_icon (string html, out int best_score) {
        string best = "/favicon.ico";
        best_score = -1;
        try {
            // RAW: pages are not always the UTF-8 they claim to be.
            var link = new Regex ("<link\\b[^>]*>", RegexCompileFlags.CASELESS | RegexCompileFlags.RAW);
            var rel = new Regex ("\\brel\\s*=\\s*[\"']?([^\"'>]+)", RegexCompileFlags.CASELESS | RegexCompileFlags.RAW);
            var href = new Regex ("\\bhref\\s*=\\s*[\"']?([^\"'\\s>]+)", RegexCompileFlags.CASELESS | RegexCompileFlags.RAW);
            var sizes = new Regex ("\\bsizes\\s*=\\s*[\"']?(\\d+)", RegexCompileFlags.CASELESS | RegexCompileFlags.RAW);
            MatchInfo tag, r, h, n;
            for (link.match (html, 0, out tag); tag.matches (); tag.next ()) {
                var text = tag.fetch (0);
                if (!rel.match (text, 0, out r)) continue;
                if (!href.match (text, 0, out h)) continue;
                var kind = r.fetch (1).down ();
                if (!kind.contains ("icon") || kind.contains ("mask")) continue;
                int score = kind.contains ("apple-touch") ? 1000 : 0;
                if (sizes.match (text, 0, out n)) score += int.parse (n.fetch (1));
                if (h.fetch (1).down ().contains (".svg")) score -= 2000;   // only if nothing else: not every system can draw one
                if (score > best_score) {
                    best_score = score;
                    best = h.fetch (1).replace ("&amp;", "&");
                }
            }
        } catch (Error e) {}
        return best;
    }

    // The body of a page that answered 200, and where it ended up after redirects; null otherwise.
    async Bytes? fetch (string url, out string where) throws Error {
        where = url;
        var msg = new Soup.Message ("GET", url);
        if (msg == null) return null;   // not a URL
        var body = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
        where = msg.uri.to_string ();
        return msg.status_code == 200 && body.get_size () > 0 ? body : null;
    }

    // An image file's bytes, or null if there is no such thing there (or it is implausibly big for a logo).
    async Bytes? image_at (string url) throws Error {
        string where;
        var body = yield fetch (url, out where);
        return body != null && body.get_size () < 2 * 1024 * 1024 ? body : null;
    }

    // Give each hit priced in another currency the rate into `into`, so the list can show both.
    // Rates are asked for once per currency per session: a search result needs them no fresher.
    async void rate_hits (Hit[] hits, string into) {
        string[] wanted = {};
        foreach (var hit in hits) {
            foreach (var currency in new string[] { hit.currency, into })
                if (currency != "" && currency != "USD" && currency == currency.up () && !per_usd.contains (currency)) {
                    per_usd[currency] = double.NAN;   // asked for; also keeps it out of this list twice
                    wanted += "USD" + currency + "=X";
                }
        }
        var quotes = yield quote_batch (wanted, "regularMarketPrice");
        for (uint i = 0; quotes != null && i < quotes.get_length (); i++) {
            var o = quotes.get_object_element (i);
            var pair = o.get_string_member_with_default ("symbol", "");
            if (pair.length == 8) per_usd[pair[3:6]] = o.get_double_member_with_default ("regularMarketPrice", double.NAN);
        }
        per_usd["USD"] = 1;
        foreach (var hit in hits) {
            if (hit.currency == into || !per_usd.contains (hit.currency) || !per_usd.contains (into)) continue;
            hit.rate = per_usd[into] / per_usd[hit.currency];   // NaN if either rate never arrived
        }
    }

    // ---- Yahoo ----

    async Json.Object chart (string symbol, string query) throws Error {
        var root = yield get_json (@"$YAHOO/v8/finance/chart/$(Uri.escape_string (symbol, "="))?$query");
        var chart = root.has_member ("chart") ? root.get_object_member ("chart") : null;
        if (chart == null) throw new IOError.FAILED ("unexpected answer from Yahoo");
        if (chart.has_member ("error") && !chart.get_null_member ("error"))
            throw new IOError.FAILED ("%s", chart.get_object_member ("error").get_string_member_with_default ("description", "unknown symbol"));
        return chart.get_array_member ("result").get_object_element (0);
    }

    static Series closes (Json.Object result) {
        if (!result.has_member ("timestamp")) return new Series ();   // nothing traded in the window
        return series (result.get_array_member ("timestamp"),
                       result.get_object_member ("indicators").get_array_member ("quote").get_object_element (0).get_array_member ("close"), 1);
    }

    // Prices are split-adjusted; dividends are not included.
    async Quote fetch_yahoo (string symbol) throws Error {
        var now = get_real_time () / 1000000;
        // Everything, by dates: range=max silently returns 3-month bars instead. 36,000 days because
        // Yahoo refuses more than 100 years of daily bars for some symbols (^VNINDEX.VN).
        int64 from = now - 36000 * (int64) 86400;
        var result = yield chart (symbol, @"period1=$from&period2=$now&interval=1d");
        var meta = result.get_object_member ("meta");
        var q = new Quote () {
            symbol = symbol,
            currency = meta.get_string_member_with_default ("currency", ""),
            kind = meta.get_string_member_with_default ("instrumentType", ""),
            gmtoffset = (int) meta.get_int_member_with_default ("gmtoffset", 0),
            daily = closes (result)
        };
        q.name = meta.get_string_member_with_default ("longName", meta.get_string_member_with_default ("shortName", symbol));
        q.daily = yield with_past (symbol, q.daily, from, q.gmtoffset);
        if (q.daily.n == 0) throw new IOError.FAILED ("no price history");
        q.hourly = yield hours (symbol, now - 365 * 86400);
        apply (q, yield chart (symbol, @"period1=$(bars_from (q, now))&period2=$now&interval=5m"), now);
        return q;
    }

    // Some indices Yahoo carries with no past at all, only today's level: ^SPXXAI, which S&P launched
    // in 2026, has a single daily bar there. CNBC has such an index's closes (that one's back to 2000,
    // back-tested), so when Yahoo comes up with one bar or none, the days before it are CNBC's.
    // Nothing else is asked of CNBC. Its US prices match Yahoo's, but it has no Vietnam, quotes Asia
    // late, and its bars come one symbol to a request.
    // ponytail: indices only (^X is .X there). A share would need CNBC's naming for its market
    // (7203.T-JP, 700-HK); none has turned up that Yahoo lacks the history of.
    async Series with_past (string symbol, Series daily, int64 from, int gmtoffset) {
        if (daily.n > 1 || !symbol.has_prefix ("^")) return daily;
        var all = new Series ();
        try {
            // Asked for bars from before 1970, CNBC dates every one of them a day early.
            var since = new DateTime.from_unix_utc (int64.max (from, 86400)).format ("%Y%m%d000000");
            var until = new DateTime.now_utc ().add_days (1).format ("%Y%m%d000000");
            var root = yield get_json (@"$CNBC_BARS/.$(Uri.escape_string (symbol.substring (1)))/1D/$since/$until/adjusted/EST5EDT.json");
            var data = root.has_member ("barData") && !root.get_null_member ("barData") ? root.get_object_member ("barData") : null;
            var bars = data != null && data.has_member ("priceBars") && !data.get_null_member ("priceBars") ? data.get_array_member ("priceBars") : null;
            int64 first = daily.n > 0 ? (daily.t[0] + gmtoffset) / 86400 : int64.MAX;   // Yahoo's own bars start here
            for (uint i = 0; bars != null && i < bars.get_length (); i++) {
                var bar = bars.get_object_element (i);
                var day = bar.get_string_member_with_default ("tradeTime", "");   // "20260220000000"
                double close = double.parse (bar.get_string_member_with_default ("close", ""));
                if (day.length < 8 || close <= 0) continue;
                // CNBC dates its bars where Yahoo times them: call it noon on the exchange's clock.
                int64 t = new DateTime.utc (int.parse (day.substring (0, 4)), int.parse (day.substring (4, 2)), int.parse (day.substring (6, 2)), 12, 0, 0).to_unix () - gmtoffset;
                if ((t + gmtoffset) / 86400 < first) all.add (t, close);
            }
        } catch (Error e) {}   // no help from CNBC: what Yahoo has will have to do
        for (int i = 0; i < daily.n; i++) all.add (daily.t[i], daily.v[i]);
        return all;
    }

    // Take a quote's price, session hours and newest 5-minute bars from a chart of it.
    static void apply (Quote q, Json.Object result, int64 now) {
        var meta = result.get_object_member ("meta");
        q.intra.merge (closes (result));   // nothing new while the market is shut
        q.extended = meta.get_boolean_member_with_default ("hasPrePostMarketData", false);
        if (meta.has_member ("currentTradingPeriod") && meta.get_object_member ("currentTradingPeriod").has_member ("regular")) {
            var session = meta.get_object_member ("currentTradingPeriod").get_object_member ("regular");
            q.opens = session.get_int_member_with_default ("start", 0);
            q.closes = session.get_int_member_with_default ("end", 0);
        }
        // Bars are exact; the meta price is rounded to a few decimals, which turns VNDUSD=X into 0.0.
        double price = q.intra.n > 0 ? q.intra.v[q.intra.n - 1] : meta.get_double_member_with_default ("regularMarketPrice", q.daily.v[q.daily.n - 1]);
        q.tick (price, meta.get_int_member_with_default ("regularMarketTime", now));
        q.prev_close = price / (1 + meta.get_double_member_with_default ("regularMarketChangePercent", double.NAN) / 100);
    }

    // ---- Vietnam (SSI) ----

    // PVS.VN is PVS to SSI, and the index ^VN30.VN is VN30.
    static string ssi_code (string symbol) { return symbol[(symbol.has_prefix ("^") ? 1 : 0):symbol.length - 3]; }

    // Closes for a .VN symbol. SSI quotes shares in thousands of dong (indices in plain points), and
    // adjusts history for dividends as well as splits, so (unlike Yahoo's) these series are total-return.
    async Series ssi_bars (string symbol, string resolution, int64 from) throws Error {
        var now = get_real_time () / 1000000;
        var root = yield get_json (@"$SSI_BARS?resolution=$resolution&symbol=$(Uri.escape_string (ssi_code (symbol)))&from=$from&to=$now");
        var data = root.has_member ("data") && !root.get_null_member ("data") ? root.get_object_member ("data") : null;
        if (data == null || !data.has_member ("t") || !data.has_member ("c")) return new Series ();
        return series (data.get_array_member ("t"), data.get_array_member ("c"), symbol.has_prefix ("^") ? 1 : 1000);
    }

    // Name and board of a ticker, or null if SSI doesn't list it (or can't be reached).
    async Json.Object? ssi_info (string code) {
        try {
            var root = yield get_json (@"$SSI_INFO/$(Uri.escape_string (code))");
            return root.has_member ("data") && !root.get_null_member ("data") ? root.get_object_member ("data") : null;
        } catch (Error e) {
            return null;
        }
    }

    async Quote fetch_ssi (string symbol) throws Error {
        var code = ssi_code (symbol);
        bool index = symbol.has_prefix ("^");
        var q = new Quote () { symbol = symbol, name = code, currency = "VND", kind = index ? "INDEX" : "EQUITY", gmtoffset = 7 * 3600 };
        q.daily = yield ssi_bars (symbol, "1D", 0);
        if (q.daily.n == 0) throw new IOError.FAILED ("no data found on Vietnam's exchanges");   // unknown tickers come back empty
        Json.Object? info = null;
        if (!index) info = yield ssi_info (code);
        if (info != null) {
            q.name = info.get_string_member_with_default ("companyNameEn", code);
            q.kind = info.get_string_member_with_default ("stockType", "s") == "e" ? "ETF" : "EQUITY";
        }
        q.hourly = yield hours (symbol, get_real_time () / 1000000 - 365 * 86400);
        yield refresh_ssi (q);
        return q;
    }

    // prev_close stays NaN: the daily series' previous bar is already the day's reference price.
    async void refresh_ssi (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        var bars = yield ssi_bars (q.symbol, "5", bars_from (q, now));
        q.intra.merge (bars);
        if (q.intra.n > 0) q.tick (q.intra.v[q.intra.n - 1], q.intra.t[q.intra.n - 1]);
        else q.price = q.daily.v[q.daily.n - 1];
        // SSI doesn't say when the market is open. Vietnam trades 09:00 to 15:00 on weekdays; on a
        // holiday that just means a few refreshes that come back empty.
        int64 local = now + q.gmtoffset, midnight = now - local % 86400;
        if (new DateTime.from_unix_utc (local).get_day_of_week () <= 5) {
            q.opens = midnight + 9 * 3600;
            q.closes = midnight + 15 * 3600;
        }
    }
}

}
