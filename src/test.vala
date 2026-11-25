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

string order (GenericArray<Tile> tiles) {
    string names = "";
    for (int i = 0; i < tiles.length; i++) names += tiles[i].symbol + " ";
    return names;
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
    int today;
    assert (a.trail (Range.D1, NOW, out today).n == 4 && today == 0);                   // no session before it to lead in with
    a.intra = new Series ();
    // early in a session a 1D chart is led in by the session before: six bars on day 8, then day 9's
    for (int i = 0; i < 6; i++) a.intra.add (T0 + 8 * DAY + 9 * 3600 + i * 300, 107 + i * 0.1);
    assert (a.trail (Range.D1, NOW, out today).n == 1 && today == 0);                   // day 9 has no bars yet: view()'s one daily bar
    a.intra.add (T0 + 9 * DAY + 9 * 3600, 108.5);
    var led = a.trail (Range.D1, NOW, out today);
    assert (led.n == 6 && today == 5 && led.t[0] == T0 + 8 * DAY + 9 * 3600 + 300);     // five of day 8's, one of day 9's
    for (int i = 1; i < 6; i++) a.intra.add (T0 + 9 * DAY + 9 * 3600 + i * 300, 108.5 + i * 0.1);
    assert (a.trail (Range.D1, NOW, out today).n == 6 && today == 0);                   // a full session: today alone
    assert (a.trail (Range.D30, NOW, out today).n == 10 && today == 0);                 // other ranges are view()'s
    a.intra = new Series ();

    // tick: same exchange day overwrites the live bar, a new day appends one
    a.tick (109.5, NOW);
    assert (a.daily.n == 10);
    near (a.daily.v[9], 109.5);
    a.tick (111, NOW + DAY);
    assert (a.daily.n == 11);
    a = quote ("A", "USD", 100, 1);

    // hourly bars chart the ranges between a week and a year, if they cover the range
    for (int d = 6; d < 10; d++) for (int h = 9; h < 12; h++) a.hourly.add (T0 + d * DAY + h * 3600, 100 + d);
    assert (a.view (Range.D30, NOW).n == 10);                 // they start on day 6: daily closes still
    a.hourly = new Series ();
    for (int d = 0; d < 10; d++) for (int h = 9; h < 12; h++) a.hourly.add (T0 + d * DAY + h * 3600, 100 + d);
    assert (a.view (Range.D30, NOW).n == 30 && a.view (Range.D7, NOW).n == 7 && a.view (Range.MAX, NOW).n == 10);
    // ...and the 5m bars fill in since the last of them, an hour apart; the end is the price now
    a.intra.add (NOW - 600, 55);                              // within the hour of the last hourly bar: left out
    a.intra.add (NOW, 108.7);
    a.intra.add (NOW + 300, 108.8);
    a.price = 108.9;
    var fine = a.view (Range.YTD, NOW);
    assert (fine.n == 31 && fine.t[30] == NOW);
    near (fine.v[29], 109);
    near (fine.v[30], 108.9);
    a = quote ("A", "USD", 100, 1);

    // a live trade moves the price, the day's bar and the 5-minute bar it falls in
    a.trade (110, NOW);
    a.trade (111, NOW + 60);
    assert (a.intra.n == 1 && a.intra.t[0] == NOW - NOW % 300 && a.daily.n == 10);
    a.trade (112, NOW + 400);
    assert (a.intra.n == 2);
    near (a.intra.v[0], 111);
    near (a.daily.v[9], 112);
    a = quote ("A", "USD", 100, 1);

    // --- a point in the past: the day's bar, the year up to it, the latest period reported ---
    var past = new Past ();
    for (int d = 0; d < 10; d++) {
        int64 t = T0 + d * DAY + 9 * 3600;
        past.open.add (t, 100 + d);
        past.high.add (t, 102 + d);
        past.low.add (t, 99 + d);
        past.close.add (t, 101 + d);
        past.volume.add (t, 1000 * (d + 1));
    }
    past.dividends.put (T0 + 8 * DAY, 0.7);
    past.dividends.put (T0 + 2 * DAY, 0.5);                    // out of order: put() files it where it belongs
    past.dividends.put (T0 + 2 * DAY, 0.5);                    // ...once
    assert (past.dividends.n == 2 && past.dividends.t[0] == T0 + 2 * DAY);
    past.eps.put (T0 + 6 * DAY, 5);
    past.eps.put (T0 + DAY, 4);
    past.shares.put (T0 + DAY, 1e6);
    var then = past.at (T0 + 7 * DAY + 10 * 3600, 108, 0);
    near (then.open, 107);
    near (then.high, 109);
    near (then.low, 106);
    near (then.volume, 8000);
    near (then.prev_close, 107);
    near (then.high52, 109);                                   // the highest high and lowest low of days 0..7
    near (then.low52, 99);
    near (then.avg_volume, 4500);
    near (then.dividend_rate, 0.5);                            // day 8's wasn't paid yet
    near (then.dividend_yield, 0.5 / 108 * 100);
    near (then.eps, 5);
    near (then.pe, 21.6);
    near (then.cap, 108e6);
    then = past.at (T0 + 12 * DAY, 120, 0);                    // a day with no bar: no day's figures, the year's still
    assert (!then.open.is_finite () && !then.volume.is_finite ());
    near (then.high52, 111);
    near (then.dividend_rate, 1.2);
    then = past.at (T0 + 10 * 3600, 100, 0);                   // before anything was reported
    assert (!then.pe.is_finite () && !then.cap.is_finite () && !then.dividend_rate.is_finite ());
    near (then.open, 100);
    assert (!past.at (T0 - DAY, 100, 0).high52.is_finite ());  // before the records begin
    then = past.at (T0 + 600 * DAY, 100, 0);                   // long after the last report: it no longer stands
    assert (!then.eps.is_finite () && !then.cap.is_finite ());

    // --- a price off Yahoo's stream, as it arrived ---
    var trade = Trade.decode (Base64.decode ("CgdCVEMtVVNEFWFyakcYgNixzMJoIgNVU0QqA0NDQzApOAFFWxVfPkiAgIWrpwJVsN1rR10vzl9HZQB4AkN9p2FpR7ABgICFq6cC2AEE4AGAgIWrpwLoAYCAhaunAvIBA0JUQ4ECAAAAQHgvc0GJAgAAuqB+knFC9QIAeAJD/QJbFV8+"));
    assert (trade.symbol == "BTC-USD" && trade.time == 1795644864 && trade.session == 1);
    near (trade.price, 60018.37890625);
    near (trade.change, 0.21785490214824677);
    assert (Trade.decode ({ 0x0a, 0x7f, 0x41 }).symbol == "");   // cut short: nothing read past the end

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

    // --- folders ---
    // p holds A (1635) and J (20) and watches W. File A and J under Tech; watch an index too.
    var tech = p.add_group ("Tech", p.root);
    p.assign ("A", tech.id);
    p.assign ("J", tech.id);
    assert (((Lot) p.lots.get_item (1)).group == tech.id);     // both lots of A moved
    var index = quote ("^X", "USD", 5000, 10);
    index.kind = "INDEX";
    p.quotes["^X"] = index;
    p.lots.append (new Lot () { symbol = "^X" });
    p.rebase ();
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    // Tech with A and J in it; then what is in no folder, W and the index, as tiles of their own
    assert (order (tiles) == "Tech A J W ^X ");
    assert (tiles[0].kind == TileKind.GROUP && tiles[1].kind == TileKind.STOCK && tiles[4].kind == TileKind.BENCHMARK);
    assert (tiles[0].folder == tech && tiles[1].folder == tech && tiles[3].folder == p.root && tiles[0].count == 2);
    near (tiles[0].w * tiles[0].h, 400 * 300 * 1655 / (1655 + 2 * 827.5));        // a folder is as big as its stocks
    near (tiles[0].change, (1635 * (109.0 / 108 - 1) + 20 * 0) / 1655);           // and moves as their weighted average
    near (tiles[1].y, tiles[0].y + Portfolio.GROUP_HEADER);                       // stocks start below its label
    near (tiles[1].x, tiles[0].x + Portfolio.GROUP_BORDER);                       // and inside its frame
    near (tiles[1].w * tiles[1].h + tiles[2].w * tiles[2].h,
          (tiles[0].w - 2 * Portfolio.GROUP_BORDER) * (tiles[0].h - Portfolio.GROUP_HEADER - Portfolio.GROUP_BORDER));
    p.gain (Range.MAX, NOW, out gain, out capital);
    near (capital, 10 * 90 + 5 * 104 + 10);                                       // none of this touches the totals

    // a strip pinned along the top: one tile high, the full width, its stocks side by side and equal
    var top = p.add_group ("Top", p.root);
    top.arrange = Arrange.ROW;
    p.dock_group (top, Dock.TOP);
    p.assign ("^X", top.id);
    p.assign ("W", top.id);
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (order (tiles) == "Top W ^X Tech A J ");                               // pinned first, whatever the folders' order
    near (tiles[0].w, 400);
    near (tiles[0].h, Portfolio.STRIP_HEIGHT + Portfolio.GROUP_HEADER + Portfolio.GROUP_BORDER);
    near (tiles[1].w, (400 - 2 * Portfolio.GROUP_BORDER) / 2);
    near (tiles[1].w, tiles[2].w);
    near (tiles[2].x, tiles[1].x + tiles[1].w);
    near (tiles[1].h, Portfolio.STRIP_HEIGHT);
    near (tiles[3].y, tiles[0].h);                                                // the rest starts below it
    near (tiles[3].h, 300 - tiles[0].h);
    // dragged to a size: that share of the height. Pinned to a side, the strip turns to run down it.
    top.size = 0.5;
    near (p.tiles (Range.D1, NOW, 400, 300)[0].h, 150);
    p.dock_group (top, Dock.RIGHT);
    assert (top.arrange == Arrange.COLUMN && top.size == 0);
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    near (tiles[0].x + tiles[0].w, 400);
    near (tiles[0].w, 400 / 3.0);                                                 // no more than a third unless the user says so
    near (tiles[2].y, tiles[1].y + tiles[1].h);
    near (tiles[3].w, 400 - tiles[0].w);
    // nothing else on the map: the pinned folder has it all
    p.assign ("A", top.id);
    p.assign ("J", top.id);
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (order (tiles) == "Top A J W ^X ");
    near (tiles[0].w, 400);
    p.assign ("A", tech.id);
    p.assign ("J", tech.id);

    // a strip that scrolls keeps its tiles readable and runs on past its end
    p.dock_group (top, Dock.TOP);
    top.scroll = true;
    tiles = p.tiles (Range.D1, NOW, 150, 300);
    near (tiles[1].w, Portfolio.SCROLL_WIDTH);
    near (top.overflow, 2 * Portfolio.SCROLL_WIDTH - (150 - 2 * Portfolio.GROUP_BORDER));
    assert (tiles[1].covers (10, 40) && !tiles[2].covers (149, 40));              // the frame's edge cuts the second one off
    top.offset = 1000;
    tiles = p.tiles (Range.D1, NOW, 150, 300);
    near (top.offset, top.overflow);                                              // no further than its end
    near (tiles[2].x + tiles[2].w, 150 - Portfolio.GROUP_BORDER);
    assert (!tiles[1].covers (1, 40));
    top.scroll = false;
    near (p.tiles (Range.D1, NOW, 150, 300)[1].w, (150 - 2 * Portfolio.GROUP_BORDER) / 2);

    // folders in folders: AI inside Tech takes J with it; Tech arranges AI and its own A
    var ai = p.add_group ("AI", tech);
    p.assign ("J", ai.id);
    p.dock_group (top, Dock.FLOW);
    p.root.arrange = Arrange.COLUMN;
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    assert (order (tiles) == "Tech AI J A Top W ^X ");
    assert (tiles[0].count == 2 && tiles[1].folder == ai && ai.within (tech) && !tech.within (ai));
    near (tiles[0].h, 300 * 2 / 3.0);                                             // down a column: Tech is two stocks long,
    near (tiles[4].h, 300 / 3.0);                                                 // a strip lying across it one
    near (tiles[1].x, tiles[0].x + Portfolio.GROUP_BORDER);
    p.move_group (tech, ai);                                                       // not into itself
    assert (tech.parent == p.root && p.folders ().length == 3);
    p.move_group (top, p.root, tech, false);                                       // before Tech
    assert (p.root.children[0] == top);
    p.move_group (top, tech, ai, true);                                            // into Tech, after AI
    assert (top.parent == tech && tech.children[1] == top && p.root.children.length == 1);
    p.move_group (top, p.root);
    assert (p.folder (ai.id) == ai && p.folder ("gone") == p.root);

    // a grid: equal cells, the last row stretched; Fibonacci: half, then half of the rest
    p.root.arrange = Arrange.VALUE;
    for (int i = 0; i < 5; i++) {
        p.quotes[@"G$i"] = quote (@"G$i", "USD", 10, 1);
        p.lots.append (new Lot () { symbol = @"G$i", group = top.id });
    }
    top.arrange = Arrange.GRID;
    p.dock_group (top, Dock.BOTTOM);
    top.size = 0.5;
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    int g0 = 0;
    while (tiles[g0].symbol != "Top") g0++;
    assert (tiles[g0].count == 7 && tiles[g0 + 1].symbol == "W");
    near (tiles[g0 + 1].w, tiles[g0 + 2].w);
    near (tiles[g0 + 1].h, tiles[g0 + 7].h);
    assert (tiles[g0 + 7].w > tiles[g0 + 1].w);                                   // 7 in rows of 3 or 4: the last one is short
    top.arrange = Arrange.FIBONACCI;
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    double inner = (400 - 2 * Portfolio.GROUP_BORDER) * (150 - Portfolio.GROUP_HEADER - Portfolio.GROUP_BORDER);
    near (tiles[g0 + 1].w * tiles[g0 + 1].h, inner / 2);
    near (tiles[g0 + 2].w * tiles[g0 + 2].h, inner / 4);
    near (tiles[g0 + 7].w * tiles[g0 + 7].h, tiles[g0 + 6].w * tiles[g0 + 6].h);  // the last takes what is left
    area = 0;
    for (int i = g0 + 1; i <= g0 + 7; i++) area += tiles[i].w * tiles[i].h;
    near (area, inner);
    for (int i = 0; i < 5; i++) p.lots.remove (p.lots.get_n_items () - 1);

    // a held index fund is a position like any other, and labelled like one
    ((Lot) p.lots.get_item (4)).shares = 1;
    ((Lot) p.lots.get_item (4)).price = 5000;
    p.rebase ();
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    for (int i = 0; i < tiles.length; i++) assert (tiles[i].kind != TileKind.BENCHMARK);

    // deleting a folder moves what was in it up a level; with no folders the map is flat again
    p.remove_group (tech);
    assert (ai.parent == p.root && p.root.children[0] == ai && ((Lot) p.lots.get_item (0)).group == "");
    p.remove_group (ai);
    p.remove_group (top);
    assert (p.root.children.length == 0 && ((Lot) p.lots.get_item (2)).group == "");
    tiles = p.tiles (Range.D1, NOW, 400, 300);
    for (int i = 0; i < tiles.length; i++) assert (tiles[i].kind == TileKind.STOCK);

    // --- arranging by hand: the order of the list is the order of the map ---
    // p lists A (two lots), J, W and ^X, in no folder.
    p.move ("W", "A", false);
    assert (order (p.tiles (Range.D1, NOW, 400, 300)) == "W A J ^X ");
    p.move ("A", "^X", true);                                                         // both lots of A go, and stay together
    string listed = "";
    for (uint i = 0; i < p.lots.get_n_items (); i++) listed += ((Lot) p.lots.get_item (i)).symbol + " ";
    assert (listed == "W J ^X A A ");
    near (((Lot) p.lots.get_item (3)).shares, 10);                                      // in the order they were in
    p.move ("W", "nowhere", false);                                                     // no such neighbour: the end
    assert (((Lot) p.lots.get_item (4)).symbol == "W");
    var one = p.add_group ("One", p.root);
    p.add_group ("Two", p.root);
    var three = p.add_group ("Three", p.root);
    p.move_group (three, p.root, one, false);
    assert (p.root.children[0] == three && p.root.children[1] == one);
    p.assign ("J", three.id);
    p.assign ("W", one.id);
    assert (order (p.tiles (Range.D1, NOW, 400, 300)) == "Three J One W ^X A ");        // folders in their order, empty ones absent

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
    var quit = quote ("Q", "USD", 100, 1);
    quit.daily.set_last (50);                                                           // closed mid-session: day 9 is wherever it stood
    assert (quit.daily.agrees (tail, 0));                                               // ...which is no rewritten past
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
    assert (cache.load ("C", NOW).checked == 0);                                        // no hourly bars yet: due a look
    c.hourly.add (NOW - 400 * DAY, 1);                                                  // over a year old: not kept either
    for (int i = 0; i < 5; i++) c.hourly.add (NOW - 5 * 3600 + i * 3600, 108 + i);
    cache.save (c, NOW);
    var back = cache.load ("C", NOW);
    assert (back.name == c.name && back.currency == "USD" && back.kind == "EQUITY" && back.checked == 4242);
    assert (back.daily.n == 12 && back.daily.unsaved == 12 && back.intra.n == 3 && back.hourly.n == 5 && back.hourly.unsaved == 5);
    near (back.hourly.v[4], 112);
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
