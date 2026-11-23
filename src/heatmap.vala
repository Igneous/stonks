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
    Portfolio p;
    GenericArray<Tile> tiles = new GenericArray<Tile> ();

    public Treemap (Portfolio p) {
        this.p = p;
        has_tooltip = true;
        set_draw_func (paint);
        query_tooltip.connect ((x, y, keyboard, tip) => {
            for (int i = 0; i < tiles.length; i++) {
                var t = tiles[i];
                if (x < t.x || x >= t.x + t.w || y < t.y || y >= t.y + t.h) continue;
                tip.set_text ("%s · %s\n%s %s · %s over %s".printf (t.symbol, t.name, money (t.value, p.currency), p.currency, pct (t.change), RANGE_LABELS[range]));
                tip.set_tip_area ({ (int) t.x, (int) t.y, (int) t.w, (int) t.h });
                return true;
            }
            return false;
        });
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        tiles = p.tiles (range, now_s (), width, height);
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            heat (cr, t.change, range);
            cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
            cr.fill ();
            // Text scales with the tile; show as much as fits.
            double size = double.min (t.w / 8, t.h / 4).clamp (7, 26);
            var head = "<span font_desc='Bold %.0f'>%s</span>".printf (size, Markup.escape_text (t.symbol));
            var move = "<span font_desc='%.0f'>%s</span>".printf (size * 0.75, pct (t.change));
            var name = "<span font_desc='%.0f' alpha='75%%'>%s</span>".printf (size * 0.5 + 3, Markup.escape_text (t.name));
            string[] fits = { @"$head\n$move\n$name", @"$head\n$move", head };
            cr.set_source_rgb (1, 1, 1);
            foreach (var markup in fits)
                if (draw_text (this, cr, markup, t.x + t.w / 2, t.y + t.h / 2, 0.5, 0.5, t.w - 10, t.h - 6)) break;
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

    // Held symbols, biggest first (the treemap's tiles, layout ignored).
    public void refresh () {
        content_height = ROW * (p.tiles (Range.D1, now_s (), 1, 1).length + 2);
        queue_draw ();
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        var fg = get_color ();
        var now = now_s ();
        var tiles = p.tiles (Range.D1, now, 1, 1);
        double label_w = double.min (width * 0.34, 320), cell_w = (width - label_w) / RANGE_LABELS.length;

        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.6);
        for (int c = 0; c < RANGE_LABELS.length; c++)
            draw_text (this, cr, RANGE_LABELS[c], label_w + cell_w * (c + 0.5), ROW / 2.0, 0.5, 0.5);

        // Row 0 is the whole portfolio, in its currency; the rest are each instrument's own price change.
        for (int row = 0; row <= tiles.length; row++) {
            double y = ROW * (row + 1);
            var t = row > 0 ? tiles[row - 1] : null;
            var bold = "<b>%s</b>".printf (t != null ? Markup.escape_text (t.symbol) : "Portfolio");
            string[] fits = { bold + (t != null ? "  <span alpha='60%%'>%s</span>".printf (Markup.escape_text (t.name)) : ""), bold };
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 1);
            foreach (var markup in fits)
                if (draw_text (this, cr, markup, 12, y + ROW / 2.0, 0, 0.5, label_w - 20)) break;

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
