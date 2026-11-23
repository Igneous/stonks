// Number formatting, text drawing and the line chart.
namespace Stonks {

// Yen, won and dong amounts are shown whole: their minor units are not in use.
int decimals (string currency) { return currency == "JPY" || currency == "KRW" || currency == "VND" ? 0 : 2; }
string money (double v, string currency) { return v.is_finite () ? "%'.*f".printf (decimals (currency), v) : "—"; }
string delta (double v, string currency) { return v.is_finite () ? "%+'.*f".printf (decimals (currency), v) : "—"; }
string pct (double f) { return f.is_finite () ? "%+.2f%%".printf (f * 100) : "—"; }

// Market-cap sized numbers: 3.25T, 812.40B, 45.10M.
string compact (double v) {
    if (v >= 1e12) return "%'.2fT".printf (v / 1e12);
    if (v >= 1e9) return "%.2fB".printf (v / 1e9);
    if (v >= 1e6) return "%.2fM".printf (v / 1e6);
    return "%'.0f".printf (v);
}

// Draw Pango markup in the current cairo color, its (ax, ay) fraction anchored at (x, y).
// Text that would not fit in max_w x max_h is cut short with an ellipsis if `ellipsize`; otherwise
// nothing is drawn and the result is false.
bool draw_text (Gtk.Widget widget, Cairo.Context cr, string markup, double x, double y, double ax, double ay,
                double max_w = double.MAX, double max_h = double.MAX, bool ellipsize = false) {
    var layout = widget.create_pango_layout (null);
    layout.set_markup (markup, -1);
    layout.set_alignment (ax == 0.5 ? Pango.Alignment.CENTER : Pango.Alignment.LEFT);
    if (ellipsize) {
        layout.set_width ((int) (max_w * Pango.SCALE));
        layout.set_ellipsize (Pango.EllipsizeMode.END);
    }
    int w, h;
    layout.get_pixel_size (out w, out h);
    if (w > max_w || h > max_h) return false;
    cr.move_to (x - w * ax, y - h * ay);
    Pango.cairo_show_layout (cr, layout);
    return true;
}

public class Chart : Gtk.DrawingArea {
    const int LEFT = 12;
    const int TOP = 30;
    const int BOTTOM = 26;
    const string[] AXIS = { "%H:%M", "%a %e", "%b %e", "%b %e", "%b %Y", "%b %Y", "%b %Y" };

    Series s = new Series ();
    double basis = double.NAN;
    bool up = true;
    Range range;
    string currency = "";
    int hover = -1;
    // Plot geometry, set by paint().
    double lo;
    double hi;
    double pw;
    double ph;

    construct {
        content_height = 280;
        add_css_class ("caption");
        set_draw_func (paint);
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => {
            hover = pw > 0 ? (int) Math.round (((x - LEFT) / pw).clamp (0, 1) * (s.n - 1)) : -1;
            queue_draw ();
        });
        motion.leave.connect (() => { hover = -1; queue_draw (); });
        add_controller (motion);
    }

    // Show a series; `basis` (NaN for none) is drawn as the dashed reference line, `up` picks green or red.
    public void plot (Series s, double basis, bool up, Range range, string currency) {
        this.currency = currency;
        this.s = s;
        this.basis = basis;
        this.up = up;
        this.range = range;
        hover = -1;
        queue_draw ();
    }

    // x by index, not time: nights, weekends and lunch breaks would otherwise be long flat stretches.
    double px (int i) { return LEFT + pw * i / (s.n - 1); }
    double py (double v) { return TOP + ph * (hi - v) / (hi - lo); }

    void ink (Cairo.Context cr, double alpha) {
        if (up) cr.set_source_rgba (0.18, 0.76, 0.49, alpha); else cr.set_source_rgba (0.93, 0.2, 0.23, alpha);
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        var fg = get_color ();
        if (s.n < 2) {
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.5);
            draw_text (this, cr, "No price data for this range yet", width / 2.0, height / 2.0, 0.5, 0.5);
            return;
        }
        lo = hi = s.v[0];
        foreach (double v in s.v) { lo = double.min (lo, v); hi = double.max (hi, v); }
        if (basis.is_finite ()) { lo = double.min (lo, basis); hi = double.max (hi, basis); }
        double pad = double.max ((hi - lo) * 0.08, hi * 0.001) + 1e-9;
        lo = lo >= 0 ? double.max (lo - pad, 0) : lo - pad;   // no negative axis under an all-positive series
        hi += pad;

