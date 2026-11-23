// Yahoo Finance's chart and search endpoints. There is no API key: Yahoo retired its official API in
// 2017 and these are the ones finance.yahoo.com itself calls. Unofficial, so they can change or throttle.
namespace Stonks {

public class Hit {
    public string symbol;
    public string detail;
}

public class Yahoo {
    const string HOST = "https://query1.finance.yahoo.com";
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
            throw new IOError.FAILED ("Yahoo answered HTTP %u %s", msg.status_code, Soup.Status.get_phrase (msg.status_code));
        return root.get_object ();
    }

    async Json.Object chart (string symbol, string query) throws Error {
        var root = yield get_json (@"$HOST/v8/finance/chart/$(Uri.escape_string (symbol, "="))?$query");
        var chart = root.has_member ("chart") ? root.get_object_member ("chart") : null;
        if (chart == null) throw new IOError.FAILED ("unexpected answer from Yahoo");
        if (chart.has_member ("error") && !chart.get_null_member ("error"))
            throw new IOError.FAILED ("%s", chart.get_object_member ("error").get_string_member_with_default ("description", "unknown symbol"));
        return chart.get_array_member ("result").get_object_element (0);
    }

    // Closing prices of a chart result, minus the bars Yahoo leaves null (halts, holidays, lunch breaks).
    static Series closes (Json.Object result) {
        var s = new Series ();
        if (!result.has_member ("timestamp")) return s;   // nothing traded in the window
        var ts = result.get_array_member ("timestamp");
        var close = result.get_object_member ("indicators").get_array_member ("quote").get_object_element (0).get_array_member ("close");
        for (uint i = 0; i < ts.get_length (); i++)
            if (!close.get_null_element (i) && close.get_double_element (i) > 0) s.add (ts.get_int_element (i), close.get_double_element (i));
        return s;
    }

    // A symbol's whole daily history, then its latest bars. Prices are split-adjusted, dividends are not included.
    public async Quote fetch (string symbol) throws Error {
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
        yield refresh (q);
        return q;
    }

    // Latest price and the last week of 5-minute bars.
    public async void refresh (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        var result = yield chart (q.symbol, @"period1=$(now - 7 * 86400)&period2=$now&interval=5m");
        var meta = result.get_object_member ("meta");
        q.intra = closes (result);
        // Bars are exact; the meta price is rounded to a few decimals, which turns VNDUSD=X into 0.0.
        double price = q.intra.n > 0 ? q.intra.v[q.intra.n - 1] : meta.get_double_member_with_default ("regularMarketPrice", q.daily.v[q.daily.n - 1]);
        q.tick (price, meta.get_int_member_with_default ("regularMarketTime", now));
        q.prev_close = price / (1 + meta.get_double_member_with_default ("regularMarketChangePercent", double.NAN) / 100);
    }

    public async Hit[] search (string text) throws Error {
        var root = yield get_json (@"$HOST/v1/finance/search?q=$(Uri.escape_string (text))&quotesCount=5&newsCount=0");
        Hit[] hits = {};
        if (!root.has_member ("quotes")) return hits;
        var quotes = root.get_array_member ("quotes");
        for (uint i = 0; i < quotes.get_length (); i++) {
            var o = quotes.get_object_element (i);
            if (!o.has_member ("symbol")) continue;
            var name = o.get_string_member_with_default ("longname", o.get_string_member_with_default ("shortname", ""));
            hits += new Hit () {
                symbol = o.get_string_member ("symbol"),
                detail = "%s · %s · %s".printf (name, o.get_string_member_with_default ("exchDisp", ""), o.get_string_member_with_default ("typeDisp", ""))
            };
        }
        return hits;
    }
}

}
