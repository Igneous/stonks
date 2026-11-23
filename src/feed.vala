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
// Search also reads Nasdaq Trader's public symbol directory, for the full names of US securities, and
// logos come from wherever logo() says.
//
// Being a polite guest of all three: everything fetched goes into the on-disk Cache, so a symbol's
// whole history is downloaded once and after that only the bars since the last ones we have; a quote
// is refreshed only when Quote.due() says its market could have moved; and the name directory is
// fetched once a week.
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

public class Feed {
    const string YAHOO = "https://query1.finance.yahoo.com";
    const string SSI_BARS = "https://iboard-api.ssi.com.vn/statistics/charts/history";
    const string SSI_INFO = "https://iboard-query.ssi.com.vn/stock";
    // Yahoo answers 429 to user agents that don't look like a browser.
    Soup.Session session = new Soup.Session () { user_agent = "Mozilla/5.0 (X11; Linux x86_64)", timeout = 30 };
    HashTable<string, string>? names;   // US symbol -> full security name, once load_names() has run
    string? crumb;                      // see quote_batch()
    HashTable<string, double?> per_usd = new HashTable<string, double?> (str_hash, str_equal);   // see rate_hits()
    HashTable<string, Found> found = new HashTable<string, Found> (str_hash, str_equal);          // see search()
    Cache cache;

    class Found {
        public Hit[] hits;
        public int64 at;
    }

    public Feed (Cache cache) {
        this.cache = cache;
        session.add_feature (new Soup.CookieJar ());   // for the cookie quote_batch() needs
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

    // A symbol from scratch: its whole daily history and the last week of 5-minute bars. The one big
    // download per symbol; afterwards it lives in the cache.
    public async Quote download (string symbol) throws Error {
        var now = get_real_time () / 1000000;
        Quote q;
        if (from_ssi (symbol)) q = yield fetch_ssi (symbol); else q = yield fetch_yahoo (symbol);
        q.checked = q.refreshed = now;
        cache.save (q, now);
        return q;
    }

    // Bring a quote up to date: the price, and the 5-minute bars since the last ones it has. Twice a
    // day at most it also makes sure its daily history still matches the feed's.
    public async void refresh (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        if (now - q.checked > 12 * 3600) yield catch_up (q, now);
        if (from_ssi (q.symbol)) yield refresh_ssi (q); else yield refresh_yahoo (q);
        q.refreshed = now;
        cache.save (q, now);
    }

    // Fetch the last few days of daily bars and hold them against ours. Normally they agree and any
    // new days are appended. If a split or a dividend adjustment has rewritten the past, they don't,
    // and the whole history is downloaded again.
    async void catch_up (Quote q, int64 now) throws Error {
        int64 from = q.daily.t[q.daily.n - 1] - 12 * 86400;
        Series tail;
        if (from_ssi (q.symbol)) tail = yield ssi_bars (q.symbol, "1D", from); else tail = yield daily_yahoo (q.symbol, from);
        if (q.daily.agrees (tail, q.gmtoffset)) {
            q.daily.merge (tail);
        } else {
            Quote again;
            if (from_ssi (q.symbol)) again = yield fetch_ssi (q.symbol); else again = yield fetch_yahoo (q.symbol);
            q.daily = again.daily;
            q.intra = again.intra;
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
    // ponytail: Vietnamese companies are found by ticker only; searching them by name needs a symbol
    // list (trading.vietcap.com.vn/api/price/symbols/getAll has one) filtered here.
    // Prices and market caps come in the security's own currency, with `into` as a second opinion.
    public async Hit[] search (string text, string into) {
        var now = get_real_time () / 1000000;
        var key = into + "\n" + text.down ();
        var seen = found[key];
        if (seen != null && now - seen.at < 900) return seen.hits;   // typed again within a quarter of an hour
        var hits = yield find (text);
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
        var quotes = yield quote_batch (symbols, "regularMarketPrice,currency,marketCap,longName,shortName,fullExchangeName,typeDisp");
        for (uint i = 0; quotes != null && i < quotes.get_length (); i++) {
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
    //   a Vietnamese ticker   Simplize's logo CDN, by ticker
    //   a coin                the image Yahoo's quote links to
    //   a company             the best icon its own website declares; Yahoo's profile says which site
    //   anything else         none, without asking anyone: indices, funds and pairs have no site of their own
    public async Bytes? logo (string symbol, string kind) throws Error {
        Bytes? image = null;
        if (from_ssi (symbol)) {
            if (!symbol.has_prefix ("^")) image = yield image_at (@"https://cdn.simplize.vn/simplizevn/logo/$(Uri.escape_string (ssi_code (symbol))).jpeg");
        } else if (kind == "CRYPTOCURRENCY") {
            var quotes = yield quote_batch ({ symbol }, "logoUrl");
            if (quotes == null) throw new IOError.FAILED ("Yahoo's quote can't be reached");
            if (quotes.get_length () > 0) image = yield image_at (quotes.get_object_element (0).get_string_member_with_default ("logoUrl", ""));
        } else if (kind == "EQUITY" || kind == "") {
            image = yield site_icon (symbol);
        }
        cache.save_logo (symbol, image);
        return image;
    }

    // The icon of the company's own website. Yahoo's profile names the site; the site's front page says
    // where its icons are. Two requests to the company at most, once.
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
            var page = yield fetch (site, out where);
            if (page != null) icon = best_icon (((string) page.get_data ()).substring (0, (long) page.get_size ()));
            var image = yield image_at (Uri.resolve_relative (where, icon, UriFlags.NONE));
            if (image == null && icon != "/favicon.ico") image = yield image_at (Uri.resolve_relative (where, "/favicon.ico", UriFlags.NONE));
            return image;
        } catch (Error e) {
            return null;
        }
    }

    // The best icon a page declares: an apple-touch-icon if it has one (large, and drawn to stand on its
    // own), otherwise its largest rel=icon, otherwise the conventional /favicon.ico.
    static string best_icon (string html) {
        string best = "/favicon.ico";
        int best_score = -1;
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

    async Series daily_yahoo (string symbol, int64 from) throws Error {
        var now = get_real_time () / 1000000;
        var result = yield chart (symbol, @"period1=$from&period2=$now&interval=1d");
        return closes (result);
    }

    async void refresh_yahoo (Quote q) throws Error {
        var now = get_real_time () / 1000000;
        var result = yield chart (q.symbol, @"period1=$(bars_from (q, now))&period2=$now&interval=5m");
        var meta = result.get_object_member ("meta");
        q.intra.merge (closes (result));   // nothing new while the market is shut
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
