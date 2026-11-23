// The two heatmaps: a treemap of holdings for one range, and a symbol x range performance grid.
namespace Stonks {

// The move at which a tile reaches full color, per range (3% in a day, 300% over a lifetime).
const double[] HEAT_FULL = { 0.03, 0.06, 0.10, 0.20, 0.30, 1.0, 3.0 };

// Set the cairo color for a change: slate at zero, shading to green or red.
void heat (Cairo.Context cr, double change, Range r) {
    double x = change.is_finite () ? (change / HEAT_FULL[r]).clamp (-1, 1) : 0, a = Math.fabs (x);
    double red = x < 0 ? 0.82 : 0.12, green = x < 0 ? 0.17 : 0.60, blue = x < 0 ? 0.20 : 0.32;
    cr.set_source_rgb (0.27 + (red - 0.27) * a, 0.29 + (green - 0.29) * a, 0.34 + (blue - 0.34) * a);
}

int64 now_s () { return get_real_time () / 1000000; }

public class Treemap : Gtk.DrawingArea {
    public Range range;
    // Something was dropped: a symbol, or "folder:" and a folder's name. `folder` is the folder it
    // landed in; `target`, if any, the symbol it was dropped on, to go before or `after` it.
    public signal void dropped (string payload, string folder, string? target, bool after);
    Portfolio p;
    GenericArray<Tile> tiles = new GenericArray<Tile> ();
    string dragged = "";   // what is being dragged out of here
    Tile? hover_spot;      // while a drag hovers: the tile it would go beside,
    Tile? hover_block;     // the folder block it would land in,
    bool hover_after;      // and on which side of the tile

    public Treemap (Portfolio p) {
        this.p = p;
        has_tooltip = true;
        set_draw_func (paint);

        // Drag a tile out (to another spot here, or to the sidebar); a folder goes by its header band.
        var drag = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
        drag.prepare.connect ((x, y) => {
            var t = at (x, y, TileKind.STOCK) ?? at (x, y, TileKind.BENCHMARK);
            var block = at (x, y, TileKind.GROUP);
            if (t != null) dragged = t.symbol;
            else if (block != null && block.group != "") dragged = "folder:" + block.group;
            else return null;
            return new Gdk.ContentProvider.for_value (dragged);
        });
        drag.drag_begin.connect ((d) => {
            var name = dragged.has_prefix ("folder:") ? dragged.substring (7) : dragged;
            ((Gtk.DragIcon) Gtk.DragIcon.get_for_drag (d)).child = new Gtk.Label (@"  $name  ") { height_request = 34, css_classes = { "heading", "card" } };
        });
        add_controller (drag);

        // Drop one (from here or from the sidebar) on a tile to put it beside that tile, or on a
        // folder's block to file it there.
        var drop = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE) { preload = true };
        unowned Gtk.DropTarget target = drop;
        drop.motion.connect ((x, y) => {
            unowned Value? held = target.get_value ();   // known while it hovers, thanks to preload
            bool ok = aim (held != null ? held.get_string () : null, x, y, out hover_spot, out hover_block, out hover_after);
            if (!ok) hover_spot = hover_block = null;
            queue_draw ();
            return ok ? Gdk.DragAction.MOVE : (Gdk.DragAction) 0;
        });
        drop.leave.connect (() => { hover_spot = hover_block = null; queue_draw (); });
        drop.drop.connect ((value, x, y) => {
            Tile? spot, block;
            bool after;
            var payload = value.get_string ();
            bool ok = aim (payload, x, y, out spot, out block, out after);
            hover_spot = hover_block = null;
            queue_draw ();
            if (!ok) return false;
            string folder = spot != null ? spot.group : block.group;
            string? beside = spot != null ? spot.symbol : null;
            // Later, not from inside the drop: it rebuilds the very widgets taking part in it.
            Idle.add (() => { dropped (payload, folder, beside, after); return Source.REMOVE; });
            return true;
        });
        add_controller (drop);

        query_tooltip.connect ((x, y, keyboard, tip) => {
            for (int i = 0; i < tiles.length; i++) {
                var t = tiles[i];
                if (t.kind == TileKind.GROUP || x < t.x || x >= t.x + t.w || y < t.y || y >= t.y + t.h) continue;
                var worth = t.value > 0 ? "%s %s".printf (money (t.value, p.currency), p.currency) : "Watching";
                if (t.kind == TileKind.BENCHMARK) worth = "%s %s".printf (money (t.price, t.currency), t.currency);
                tip.set_text ("%s · %s\n%s · %s over %s".printf (t.symbol, t.name, worth, pct (t.change), RANGE_LABELS[range]));
                tip.set_tip_area ({ (int) t.x, (int) t.y, (int) t.w, (int) t.h });
                return true;
            }
            return false;
        });
    }

