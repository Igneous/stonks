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

    print ("ok\n");
}