        // The right margin fits the widest price label, whatever the currency's magnitude.
        int label_w = 0, label_h;
        for (int i = 0; i <= 4; i++) {
            int w;
            create_pango_layout (money (lo + (hi - lo) * i / 4, currency)).get_pixel_size (out w, out label_h);
            label_w = int.max (label_w, w);
        }
        pw = width - LEFT - label_w - 16;
        ph = height - TOP - BOTTOM;
        if (pw < 10 || ph < 10) return;

        cr.set_line_width (1);
        for (int i = 0; i <= 4; i++) {
            double v = lo + (hi - lo) * i / 4, y = Math.round (py (v)) + 0.5;
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.1);
            cr.move_to (LEFT, y);
            cr.line_to (LEFT + pw, y);
            cr.stroke ();
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.6);
            draw_text (this, cr, money (v, currency), LEFT + pw + 8, y, 0, 0.5);
        }
        // A 1D view of holdings on several exchanges strings their sessions together, so name the day.
        bool span_days = range == Range.D1 && s.t[s.n - 1] - s.t[0] > 86400;
        string last = "";
        for (int i = 0; i <= 4; i++) {
            int k = (s.n - 1) * i / 4;
            string text = new DateTime.from_unix_local (s.t[k]).format (span_days ? "%a %H:%M" : AXIS[range]);
            if (text != last) draw_text (this, cr, text, px (k), height - BOTTOM + 6, i / 4.0, 0);
            last = text;
        }

        if (basis.is_finite ()) {
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.45);
            cr.set_dash ({ 4, 4 }, 0);
            cr.move_to (LEFT, Math.round (py (basis)) + 0.5);
            cr.line_to (LEFT + pw, Math.round (py (basis)) + 0.5);
            cr.stroke ();
            cr.set_dash (null, 0);
        }

        cr.move_to (px (0), py (s.v[0]));
        for (int i = 1; i < s.n; i++) cr.line_to (px (i), py (s.v[i]));
        var line = cr.copy_path ();
        cr.line_to (LEFT + pw, TOP + ph);
        cr.line_to (LEFT, TOP + ph);
        cr.close_path ();
        var fade = new Cairo.Pattern.linear (0, TOP, 0, TOP + ph);
        fade.add_color_stop_rgba (0, up ? 0.18 : 0.93, up ? 0.76 : 0.2, up ? 0.49 : 0.23, 0.28);
        fade.add_color_stop_rgba (1, up ? 0.18 : 0.93, up ? 0.76 : 0.2, up ? 0.49 : 0.23, 0);
        cr.set_source (fade);
        cr.fill ();
        cr.append_path (line);
        ink (cr, 1);
        cr.set_line_width (2);
        cr.set_line_join (Cairo.LineJoin.ROUND);
        cr.stroke ();

        if (hover < 0 || hover >= s.n) return;
        double x = px (hover), v = s.v[hover];
        cr.set_line_width (1);
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.35);
        cr.move_to (Math.round (x) + 0.5, TOP);
        cr.line_to (Math.round (x) + 0.5, TOP + ph);
        cr.stroke ();
        ink (cr, 1);
        cr.arc (x, py (v), 4, 0, 2 * Math.PI);
        cr.fill ();
        var when = new DateTime.from_unix_local (s.t[hover]).format (range <= Range.D7 ? "%a %e %b, %H:%M" : "%e %b %Y");
        var readout = "<b>%s</b>   %s".printf (money (v, currency), when);
        if (basis.is_finite ()) readout += "   %s (%s)".printf (delta (v - basis, currency), pct (v / basis - 1));
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.9);
        draw_text (this, cr, readout, LEFT, 4, 0, 0);
    }
}

}