    // Where a dragged thing would land at (x, y): `spot` is the tile it would go beside (null if it
    // would only be filed in `block`'s folder), `after` the side. False if it can't go there: a stock
    // belongs in the body, a top-row tile in the top row, a folder among the folders. With no payload
    // (a drag whose content isn't known yet) anything under the pointer will do.
    bool aim (string? payload, double x, double y, out Tile? spot, out Tile? block, out bool after) {
        block = at (x, y, TileKind.GROUP);
        spot = at (x, y, TileKind.STOCK) ?? at (x, y, TileKind.BENCHMARK);
        after = false;
        if (spot != null && spot.kind == TileKind.BENCHMARK) after = x > spot.x + spot.w / 2;
        else if (spot != null) after = (x - spot.x) / spot.w + (y - spot.y) / spot.h > 1;   // past the tile's diagonal
        if (payload == null) return spot != null || block != null;
        if (payload.has_prefix ("folder:")) {
            spot = null;
            return block != null && block.group != payload.substring (7);
        }
        Tile? moving = null;
        for (int i = 0; i < tiles.length; i++) if (tiles[i].kind != TileKind.GROUP && tiles[i].symbol == payload) moving = tiles[i];
        if (moving == null || spot == moving) return false;
        if (spot != null && spot.kind != moving.kind) spot = null;   // not a neighbour it can have
        return spot != null || (block != null && moving.kind == TileKind.STOCK);
    }

    // A stock's tile: its symbol, its change and its name, stacked and centered. The name is what says
    // which company 8306.T is, so it stays: it wraps onto two lines, is cut with an ellipsis beyond
    // that, and the whole label shrinks before anything is left out. Only a tile too low for three
    // lines of the smallest text loses the name, and then the change.
    void label (Cairo.Context cr, Tile t) {
        double fit = double.min (t.w / 8, t.h / 4).clamp (7, 26), inner = t.w - 10;
        bool named = t.name != "" && t.name != t.symbol;
        for (int parts = named ? 3 : 2; parts >= 1; parts--) {
            foreach (double scale in new double[] { 1, 0.8, 0.64, 0.5 }) {
                double size = double.max (fit * scale, 6);
                Pango.Layout[] rows = { text_layout (this, "<span font_desc='Bold %.1f'>%s</span>".printf (size, Markup.escape_text (t.symbol)), true, inner, 1) };
                if (parts >= 2) rows += text_layout (this, "<span font_desc='%.1f'>%s</span>".printf (size * 0.75, pct (t.change)), true, inner, 1);
                if (parts >= 3) rows += text_layout (this, "<span font_desc='%.1f' alpha='75%%'>%s</span>".printf (size * 0.5 + 3, Markup.escape_text (t.name)), true, inner, 2);
                int total = 0, w, h;
                foreach (var row in rows) {
                    row.get_pixel_size (out w, out h);
                    total += h;
                }
                if (total > t.h - 6) continue;
                double y = t.y + (t.h - total) / 2;
                foreach (var row in rows) {
                    row.get_pixel_size (out w, out h);
                    cr.move_to (t.x + 5, y);
                    Pango.cairo_show_layout (cr, row);
                    y += h;
                }
                return;
            }
        }
    }

