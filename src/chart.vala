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

// A Pango layout of some markup. With `lines` > 0 it is kept to max_w: wrapped onto at most that many
// lines per paragraph, the rest cut with an ellipsis. With 0 it is left as wide as it comes.
Pango.Layout text_layout (Gtk.Widget widget, string markup, bool centered, double max_w = double.MAX, int lines = 0) {
    var layout = widget.create_pango_layout (null);
    layout.set_markup (markup, -1);
    layout.set_alignment (centered ? Pango.Alignment.CENTER : Pango.Alignment.LEFT);
    if (lines > 0) {
        layout.set_width ((int) (max_w * Pango.SCALE));
        layout.set_wrap (Pango.WrapMode.WORD_CHAR);
        layout.set_ellipsize (Pango.EllipsizeMode.END);
        layout.set_height (-lines);
    }
    return layout;
}

// Draw Pango markup in the current cairo color, its (ax, ay) fraction anchored at (x, y).
// If it would not fit in max_w x max_h, nothing is drawn and the result is false; `lines` > 0 makes the
// width always fit, by wrapping and cutting as text_layout() does.
bool draw_text (Gtk.Widget widget, Cairo.Context cr, string markup, double x, double y, double ax, double ay,
                double max_w = double.MAX, double max_h = double.MAX, int lines = 0) {
    var layout = text_layout (widget, markup, ax == 0.5, max_w, lines);
    int w, h;
    layout.get_pixel_size (out w, out h);
    if ((lines == 0 && w > max_w) || h > max_h) return false;
    cr.move_to (x - (lines > 0 ? max_w : w) * ax, y - h * ay);
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
    int today;
    int regular;
    string currency = "";
    double hover = -1;   // where the pointer is, across; negative while it is elsewhere
    // What is pinned, by time so that it stays put as the series grows: a point, or the two ends of a
    // span in the order they were dragged. Both 0 for nothing.
    int64 anchor;
    int64 reach;
    // Plot geometry, set by paint().
    double lo;
    double hi;
    double pw;
    double ph;

    // The pins changed: a click pins a point, a drag a span, a right click (or unpin()) nothing.
    public signal void pinned ();
    public int64 pin_from { get { return int64.min (anchor, reach); } }
    public int64 pin_to { get { return int64.max (anchor, reach); } }

    construct {
        content_height = 280;
        add_css_class ("caption");
        set_draw_func (paint);
        var motion = new Gtk.EventControllerMotion ();
        motion.motion.connect ((x, y) => { hover = x; queue_draw (); });
        motion.leave.connect (() => { hover = -1; queue_draw (); });
        add_controller (motion);
        var drag = new Gtk.GestureDrag ();
        unowned Gtk.GestureDrag self = drag;   // unowned, or its own handler would keep it alive
        drag.drag_begin.connect ((x, y) => mark (x, x));
        drag.drag_update.connect ((dx, dy) => {
            double x, y;
            self.get_start_point (out x, out y);
            mark (x, Math.fabs (dx) < 4 ? x : x + dx);   // a hand that shakes on a click isn't dragging
        });
        add_controller (drag);
        var clear = new Gtk.GestureClick () { button = Gdk.BUTTON_SECONDARY };
        clear.pressed.connect (() => { unpin (); pinned (); });
        add_controller (clear);
    }

    // Show a series; `basis` (NaN for none) is drawn as the dashed reference line, `up` picks green or red.
    // `today`, if not 0, is the point the latest session starts at (see Quote.trail): an upright
    // dashed line sets it off from the session before. `regular`, if not 0, is how many of the points
    // are a regular session's: the rest, traded before or after hours, are drawn in grey. What is
    // pinned stays pinned: unpin() when the chart turns to something else.
    public void plot (Series s, double basis, bool up, Range range, string currency, int today = 0, int regular = 0) {
        this.today = today;
        this.regular = regular > 0 && regular < s.n ? regular : s.n;
        this.currency = currency;
        this.s = s;
        this.basis = basis;
        this.up = up;
        this.range = range;
        queue_draw ();
    }

    public void unpin () {
        anchor = reach = 0;
        queue_draw ();
    }

    // Dev aid, see the Makefile: pin by position, as fractions of the chart's width.
    public void pin (double from, double to) { mark (LEFT + pw * from, LEFT + pw * to); }

    // Pin the points under two places across the chart: one point, if they are the same.
    void mark (double from, double to) {
        if (s.n < 2 || pw <= 0) return;
        anchor = s.t[at (from)];
        reach = s.t[at (to)];
        queue_draw ();
        pinned ();
    }

    // x by index, not time: nights, weekends and lunch breaks would otherwise be long flat stretches.
    double px (int i) { return LEFT + pw * i / (s.n - 1); }
    double py (double v) { return TOP + ph * (hi - v) / (hi - lo); }
    int at (double x) { return (int) Math.round (((x - LEFT) / pw).clamp (0, 1) * (s.n - 1)); }
    int index (int64 t) { return int.max (s.before (t + 1), 0); }

    void ink (Cairo.Context cr, double alpha) {
        if (up) cr.set_source_rgba (0.18, 0.76, 0.49, alpha); else cr.set_source_rgba (0.93, 0.2, 0.23, alpha);
    }

    string when (int i) {
        return new DateTime.from_unix_local (s.t[i]).format (range <= Range.D7 ? "%a %e %b, %H:%M" : "%e %b %Y").strip ();
    }

    // A point in words (markup): its price, its time, and how far that is from the basis.
    string point_text (int i) {
        var text = "<b>%s</b>   %s".printf (money (s.v[i], currency), when (i));
        if (basis.is_finite ()) text += "   %s (%s)".printf (delta (s.v[i] - basis, currency), pct (s.v[i] / basis - 1));
        return text;
    }

    // What is pinned, in words (markup): a point as point_text() has it, or a span's two prices and
    // times with the change from the one to the other. "" for nothing.
    public string pin_text () {
        if (anchor == 0 || s.n < 2) return "";
        int a = index (pin_from), b = index (pin_to);
        if (a == b) return point_text (a);
        return "<b>%s → %s</b>   %s → %s   %s (%s)".printf (money (s.v[a], currency), money (s.v[b], currency), when (a), when (b),
                                                            delta (s.v[b] - s.v[a], currency), pct (s.v[b] / s.v[a] - 1));
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
        bool span_days = range == Range.D1 && (today > 0 || s.t[s.n - 1] - s.t[0] > 86400);
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
        if (today > 0 && today < s.n) {
            double x = Math.round ((px (today - 1) + px (today)) / 2) + 0.5;
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.45);
            cr.set_dash ({ 4, 4 }, 0);
            cr.move_to (x, TOP);
            cr.line_to (x, TOP + ph);
            cr.stroke ();
            cr.set_dash (null, 0);
        }

        // Outside regular hours first, so that the session's line ends on top of it.
        cr.set_line_width (2);
        cr.set_line_join (Cairo.LineJoin.ROUND);
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.4);
        for (int i = regular - 1; i < s.n; i++) cr.line_to (px (i), py (s.v[i]));
        cr.stroke ();

        cr.move_to (px (0), py (s.v[0]));
        for (int i = 1; i < regular; i++) cr.line_to (px (i), py (s.v[i]));
        var line = cr.copy_path ();
        cr.line_to (px (regular - 1), TOP + ph);
        cr.line_to (LEFT, TOP + ph);
        cr.close_path ();
        var fade = new Cairo.Pattern.linear (0, TOP, 0, TOP + ph);
        fade.add_color_stop_rgba (0, up ? 0.18 : 0.93, up ? 0.76 : 0.2, up ? 0.49 : 0.23, 0.28);
        fade.add_color_stop_rgba (1, up ? 0.18 : 0.93, up ? 0.76 : 0.2, up ? 0.49 : 0.23, 0);
        cr.set_source (fade);
        cr.fill ();
        cr.append_path (line);
        ink (cr, 1);
        cr.stroke ();

        // What is pinned: a dot on the line and a dashed level across from each point, and a wash over a span.
        cr.set_line_width (1);
        if (anchor != 0) {
            int a = index (pin_from), b = index (pin_to);
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.07);
            cr.rectangle (px (a), TOP, px (b) - px (a), ph);
            cr.fill ();
            foreach (int i in new int[] { a, b }) {   // the same point twice, if it is only the one
                double y = Math.round (py (s.v[i])) + 0.5;
                ink (cr, 0.9);
                cr.set_dash ({ 6, 3 }, 0);
                cr.move_to (LEFT, y);
                cr.line_to (LEFT + pw, y);
                cr.stroke ();
                cr.set_dash (null, 0);
                cr.arc (px (i), py (s.v[i]), 5, 0, 2 * Math.PI);
                cr.fill_preserve ();
                cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.9);
                cr.stroke ();
            }
        }

        if (hover < 0) return;
        int h = at (hover);
        double x = px (h);
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.35);
        cr.move_to (Math.round (x) + 0.5, TOP);
        cr.line_to (Math.round (x) + 0.5, TOP + ph);
        cr.stroke ();
        if (h < regular) ink (cr, 1);
        cr.arc (x, py (s.v[h]), 4, 0, 2 * Math.PI);
        cr.fill ();
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.9);
        draw_text (this, cr, point_text (h), LEFT, 4, 0, 0);
    }
}

}
