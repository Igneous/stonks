// `make check`: the portfolio math against numbers worked out by hand.
using Stonks;

const int64 DAY = 86400;
const int64 T0 = 1699920000;        // a UTC midnight
const int64 NOW = T0 + 9 * DAY + 12 * 3600;

void near (double got, double want) {
    if (Math.fabs (got - want) > 1e-9 * double.max (1, Math.fabs (want))) error ("got %.12g, want %.12g", got, want);
}

// Ten daily bars stamped 09:00 UTC on days 0..9, closing at first, first + step, ...
Quote quote (string symbol, string currency, double first, double step) {
    var q = new Quote () { symbol = symbol, currency = currency };
    for (int d = 0; d < 10; d++) q.daily.add (T0 + d * DAY + 9 * 3600, first + step * d);
    q.price = first + step * 9;
    return q;
}

Lot lot (string symbol, double shares, double price, int day) {
    return new Lot () { symbol = symbol, shares = shares, price = price, date = new DateTime.from_unix_utc (T0 + day * DAY).format ("%Y-%m-%d") };
}

void main () {
    // --- one quote: closes 100..109 ---
    var a = quote ("A", "USD", 100, 1);
    assert (a.daily.before (T0) == -1 && a.daily.before (T0 + 9 * 3600 + 1) == 0);
    near (a.daily.at (T0 - 5), 100);                          // before history: first value
    near (a.basis (Range.D1, NOW), 108);                      // previous bar
    near (a.change (Range.D1, NOW), 109.0 / 108 - 1);
    near (a.basis (Range.D7, NOW), 102);                      // last close before now - 7d (day 2.5)
    near (a.basis (Range.MAX, NOW), 100);
    assert (a.view (Range.D7, NOW).n == 7);                   // days 3..9, daily because there are no 5m bars
    assert (a.bar (T0 + 5 * DAY) == 5 && a.bar (T0 - 3 * DAY) == 0);
    a.prev_close = 107;
    near (a.basis (Range.D1, NOW), 107);                      // Yahoo's own previous close wins
    a.prev_close = double.NAN;

    // 5m bars take over for short ranges once there are some
    for (int i = 0; i < 4; i++) a.intra.add (T0 + 9 * DAY + 9 * 3600 + i * 300, 108.5 + i * 0.1);
    assert (a.view (Range.D1, NOW).n == 4 && a.view (Range.D30, NOW).n == 10);
    a.intra = new Series ();

    // tick: same exchange day overwrites the live bar, a new day appends one
    a.tick (109.5, NOW);
    assert (a.daily.n == 10);
    near (a.daily.v[9], 109.5);
    a.tick (111, NOW + DAY);
    assert (a.daily.n == 11);
    a = quote ("A", "USD", 100, 1);

    // --- portfolio in one currency ---
    var p = new Portfolio ();
    p.quotes["A"] = a;
    p.lots.append (lot ("A", 10, 90, 0));     // held all along
    p.lots.append (lot ("A", 5, 104, 5));     // bought inside the 7D range
    p.rebase ();
    double gain, capital;
    p.gain (Range.MAX, NOW, out gain, out capital);
    near (gain, 10 * (109 - 90) + 5 * (109 - 104));
    near (capital, 10 * 90 + 5 * 104);
    p.gain (Range.D7, NOW, out gain, out capital);
    near (gain, 10 * (109 - 102) + 5 * (109 - 104));          // old lot from the range start, new lot from its cost
    near (capital, 10 * 102 + 5 * 104);

    double opening;
    var h = p.history (Range.D7, NOW, out opening);
    assert (h.n == 7);
    near (opening, 10 * 102);
    near (h.v[0], 10 * 103);                                  // day 3: first lot only
    near (h.v[2], 15 * 105);                                  // day 5: second lot joins
    near (h.v[6], 15 * 109);

    // --- foreign currency: J closes at 1000 JPY throughout, the yen doubles on day 5 ---
    var j = quote ("J", "JPY", 1000, 0);
    var jpy = new Quote () { symbol = "JPYUSD=X", currency = "USD", price = 0.02 };
    for (int d = 0; d < 10; d++) jpy.daily.add (T0 + d * DAY, d < 5 ? 0.01 : 0.02);
    p.quotes["J"] = j;
    p.lots.append (lot ("J", 1, 1000, 2));
    assert (string.joinv (" ", p.wanted ()) == "A J JPYUSD=X");
    assert (p.tracks ("J") && !p.tracks ("JPYUSD=X"));
    p.rebase ();
    p.gain (Range.MAX, NOW, out gain, out capital);
    near (capital, 10 * 90 + 5 * 104);                        // J stays out of totals until its FX pair loads
    p.quotes["JPYUSD=X"] = jpy;
    p.rebase ();
    double g, k;
    assert (p.lot_gain ((Lot) p.lots.get_item (2), Range.MAX, NOW, out g, out k));
    near (k, 10);                                             // cost at the buy-date rate: 1000 * 0.01
    near (g, 10);                                             // worth 1000 * 0.02 now: all of it currency gain
    near (p.converted["J"].basis (Range.D7, NOW), 10);        // day 2 close at day 2's rate

    // a third currency goes through USD both ways
    p.currency = "VND";
    var vnd = new Quote () { symbol = "VNDUSD=X", currency = "USD", price = 0.00004 };
    for (int d = 0; d < 10; d++) vnd.daily.add (T0 + d * DAY, 0.00004);
    assert (string.joinv (" ", p.wanted ()) == "A VNDUSD=X J JPYUSD=X");
    p.quotes["VNDUSD=X"] = vnd;
    p.rebase ();
    near (p.converted["J"].price, 1000 * 0.02 / 0.00004);
    near (p.converted["A"].price, 109 / 0.00004);
    p.currency = "USD";
    p.rebase ();

    // --- treemap: tiles fill the area in proportion to value ---
    var tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (tiles.length == 2 && tiles[0].symbol == "A");
    double area = 0;
    for (int i = 0; i < tiles.length; i++) area += tiles[i].w * tiles[i].h;
    near (area, 400 * 300);
    near (tiles[1].w * tiles[1].h, 400 * 300 * 20.0 / (15 * 109 + 20));

    // --- a watched stock (no shares): on the heatmap at an average holding's size, out of every total ---
    p.quotes["W"] = quote ("W", "EUR", 50, 1);
    p.lots.append (new Lot () { symbol = "W" });
    assert (string.joinv (" ", p.wanted ()) == "A J JPYUSD=X W");   // and no EURUSD=X just to watch it
    p.rebase ();
    p.gain (Range.MAX, NOW, out gain, out capital);
    near (capital, 10 * 90 + 5 * 104 + 10);
    assert (!p.lot_gain ((Lot) p.lots.get_item (3), Range.MAX, NOW, out g, out k));
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (tiles.length == 3 && tiles[2].symbol == "W" && tiles[2].value == 0);   // in list order: A, J, W
    near (tiles[2].weight, (15 * 109 + 20) / 2.0);
    near (tiles[2].change, 59.0 / 58 - 1);
    near (tiles[2].w * tiles[2].h, 400 * 300 * 827.5 / (15 * 109 + 20 + 827.5));

    // nothing held at all: a plain watchlist gets equal tiles
    var watch = new Portfolio ();
    watch.quotes["A"] = a;
    watch.quotes["W"] = p.quotes["W"];
    watch.lots.append (new Lot () { symbol = "W" });
    watch.lots.append (new Lot () { symbol = "A" });
    watch.rebase ();
    tiles = watch.tiles (Range.D1, NOW, 400, 300);
    assert (tiles.length == 2 && tiles[0].symbol == "W");
    near (tiles[0].w * tiles[0].h, tiles[1].w * tiles[1].h);
    assert (watch.history (Range.D7, NOW, out opening).n == 0);

    // --- folders and the benchmark row ---
    // p holds A (1635) and J (20) and watches W. File A and J under Tech; watch an index too.
    p.groups.add ("Tech");
    p.assign ("A", "Tech");
    p.assign ("J", "Tech");
    assert (((Lot) p.lots.get_item (1)).group == "Tech");      // both lots of A moved
    var index = quote ("^X", "USD", 5000, 10);
    index.kind = "INDEX";
    p.quotes["^X"] = index;
    p.lots.append (new Lot () { symbol = "^X" });
    p.rebase ();
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    // the index in a row along the top; then Tech with A and J; then Ungrouped with W
    string order = "";
    for (int i = 0; i < tiles.length; i++) order += tiles[i].symbol + " ";
    assert (order == "^X Tech A J Ungrouped W ");
    assert (tiles[0].kind == TileKind.BENCHMARK && tiles[1].kind == TileKind.GROUP && tiles[2].kind == TileKind.STOCK);
    near (tiles[0].w, 400);
    near (tiles[0].h, Portfolio.BENCHMARK_ROW);
    near (tiles[1].y, Portfolio.BENCHMARK_ROW);
    double rest = 400 * (300 - Portfolio.BENCHMARK_ROW);
    near (tiles[1].w * tiles[1].h, rest * 1655 / (1655 + 827.5));                 // a folder is as big as its stocks
    near (tiles[1].change, (1635 * (109.0 / 108 - 1) + 20 * 0) / 1655);           // and moves as their weighted average
    near (tiles[2].y, tiles[1].y + Portfolio.GROUP_HEADER);                       // stocks start below its label
    near (tiles[2].x, tiles[1].x + Portfolio.GROUP_BORDER);                       // and inside its frame
    near (tiles[2].w * tiles[2].h + tiles[3].w * tiles[3].h,
          (tiles[1].w - 2 * Portfolio.GROUP_BORDER) * (tiles[1].h - Portfolio.GROUP_HEADER - Portfolio.GROUP_BORDER));
    p.gain (Range.MAX, NOW, out gain, out capital);
    near (capital, 10 * 90 + 5 * 104 + 10);                                       // none of this touches the totals

    // a held index fund is a position like any other: in the body, not the top row
    ((Lot) p.lots.get_item (4)).shares = 1;
    ((Lot) p.lots.get_item (4)).price = 5000;
    p.rebase ();
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (tiles[0].kind != TileKind.BENCHMARK);

    // deleting a folder unfiles its stocks; with no folders the map is flat again
    p.rename_group ("Tech", "");
    assert (p.groups.length == 0 && ((Lot) p.lots.get_item (0)).group == "");
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    for (int i = 0; i < tiles.length; i++) assert (tiles[i].kind == TileKind.STOCK);

    // --- arranging by hand: the order of the list is the order of the map ---
    // p lists A (two lots), J, W and ^X, all in the body by now.
    p.move ("W", "A", false);
    order = "";
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    for (int i = 0; i < tiles.length; i++) order += tiles[i].symbol + " ";
    assert (order == "W A J ^X ");
    p.move ("A", "^X", true);                                                         // both lots of A go, and stay together
    order = "";
    for (uint i = 0; i < p.lots.get_n_items (); i++) order += ((Lot) p.lots.get_item (i)).symbol + " ";
    assert (order == "W J ^X A A ");
    near (((Lot) p.lots.get_item (3)).shares, 10);                                      // in the order they were in
    p.move ("W", "nowhere", false);                                                     // no such neighbour: the end
    assert (((Lot) p.lots.get_item (4)).symbol == "W");
    foreach (var folder in new string[] { "One", "Two", "Three" }) p.groups.add (folder);
    p.move_group ("Three", "One");
    assert (p.groups[0] == "Three" && p.groups[1] == "One" && p.groups[2] == "Two");
    p.move_group ("Three", "");
    assert (p.groups[0] == "One" && p.groups[2] == "Three");
    p.assign ("J", "Three");
    p.assign ("W", "One");
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    order = "";
    for (int i = 0; i < tiles.length; i++) order += tiles[i].symbol + " ";
    assert (order == "One W Three J Ungrouped ^X A ");                                  // folders in their order, empty ones absent

    // --- keeping history between runs: merging, spotting a rewritten past, and the cache itself ---
    var c = quote ("C", "USD", 100, 1);
    var tail = new Series ();
    for (int d = 6; d < 12; d++) tail.add (T0 + d * DAY + 9 * 3600, 100 + d);        // days 6..11: four we have, two new
    assert (c.daily.agrees (tail, 0));
    var halved = new Series ();
    for (int d = 6; d < 12; d++) halved.add (T0 + d * DAY + 9 * 3600, (100 + d) / 2.0);
    assert (!c.daily.agrees (halved, 0));                                               // a split rewrote the past
    var live = new Series ();
    live.add (T0 + 8 * DAY + 9 * 3600, 108);
    live.add (T0 + 9 * DAY + 15 * 3600, 999);                                           // its last bar is live: not compared
    assert (c.daily.agrees (live, 0));
    var later = new Series ();
    for (int d = 20; d < 23; d++) later.add (T0 + d * DAY, 1);
    assert (!c.daily.agrees (later, 0));                                                // nothing in common proves nothing

    c.daily.unsaved = c.daily.n;                                                        // as if stored
    c.daily.merge (tail);
    assert (c.daily.n == 12 && c.daily.unsaved == 6);                                   // cut back to day 6, continued from there
    near (c.daily.v[11], 111);
    c.daily.unsaved = c.daily.n;
    c.tick (112, T0 + 11 * DAY + 10 * 3600);
    assert (c.daily.n == 12 && c.daily.unsaved == 11);                                  // the live bar moved: only it needs storing

    var cache = new Cache (":memory:");
    c.kind = "EQUITY";
    c.checked = 4242;
    c.intra.add (NOW - 9 * DAY, 1);                                                     // too old to be worth keeping
    for (int i = 0; i < 3; i++) c.intra.add (NOW - 900 + i * 300, 110 + i);
    c.daily.unsaved = 0;
    cache.save (c, NOW);
    assert (c.daily.unsaved == 12 && c.intra.unsaved == 4);
    assert (cache.load ("nope", NOW) == null);
    var back = cache.load ("C", NOW);
    assert (back.name == c.name && back.currency == "USD" && back.kind == "EQUITY" && back.checked == 4242);
    assert (back.daily.n == 12 && back.daily.unsaved == 12 && back.intra.n == 3);
    near (back.daily.v[11], 112);
    near (back.price, 112);
    near (back.intra.v[2], 112);
    // then the past is rewritten from day 6 on and a day is added: the stored copy follows
    var rewritten = new Series ();
    for (int d = 6; d < 13; d++) rewritten.add (T0 + d * DAY + 9 * 3600, 50 + d);
    c.daily.merge (rewritten);
    cache.save (c, NOW);
    back = cache.load ("C", NOW);
    assert (back.daily.n == 13);
    near (back.daily.v[5], 105);
    near (back.daily.v[6], 56);
    near (back.daily.v[12], 62);

    var names = new HashTable<string, string> (str_hash, str_equal);
    names["GOOG"] = "Alphabet Inc. - Class C Capital Stock";
    cache.save_names (names, NOW);
    assert (cache.load_names (NOW + DAY)["GOOG"] == "Alphabet Inc. - Class C Capital Stock");
    assert (cache.load_names (NOW + 8 * DAY) == null);                                  // a week on, they are due again

    // --- standing in for a range the feed doesn't give ---
    double lowest, highest;
    Quote.extremes (a.daily, T0 + 5 * DAY, out lowest, out highest);                    // days 5..9 close at 105..109
    near (lowest, 105);
    near (highest, 109);
    Quote.extremes (a.daily, NOW + DAY, out lowest, out highest);
    assert (!lowest.is_finite () && !highest.is_finite ());

    // --- when a quote is worth asking about again ---
    var d = quote ("D", "USD", 100, 1);
    d.opens = NOW - 3600;
    d.closes = NOW + 3600;
    d.refreshed = NOW - 120;
    assert (d.due (NOW));                                                               // in session: every time
    d.refreshed = NOW + 2 * 3600 - 120;
    assert (!d.due (NOW + 2 * 3600));                                                   // shut, asked recently enough
    d.refreshed = NOW + 2 * 3600 - 901;
    assert (d.due (NOW + 2 * 3600));                                                    // shut, but a quarter of an hour has passed
    d.opens = NOW - NOW % DAY;                                                          // a currency: "in session" all day, every day
    d.closes = d.opens + DAY - 60;
    d.refreshed = NOW - 120;
    assert (!d.due (NOW));                                                              // ...but no bars, so it isn't really trading
    d.intra.add (NOW - 300, 100);
    assert (d.due (NOW));

    print ("ok\n");
}