    // The tile of a kind under a point, if any. (A folder's block covers its stocks' tiles.)
    Tile? at (double x, double y, TileKind kind) {
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            if (t.kind == kind && x >= t.x && x < t.x + t.w && y >= t.y && y < t.y + t.h) return t;
        }
        return null;
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        tiles = p.tiles (range, now_s (), width, height);
        bool any_held = false;
        for (int i = 0; i < tiles.length; i++) any_held |= tiles[i].kind == TileKind.STOCK && tiles[i].value > 0;
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            var symbol = Markup.escape_text (t.symbol), name = Markup.escape_text (t.name);
            if (t.kind == TileKind.GROUP) {
                // A folder: a dark card laid behind its stocks (which come next in the list and are set
                // in from its edges), so it shows as a frame around them with a band across the top,
                // named and carrying their average move.
                double head = double.min (Portfolio.GROUP_HEADER, t.h / 3);
                cr.set_source_rgb (0.13, 0.14, 0.17);
                cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
                cr.fill ();
                cr.set_source_rgb (1, 1, 1);
                string[] labels = { "<b>%s</b>   %s".printf (symbol, pct (t.change)), "<b>%s</b>".printf (symbol) };
                foreach (var markup in labels)
                    if (draw_text (this, cr, "<span font_desc='9'>%s</span>".printf (markup), t.x + 8, t.y + head / 2, 0, 0.5, t.w - 14, head)) break;
                continue;
            }
            heat (cr, t.change, range);
            cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
            cr.fill ();
            if (any_held && t.kind == TileKind.STOCK && t.value <= 0) {
                // Watched next to real holdings: a dashed outline says this tile's size isn't money.
                cr.set_source_rgba (1, 1, 1, 0.55);
                cr.set_line_width (1.5);
                cr.set_dash ({ 5, 4 }, 0);
                cr.rectangle (t.x + 6, t.y + 6, t.w - 12, t.h - 12);
                cr.stroke ();
                cr.set_dash (null, 0);
            }
            cr.set_source_rgb (1, 1, 1);
            if (t.kind == TileKind.STOCK) {
                label (cr, t);
                continue;
            }
            // The top row. An index or a currency pair is known by its name and its level, not by Yahoo's
            // ticker for it; show as much as fits.
            double size = double.min (t.w / 11, t.h / 3.6).clamp (7, 15);
            var level = "<span font_desc='%.0f'>%s   %s</span>".printf (size * 0.85, money (t.price, t.currency), pct (t.change));
            string[] fits = {
                "<span font_desc='Bold %.0f'>%s</span>\n%s".printf (size, name, level),
                "<span font_desc='Bold %.0f'>%s</span>\n%s".printf (size, symbol, level),
                "<span font_desc='Bold %.0f'>%s</span>\n<span font_desc='%.0f'>%s</span>".printf (size, symbol, size * 0.85, pct (t.change)),
                "<span font_desc='Bold %.0f'>%s</span>".printf (size, symbol)
            };
            foreach (var markup in fits)
                if (draw_text (this, cr, markup, t.x + t.w / 2, t.y + t.h / 2, 0.5, 0.5, t.w - 10, t.h - 6)) break;
        }
        // Where a dragged thing would land: a thick white edge on the side of the tile it would go
        // beside (top and left for before, bottom and right for after), or an outline of the folder.
        cr.set_source_rgb (1, 1, 1);
        cr.set_line_width (5);
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            if (hover_spot != null && t.kind != TileKind.GROUP && t.symbol == hover_spot.symbol) {
                double x = hover_after ? t.x + t.w - 3 : t.x + 3, y = hover_after ? t.y + t.h - 3 : t.y + 3;
                cr.move_to (x, t.y + 3);
                cr.line_to (x, t.y + t.h - 3);
                if (t.kind == TileKind.STOCK) {
                    cr.move_to (t.x + 3, y);
                    cr.line_to (t.x + t.w - 3, y);
                }
                cr.stroke ();
            } else if (hover_spot == null && hover_block != null && t.kind == TileKind.GROUP && t.group == hover_block.group) {
                cr.rectangle (t.x + 3, t.y + 3, t.w - 6, t.h - 6);
                cr.stroke ();
            }
        }
    }
}

public class Matrix : Gtk.DrawingArea {
    const int ROW = 36;
    Portfolio p;

    public Matrix (Portfolio p) {
        this.p = p;
        set_draw_func (paint);
    }

    // Tracked symbols in heatmap order (its tiles, layout ignored, minus the folder headers).
    GenericArray<Tile> rows () {
        var all = p.tiles (Range.D1, now_s (), 1, 1), symbols = new GenericArray<Tile> ();
        for (int i = 0; i < all.length; i++) if (all[i].kind != TileKind.GROUP) symbols.add (all[i]);
        return symbols;
    }

    public void refresh () {
        content_height = ROW * (rows ().length + 2);
        queue_draw ();
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        var fg = get_color ();
        var now = now_s ();
        var tiles = rows ();
        double label_w = double.min (width * 0.34, 320), cell_w = (width - label_w) / RANGE_LABELS.length;

        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.6);
        for (int c = 0; c < RANGE_LABELS.length; c++)
            draw_text (this, cr, RANGE_LABELS[c], label_w + cell_w * (c + 0.5), ROW / 2.0, 0.5, 0.5);

        // Row 0 is the whole portfolio, in its currency (skipped when nothing is held); the rest are
        // each instrument's own price change.
        int first = 1;
        for (int i = 0; i < tiles.length; i++) if (tiles[i].value > 0) first = 0;
        for (int row = first; row <= tiles.length; row++) {
            double y = ROW * (row + 1 - first);
            var t = row > 0 ? tiles[row - 1] : null;
            var label = t != null ? "<b>%s</b>  <span alpha='60%%'>%s</span>".printf (Markup.escape_text (t.symbol), Markup.escape_text (t.name)) : "<b>Portfolio</b>";
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 1);
            draw_text (this, cr, label, 12, y + ROW / 2.0, 0, 0.5, label_w - 20, ROW, 1);

            for (int c = 0; c < RANGE_LABELS.length; c++) {
                double change;
                if (t != null) {
                    change = p.quotes[t.symbol].change ((Range) c, now);
                } else {
                    double gain, capital;
                    p.gain ((Range) c, now, out gain, out capital);
                    change = gain / capital;
                }
                heat (cr, change, (Range) c);
                cr.rectangle (label_w + cell_w * c + 1, y + 1, cell_w - 2, ROW - 2);
                cr.fill ();
                cr.set_source_rgb (1, 1, 1);
                draw_text (this, cr, pct (change), label_w + cell_w * (c + 0.5), y + ROW / 2.0, 0.5, 0.5, cell_w - 4);
            }
        }
    }
}

}
