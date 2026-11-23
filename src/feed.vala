// Where prices come from. Two sources, both keyless and unofficial, so either can change or throttle:
//
//   Yahoo Finance   everything but Vietnam. These are the chart and search endpoints finance.yahoo.com
//                   itself calls; Yahoo retired its official API in 2017 and there is no key to get.
//   SSI iBoard      every .VN symbol, indices included (^VNINDEX.VN, ^VN30.VN, ^HNXINDEX.VN: Yahoo has
//                   one day of history for them). Yahoo lists Ho Chi Minh (HOSE) only; this broker's web
//                   terminal also has Hanoi (HNX) and UPCoM, with history back to 2006.
//                   Drop-in alternatives that returned identical bars when this was written:
//                   services.entrade.com.vn/chart-api/v2/ohlcs/stock and dchart-api.vndirect.com.vn/dchart/history.
//
// Search also reads Nasdaq Trader's public symbol directory, for the full names of US securities.
namespace Stonks {

// A search result.
public class Hit {
    public string symbol;
    public string name = "";     // as full as we can get it: "Alphabet Inc. - Class C Capital Stock"
    public string detail = "";   // exchange, type, sector, industry
    public string currency = "";
    public double price = double.NAN;   // NaN where the source has none
    public double cap = double.NAN;     // market capitalisation, in `currency`
}

public class Feed {
    const string YAHOO = "https://query1.finance.yahoo.com";
    const string SSI_BARS = "https://iboard-api.ssi.com.vn/statistics/charts/history";
    const string SSI_INFO = "https://iboard-query.ssi.com.vn/stock";
    // Yahoo answers 429 to user agents that don't look like a browser.
    Soup.Session session = new Soup.Session () { user_agent = "Mozilla/5.0 (X11; Linux x86_64)", timeout = 30 };
    HashTable<string, string>? names;   // US symbol -> full security name, once load_names() has run
    string? crumb;                      // see price_hits()

    public Feed () {
        session.add_feature (new Soup.CookieJar ());   // for the cookie price_hits() needs
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

    // A symbol's whole daily history, then its latest bars.
    public async Quote fetch (string symbol) throws Error {
        return from_ssi (symbol) ? yield fetch_ssi (symbol) : yield fetch_yahoo (symbol);
    }

    // Latest price and the last week of 5-minute bars.
    public async void refresh (Quote q) throws Error {
        if (from_ssi (q.symbol)) yield refresh_ssi (q); else yield refresh_yahoo (q);
    }

    // Full names of US-listed securities, from Nasdaq Trader's symbol directory. Yahoo calls every share
    // class of a company the same thing ("Alphabet Inc." for GOOG, GOOGL, GOOGM and GOOGN alike); these
    // say which is which. Two small files, fetched once (the window asks at startup).
    public async void load_names () {
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
        if (found.size () > 0) names = found;   // else offline: try again next time
    }

    // The exact ticker in Vietnam if there is one (on any of its three boards), then up to five Yahoo
    // matches by name or ticker.
    // ponytail: Vietnamese companies are found by ticker only; searching them by name needs a symbol
    // list (trading.vietcap.com.vn/api/price/symbols/getAll has one) filtered here.
    public async Hit[] search (string text) {
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
        var code = text.up ();
        if (code.has_suffix (".VN")) code = code[0:code.length - 3];
        bool plausible = code.length >= 3 && code.length <= 8;
        for (int i = 0; i < code.length; i++) plausible &= code[i].isalnum ();
        if (plausible) {
            var info = yield ssi_info (code);
            bool index = code == "VNINDEX" || code == "VN30" || code == "HNXINDEX";
            if (info != null || index) {
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
                hits += hit;
            }
        }
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
    async void price_hits (Hit[] hits) {
        string[] symbols = {};
        foreach (var hit in hits) if (!hit.price.is_finite ()) symbols += hit.symbol;
        if (symbols.length == 0) return;
        try {
            if (crumb == null) {
                yield session.send_and_read_async (new Soup.Message ("GET", "https://fc.yahoo.com"), Priority.DEFAULT, null);   // a 404 that sets the cookie
                var reply = yield session.send_and_read_async (new Soup.Message ("GET", "https://query2.finance.yahoo.com/v1/test/getcrumb"), Priority.DEFAULT, null);
                crumb = reply.get_size () > 0 ? ((string) reply.get_data ()).substring (0, (long) reply.get_size ()) : "";
            }
            var root = yield get_json (@"$YAHOO/v7/finance/quote?fields=regularMarketPrice,currency,marketCap,longName,shortName,fullExchangeName,typeDisp&crumb=$(Uri.escape_string (crumb))&symbols=$(Uri.escape_string (string.joinv (",", symbols), ",="))");
            if (!root.has_member ("quoteResponse")) {
                crumb = null;   // refused: the crumb went stale, so get a new one next time
                return;
            }
            var quotes = root.get_object_member ("quoteResponse").get_array_member ("result");
            for (uint i = 0; i < quotes.get_length (); i++) {
                var o = quotes.get_object_element (i);
                foreach (var hit in hits) {
                    if (hit.symbol != o.get_string_member_with_default ("symbol", "")) continue;
                    hit.currency = o.get_string_member_with_default ("currency", "");
                    hit.price = o.get_double_member_with_default ("regularMarketPrice", double.NAN);
                    hit.cap = o.get_double_member_with_default ("marketCap", double.NAN);   // funds and warrants have none
                    if (hit.name == "") {   // a pair we guessed the symbol of, rather than a search result
                        hit.name = o.get_string_member_with_default ("longName", o.get_string_member_with_default ("shortName", hit.symbol));
                        hit.detail = "%s · %s".printf (o.get_string_member_with_default ("fullExchangeName", ""), o.get_string_member_with_default ("typeDisp", ""));
                    }
                }
            }
        } catch (Error e) {
            crumb = null;
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
        var result = yield chart (symbol, @"period1=$(now - 36000 * (int64) 86400)&period2=$now&interval=1d");
        var meta = result.get_object_member ("meta");
        var q = new Quote () {
            symbol = symbol,
            currency = meta.get_string_member_with_default ("currency", ""),
            kind = meta.get_string_member_with_default ("instrumentType", ""),
            gmtoffset = (int) meta.get_int_member_with_default ("gmtoffset", 0),
            daily = closes (result)
        };
        q.name = meta.get_string_member_with_default ("longName", meta.get_string_member_with_default ("shortName", symbol));
        if (q.daily.n == 0) throw new IOError.FAILED ("no price history");
        yield refresh_yahoo (q);
        return q;
    }

    async void refresh_yahoo (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        var result = yield chart (q.symbol, @"period1=$(now - 7 * 86400)&period2=$now&interval=5m");
        var meta = result.get_object_member ("meta");
        q.intra = closes (result);
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
        yield refresh_ssi (q);
        return q;
    }

    // prev_close stays NaN: the daily series' previous bar is already the day's reference price.
    async void refresh_ssi (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        q.intra = yield ssi_bars (q.symbol, "5", now - 7 * 86400);
        if (q.intra.n > 0) q.tick (q.intra.v[q.intra.n - 1], q.intra.t[q.intra.n - 1]);
        else q.price = q.daily.v[q.daily.n - 1];
    }
}

}
