// Where prices come from. Two sources, both keyless and unofficial, so either can change or throttle:
//
//   Yahoo Finance   everything but Vietnam. These are the chart and search endpoints finance.yahoo.com
//                   itself calls; Yahoo retired its official API in 2017 and there is no key to get.
//   SSI iBoard      every .VN symbol. Yahoo lists Ho Chi Minh (HOSE) only; this Vietnamese broker's web
//                   terminal also has Hanoi (HNX) and UPCoM, with history back to 2006.
//                   Drop-in alternatives that returned identical bars when this was written:
//                   services.entrade.com.vn/chart-api/v2/ohlcs/stock and dchart-api.vndirect.com.vn/dchart/history.
namespace Stonks {

public class Hit {
    public string symbol;
    public string detail;
}

public class Feed {
    const string YAHOO = "https://query1.finance.yahoo.com";
    const string SSI_BARS = "https://iboard-api.ssi.com.vn/statistics/charts/history";
    const string SSI_INFO = "https://iboard-query.ssi.com.vn/stock";
    // Yahoo answers 429 to user agents that don't look like a browser.
    Soup.Session session = new Soup.Session () { user_agent = "Mozilla/5.0 (X11; Linux x86_64)", timeout = 30 };

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

    // A symbol's whole daily history, then its latest bars.
    public async Quote fetch (string symbol) throws Error {
        return symbol.has_suffix (".VN") ? yield fetch_ssi (symbol) : yield fetch_yahoo (symbol);
    }

    // Latest price and the last week of 5-minute bars.
    public async void refresh (Quote q) throws Error {
        if (q.symbol.has_suffix (".VN")) yield refresh_ssi (q); else yield refresh_yahoo (q);
    }

    // The exact ticker in Vietnam if there is one (on any of its three boards), then up to five Yahoo
    // matches by name or ticker.
    // ponytail: Vietnamese companies are found by ticker only; searching them by name needs a symbol
    // list (trading.vietcap.com.vn/api/price/symbols/getAll has one) filtered here.
    public async Hit[] search (string text) {
        Hit[] hits = {};
        var code = text.up ();
        if (code.has_suffix (".VN")) code = code[0:code.length - 3];
        bool plausible = code.length >= 3 && code.length <= 8;
        for (int i = 0; i < code.length; i++) plausible &= code[i].isalnum ();
        if (plausible) {
            var info = yield ssi_info (code);
            if (info != null) hits += new Hit () {
                symbol = code + ".VN",
                detail = "%s · %s · Vietnam".printf (info.get_string_member_with_default ("companyNameEn", code), info.get_string_member_with_default ("exchange", "").up ())
            };
        }
        try {
            var root = yield get_json (@"$YAHOO/v1/finance/search?q=$(Uri.escape_string (text))&quotesCount=5&newsCount=0");
            var quotes = root.has_member ("quotes") ? root.get_array_member ("quotes") : new Json.Array ();
            for (uint i = 0; i < quotes.get_length (); i++) {
                var o = quotes.get_object_element (i);
                if (!o.has_member ("symbol") || o.get_string_member ("symbol") == code + ".VN") continue;   // already listed above
                var name = o.get_string_member_with_default ("longname", o.get_string_member_with_default ("shortname", ""));
                hits += new Hit () {
                    symbol = o.get_string_member ("symbol"),
                    detail = "%s · %s · %s".printf (name, o.get_string_member_with_default ("exchDisp", ""), o.get_string_member_with_default ("typeDisp", ""))
                };
            }
        } catch (Error e) {}
        return hits;
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
        // period1 is 1900: asking for range=max instead silently returns 3-month bars.
        var result = yield chart (symbol, @"period1=-2208988800&period2=$now&interval=1d");
        var meta = result.get_object_member ("meta");
        var q = new Quote () {
            symbol = symbol,
            currency = meta.get_string_member_with_default ("currency", ""),
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

    // Closes for a ticker, without the .VN. SSI quotes in thousands of dong, and adjusts history for
    // dividends as well as splits, so (unlike Yahoo's) these series are total-return.
    async Series ssi_bars (string code, string resolution, int64 from) throws Error {
        var now = get_real_time () / 1000000;
        var root = yield get_json (@"$SSI_BARS?resolution=$resolution&symbol=$(Uri.escape_string (code))&from=$from&to=$now");
        var data = root.has_member ("data") && !root.get_null_member ("data") ? root.get_object_member ("data") : null;
        if (data == null || !data.has_member ("t") || !data.has_member ("c")) return new Series ();
        return series (data.get_array_member ("t"), data.get_array_member ("c"), 1000);
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
        var code = symbol[0:symbol.length - 3];
        var q = new Quote () { symbol = symbol, name = code, currency = "VND", gmtoffset = 7 * 3600 };
        q.daily = yield ssi_bars (code, "1D", 0);
        if (q.daily.n == 0) throw new IOError.FAILED ("no data found on Vietnam's exchanges");   // unknown tickers come back empty
        var info = yield ssi_info (code);
        if (info != null) q.name = info.get_string_member_with_default ("companyNameEn", code);
        yield refresh_ssi (q);
        return q;
    }

    // prev_close stays NaN: the daily series' previous bar is already the day's reference price.
    async void refresh_ssi (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        q.intra = yield ssi_bars (q.symbol[0:q.symbol.length - 3], "5", now - 7 * 86400);
        if (q.intra.n > 0) q.tick (q.intra.v[q.intra.n - 1], q.intra.t[q.intra.n - 1]);
        else q.price = q.daily.v[q.daily.n - 1];
    }
}

}
