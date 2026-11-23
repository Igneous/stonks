// The two heatmaps: the tiles of everything tracked for one range, laid out by folder, and a symbol x range
// performance grid.
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

// Where something dragged over the heatmap would land.
class Landing {
    public Tile? spot;     // a stock: the tile it would go beside
    public Tile? block;    // the folder it would go into, or (`beside`) next to; none is the heatmap itself
    public bool beside;
    public bool after;     // beside something: on its far side
    public Dock dock;      // a folder: the edge of the heatmap it would be pinned to
}

public class Treemap : Gtk.DrawingArea {
    const double EDGE = 28;   // how near an edge a dragged folder has to be to be aimed at the edge
    const double GEAR = 24;   // the width, at the end of a folder's label, that its gear answers to

    public Range range;
    public bool charts = true;   // draw each tile's price over the range behind its label
    HashTable<string, Cairo.ImageSurface> logos = new HashTable<string, Cairo.ImageSurface> (str_hash, str_equal);
    public signal void changed ();                               // something was rearranged here: time to save, and to redraw
    public signal void opened (string symbol);                   // a tile was double-clicked
    public signal void peeked (string symbol);                   // a tile has been hovered long enough: time to fill `card`
    public signal void configure (Group folder, Gdk.Rectangle gear);   // a folder's gear was clicked
    public Gtk.Popover card = new Gtk.Popover () { autohide = false };   // the hover card; whoever hears `peeked` sets its child
    string hovered = "";   // the symbol under the pointer
    uint hover_timer;
    double px;             // where the pointer is
    double py;
    Portfolio p;
    GenericArray<Tile> tiles = new GenericArray<Tile> ();
    string dragged = "";   // what is being dragged out of here
    Landing? landing;      // while a drag hovers: where it would land
    Tile? sizing;          // the pinned folder being resized by its divider,
    double grab_x;         // and where the pointer took hold of it
    double grab_y;

    public Treemap (Portfolio p) {
        this.p = p;
        set_draw_func (paint);
        card.set_parent (this);

        // Rest on a tile for a moment and its card comes up beside it; move on and it goes.
        var hover = new Gtk.EventControllerMotion ();
        hover.motion.connect ((x, y) => {
            px = x;
            py = y;
            var edge = divider_at (x, y);
            if (edge == null) set_cursor (null);
            else set_cursor_from_name (edge.folder.dock == Dock.TOP || edge.folder.dock == Dock.BOTTOM ? "row-resize" : "col-resize");
            var t = edge == null ? leaf_at (x, y) : null;
            var symbol = t != null ? t.symbol : "";
            if (symbol == hovered) return;
            unhover ();
            hovered = symbol;
            if (t == null) return;
            int left = (int) double.max (t.x, t.clip.x), top = (int) double.max (t.y, t.clip.y);
            Gdk.Rectangle tile = { left, top, (int) double.min (t.x + t.w, t.clip.x + t.clip.w) - left, (int) double.min (t.y + t.h, t.clip.y + t.clip.h) - top };
            hover_timer = Timeout.add (1200, () => {
                hover_timer = 0;
                card.child = null;
                peeked (symbol);
                if (card.child != null) {
                    card.pointing_to = tile;
                    card.popup ();
                }
                return Source.REMOVE;
            });
        });
        hover.leave.connect (unhover);
        add_controller (hover);

        // A double-click opens a stock; a click on a folder's gear, its settings.
        var click = new Gtk.GestureClick ();
        click.pressed.connect ((presses, x, y) => {
            var t = leaf_at (x, y);
            if (presses != 2 || t == null) return;
            unhover ();
            opened (t.symbol);
        });
        click.released.connect ((presses, x, y) => {
            var b = gear_at (x, y);
            if (b == null) return;
            unhover ();
            configure (b.folder, { (int) (b.x + b.w - GEAR), (int) b.y, (int) GEAR, (int) double.min (Portfolio.GROUP_HEADER, b.h / 3) });
        });
        add_controller (click);

        // The wheel moves a strip that has more in it than it shows: the innermost one under the pointer.
        var wheel = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.BOTH_AXES);
        unowned Gtk.EventControllerScroll turning = wheel;
        wheel.scroll.connect ((dx, dy) => {
            var b = block_at (px, py, null);
            for (unowned Group? g = b != null ? b.folder : p.root; g != null; g = g.parent) {
                if (g.overflow <= 0) continue;
                g.offset += (dy != 0 ? dy : dx) * (turning.get_unit () == Gdk.ScrollUnit.WHEEL ? 40 : 1);   // tiles() keeps it within bounds
                unhover ();
                queue_draw ();
                return true;
            }
            return false;
        });
        add_controller (wheel);

        // A pinned folder is resized by dragging the edge it shares with the rest.
        var resize = new Gtk.GestureDrag ();
        unowned Gtk.GestureDrag pulling = resize;
        resize.drag_begin.connect ((x, y) => {
            sizing = divider_at (x, y);
            grab_x = x;
            grab_y = y;
            pulling.set_state (sizing != null ? Gtk.EventSequenceState.CLAIMED : Gtk.EventSequenceState.DENIED);
        });
        resize.drag_update.connect ((dx, dy) => {
            if (sizing == null) return;
            var g = sizing.folder;
            // What it is a share of: the heatmap's size, or the inside of the folder it is in.
            Box room = { 0, 0, get_width (), get_height () };
            for (int i = 0; i < tiles.length; i++) if (tiles[i].kind == TileKind.GROUP && tiles[i].folder == g.parent) room = tiles[i].inside ();
            double x = grab_x + dx, y = grab_y + dy, thick;
            switch (g.dock) {
            case Dock.TOP: thick = (y - sizing.y) / room.h; break;
            case Dock.BOTTOM: thick = (sizing.y + sizing.h - y) / room.h; break;
            case Dock.LEFT: thick = (x - sizing.x) / room.w; break;
            default: thick = (sizing.x + sizing.w - x) / room.w; break;
            }
            g.size = thick.clamp (0.05, 0.8);
            queue_draw ();
        });
        resize.drag_end.connect ((dx, dy) => {
            if (sizing == null) return;
            sizing = null;
            changed ();
        });
        add_controller (resize);

        // Drag a tile out (to another spot here, or to the sidebar); a folder goes by its label or frame.
        var drag = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
        drag.prepare.connect ((x, y) => {
            if (divider_at (x, y) != null || gear_at (x, y) != null) return null;
            var t = leaf_at (x, y);
            var block = block_at (x, y, null);
            if (t != null) dragged = t.symbol;
            else if (block != null) dragged = "folder:" + block.folder.id;
            else return null;
            return new Gdk.ContentProvider.for_value (dragged);
        });
        drag.drag_begin.connect ((d) => {
            unhover ();
            var name = dragged.has_prefix ("folder:") ? p.folder (dragged.substring (7)).name : dragged;
            ((Gtk.DragIcon) Gtk.DragIcon.get_for_drag (d)).child = new Gtk.Label (@"  $name  ") { height_request = 34, css_classes = { "heading", "card" } };
        });
        add_controller (drag);

        // Drop one here, from here or from the sidebar: see aim() for where it goes.
        var drop = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE) { preload = true };
        unowned Gtk.DropTarget target = drop;
        drop.motion.connect ((x, y) => {
            unowned Value? held = target.get_value ();   // known while it hovers, thanks to preload
            landing = aim (held != null ? held.get_string () : null, x, y);
            queue_draw ();
            return landing != null ? Gdk.DragAction.MOVE : (Gdk.DragAction) 0;
        });
        drop.leave.connect (() => { landing = null; queue_draw (); });
        drop.drop.connect ((value, x, y) => {
            var payload = value.get_string ();
            var l = aim (payload, x, y);
            landing = null;
            queue_draw ();
            if (l == null) return false;
            // Later, not from inside the drop: what follows rebuilds the very widgets taking part in it.
            Idle.add (() => { land (payload, l); return Source.REMOVE; });
            return true;
        });
        add_controller (drop);
    }

    void unhover () {
        if (hover_timer != 0) Source.remove (hover_timer);
        hover_timer = 0;
        hovered = "";
        card.popdown ();
    }

    // A popover lives off its parent's allocation, and is its parent's to let go of. (The card is ours;
    // a folder's settings are put here by the window.)
    public override void size_allocate (int width, int height, int baseline) {
        base.size_allocate (width, height, baseline);
        for (var c = get_first_child (); c != null; c = c.get_next_sibling ()) if (c is Gtk.Popover) ((Gtk.Popover) c).present ();
    }

    public override void dispose () {
        card.unparent ();
        base.dispose ();
    }

    // Give a symbol's tile a logo to show (null takes it away again).
    public void set_logo (string symbol, Gdk.Texture? texture) {
        logos.remove (symbol);
        if (texture != null) {
            var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32, texture.width, texture.height);
            texture.download (surface.get_data (), surface.get_stride ());
            surface.mark_dirty ();
            logos[symbol] = surface;
        }
        queue_draw ();
    }

    public void clear_logos () {
        logos.remove_all ();
        queue_draw ();
    }

    // The tile's price over the range, as a faint line and wash behind everything else on it.
    void chart (Cairo.Context cr, Tile t) {
        var q = p.quotes[t.symbol];
        if (q == null || t.w < 30 || t.h < 30) return;
        var s = q.view (range, now_s ());
        if (s.n < 2) return;
        int step = int.max (1, (int) (s.n / (t.w / 2)));   // a point every two pixels is as fine as it can show
        double lo = s.v[0], hi = s.v[0];
        foreach (double v in s.v) { lo = double.min (lo, v); hi = double.max (hi, v); }
        if (hi <= lo) return;
        double left = t.x + 1, width = t.w - 2, top = t.y + t.h * 0.12, height = t.h * 0.8;
        cr.save ();
        cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
        cr.clip ();
        cr.move_to (left, top + height * (hi - s.v[0]) / (hi - lo));
        for (int i = step; i < s.n - 1; i += step) cr.line_to (left + width * i / (s.n - 1), top + height * (hi - s.v[i]) / (hi - lo));
        cr.line_to (left + width, top + height * (hi - s.v[s.n - 1]) / (hi - lo));
        var line = cr.copy_path ();
        cr.line_to (left + width, t.y + t.h);
        cr.line_to (left, t.y + t.h);
        cr.close_path ();
        cr.set_source_rgba (1, 1, 1, 0.09);
        cr.fill ();
        cr.append_path (line);
        cr.set_source_rgba (1, 1, 1, 0.32);
        cr.set_line_width (1.5);
        cr.set_line_join (Cairo.LineJoin.ROUND);
        cr.stroke ();
        cr.restore ();
    }

    // A logo as a small rounded badge with its corner at (x, y). On a white plate: most logos are
    // drawn for a white page and vanish on a red or green tile. Fitted, not stretched: some are
    // wordmarks, wider than they are tall.
    void badge (Cairo.Context cr, Cairo.ImageSurface image, double x, double y, double size) {
        double r = size * 0.22;
        cr.save ();
        cr.new_sub_path ();
        cr.arc (x + size - r, y + r, r, -Math.PI / 2, 0);
        cr.arc (x + size - r, y + size - r, r, 0, Math.PI / 2);
        cr.arc (x + r, y + size - r, r, Math.PI / 2, Math.PI);
        cr.arc (x + r, y + r, r, Math.PI, Math.PI * 1.5);
        cr.close_path ();
        cr.clip ();
        cr.set_source_rgb (1, 1, 1);
        cr.paint ();
        double fit = size / double.max (image.get_width (), image.get_height ());
        cr.translate (x + (size - image.get_width () * fit) / 2, y + (size - image.get_height () * fit) / 2);
        cr.scale (fit, fit);
        cr.set_source_surface (image, 0, 0);
        cr.get_source ().set_filter (Cairo.Filter.GOOD);
        cr.paint ();
        cr.restore ();
    }

    // Where a dragged thing would land at (x, y); null if it can't go there. With no payload (a drag
    // whose content isn't known yet) it is taken for a stock.
    //  - A stock on a tile goes beside it, before or after by which side of the tile's diagonal; on a
    //    folder's label or frame it is filed there.
    //  - A folder near an edge of the heatmap is pinned along that edge. On another folder it goes
    //    inside it, or next to it if it is near that folder's edge. Anywhere else, to the top level.
    Landing? aim (string? payload, double x, double y) {
        var l = new Landing ();
        if (payload != null && payload.has_prefix ("folder:")) {
            var moving = p.folder (payload.substring (7));
            if (moving == p.root) return null;
            if (y < EDGE) l.dock = Dock.TOP;
            else if (y > get_height () - EDGE) l.dock = Dock.BOTTOM;
            else if (x < EDGE) l.dock = Dock.LEFT;
            else if (x > get_width () - EDGE) l.dock = Dock.RIGHT;
            if (l.dock != Dock.FLOW) return l;
            var b = l.block = block_at (x, y, moving);
            if (b == null) return l;
            double band = double.min (EDGE, double.min (b.w, b.h) / 4);
            bool before = x < b.x + band || y < b.y + band;
            l.after = !before && (x > b.x + b.w - band || y > b.y + b.h - band);
            l.beside = before || l.after;
            return l;
        }
        l.spot = leaf_at (x, y);
        l.block = block_at (x, y, null);
        if (l.spot == null) return l;
        if (l.spot.symbol == payload) return null;
        l.after = (x - l.spot.x) / l.spot.w + (y - l.spot.y) / l.spot.h > 1;
        return l;
    }

    // It was dropped: put it there.
    void land (string payload, Landing l) {
        if (payload.has_prefix ("folder:")) {
            var g = p.folder (payload.substring (7));
            if (l.dock != Dock.FLOW) {
                p.move_group (g, p.root);
                p.dock_group (g, l.dock);
            } else if (l.beside) {
                p.move_group (g, l.block.folder.parent, l.block.folder, l.after);
            } else {
                p.move_group (g, l.block != null ? l.block.folder : p.root);
            }
        } else if (l.spot != null) {
            p.move (payload, l.spot.symbol, l.after);
            p.assign (payload, l.spot.folder.id);
        } else {
            p.assign (payload, l.block != null ? l.block.folder.id : "");
        }
        changed ();
    }

    // A stock's tile: its logo, its symbol, its change and its name, stacked and centered. The name is
    // what says which company 8306.T is, so it stays: it wraps onto two lines, is cut with an ellipsis
    // beyond that, and the text shrinks before anything is left out. The logo comes along where there
    // is room for it with the text no more than two steps down; it is not worth smaller text than that.
    // Only a tile too low for three lines of the smallest text loses the name, and then the change.
    void label (Cairo.Context cr, Tile t) {
        double fit = double.min (t.w / 8, t.h / 4).clamp (7, 26), inner = t.w - 10;
        double mark = (double.min (t.w, t.h) * 0.2).clamp (18, 40);
        bool named = t.name != "" && t.name != t.symbol;
        var image = logos[t.symbol];
        double[] scales = { 1, 0.8, 0.64, 1, 0.8, 0.64, 0.5 };   // the first three are tried with the logo
        for (int parts = named ? 3 : 2; parts >= 1; parts--) {
            for (int k = image != null ? 0 : 3; k < scales.length; k++) {
                bool with_logo = k < 3;
                double size = double.max (fit * scales[k], 6);
                Pango.Layout[] rows = { text_layout (this, "<span font_desc='Bold %.1f'>%s</span>".printf (size, Markup.escape_text (t.symbol)), true, inner, 1) };
                if (parts >= 2) rows += text_layout (this, "<span font_desc='%.1f'>%s</span>".printf (size * 0.75, pct (t.change)), true, inner, 1);
                if (parts >= 3) rows += text_layout (this, "<span font_desc='%.1f' alpha='75%%'>%s</span>".printf (size * 0.5 + 3, Markup.escape_text (t.name)), true, inner, 2);
                int total = with_logo ? (int) mark + 6 : 0, w, h;
                foreach (var row in rows) {
                    row.get_pixel_size (out w, out h);
                    total += h;
                }
                if (total > t.h - 6) continue;
                double y = t.y + (t.h - total) / 2;
                if (with_logo) {
                    badge (cr, image, t.x + (t.w - mark) / 2, y, mark);
                    y += mark + 6;
                    cr.set_source_rgb (1, 1, 1);
                }
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

    // The stock's tile under a point, if any.
    Tile? leaf_at (double x, double y) {
        for (int i = 0; i < tiles.length; i++) if (tiles[i].kind != TileKind.GROUP && tiles[i].covers (x, y)) return tiles[i];
        return null;
    }

    // The innermost folder's tile under a point, if any; with `skip`, leaving that folder and what is
    // in it out of account. (A folder comes after the ones it is in, so the last match is innermost.)
    Tile? block_at (double x, double y, Group? skip) {
        for (int i = tiles.length - 1; i >= 0; i--) {
            var t = tiles[i];
            if (t.kind == TileKind.GROUP && t.covers (x, y) && (skip == null || !t.folder.within (skip))) return t;
        }
        return null;
    }

    // The folder whose gear, at the end of its label, is under a point.
    Tile? gear_at (double x, double y) {
        var b = block_at (x, y, null);
        return b != null && geared (b) && y < b.y + double.min (Portfolio.GROUP_HEADER, b.h / 3) && x >= b.x + b.w - GEAR ? b : null;
    }

    // Whether a folder's label has the room for a gear.
    bool geared (Tile b) { return b.w > 70 && b.h > 3 * 14; }

    // The pinned folder whose divider, the edge it shares with the rest, is under a point.
    Tile? divider_at (double x, double y) {
        for (int i = tiles.length - 1; i >= 0; i--) {
            var t = tiles[i];
            if (t.kind != TileKind.GROUP || t.folder.dock == Dock.FLOW) continue;
            bool across = t.folder.dock == Dock.TOP || t.folder.dock == Dock.BOTTOM;
            double edge = t.y + t.h;
            if (t.folder.dock == Dock.BOTTOM) edge = t.y;
            if (t.folder.dock == Dock.LEFT) edge = t.x + t.w;
            if (t.folder.dock == Dock.RIGHT) edge = t.x;
            if (across && Math.fabs (y - edge) < 4 && x >= t.x && x < t.x + t.w) return t;
            if (!across && Math.fabs (x - edge) < 4 && y >= t.y && y < t.y + t.h) return t;
        }
        return null;
    }

    // A gear centred on (x, y). Drawn by hand: GTK's icons can't be had from a cairo draw function, and
    // the character for one comes out in whichever font the system falls back to, emoji included.
    void gear (Cairo.Context cr, double x, double y, double r) {
        cr.save ();
        cr.translate (x, y);
        cr.set_line_width (r * 0.5);
        for (int i = 0; i < 8; i++) {
            cr.move_to (r * 0.6, 0);
            cr.line_to (r, 0);
            cr.rotate (Math.PI / 4);
        }
        cr.stroke ();
        cr.set_line_width (r * 0.36);
        cr.arc (0, 0, r * 0.55, 0, 2 * Math.PI);
        cr.stroke ();
        cr.restore ();
    }

    // A thick white edge on the side of a tile something would land on: top and left for before it,
    // bottom and right for after.
    void mark (Cairo.Context cr, Tile t, bool after) {
        double x = after ? t.x + t.w - 3 : t.x + 3, y = after ? t.y + t.h - 3 : t.y + 3;
        cr.move_to (x, t.y + 3);
        cr.line_to (x, t.y + t.h - 3);
        cr.move_to (t.x + 3, y);
        cr.line_to (t.x + t.w - 3, y);
        cr.stroke ();
    }

    void paint (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        tiles = p.tiles (range, now_s (), width, height);
        bool any_held = false;
        for (int i = 0; i < tiles.length; i++) any_held |= tiles[i].kind != TileKind.GROUP && tiles[i].value > 0;
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            cr.save ();
            cr.rectangle (t.clip.x, t.clip.y, t.clip.w, t.clip.h);   // all of the heatmap, unless it is in a strip that scrolls
            cr.clip ();
            draw (cr, t, any_held);
            cr.restore ();
        }
        // Where a dragged thing would land.
        if (landing == null) return;
        cr.set_source_rgb (1, 1, 1);
        cr.set_line_width (5);
        if (landing.dock != Dock.FLOW) {
            // Pinned: along that edge of the heatmap.
            bool across = landing.dock == Dock.TOP || landing.dock == Dock.BOTTOM;
            double x = landing.dock == Dock.RIGHT ? width - 3 : 3, y = landing.dock == Dock.BOTTOM ? height - 3 : 3;
            cr.move_to (x, y);
            cr.line_to (across ? width - 3 : x, across ? y : height - 3);
            cr.stroke ();
        } else if (landing.spot != null) {
            mark (cr, landing.spot, landing.after);
        } else if (landing.beside) {
            mark (cr, landing.block, landing.after);
        } else if (landing.block != null) {
            cr.rectangle (landing.block.x + 3, landing.block.y + 3, landing.block.w - 6, landing.block.h - 6);
            cr.stroke ();
        } else {
            cr.rectangle (3, 3, width - 6, height - 6);
            cr.stroke ();
        }
    }

    void draw (Cairo.Context cr, Tile t, bool any_held) {
        var symbol = Markup.escape_text (t.symbol), name = Markup.escape_text (t.name);
        if (t.kind == TileKind.GROUP) {
            // A folder: a dark card laid behind what is in it (which comes next in the list and is set
            // in from its edges), so it shows as a frame around them with a band across the top:
            // its name, their average move, and a gear for its settings.
            double head = double.min (Portfolio.GROUP_HEADER, t.h / 3);
            cr.set_source_rgb (0.13, 0.14, 0.17);
            cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
            cr.fill ();
            cr.set_source_rgb (1, 1, 1);
            string[] labels = { "<b>%s</b>   %s".printf (symbol, pct (t.change)), "<b>%s</b>".printf (symbol) };
            foreach (var markup in labels)
                if (draw_text (this, cr, "<span font_desc='9'>%s</span>".printf (markup), t.x + 8, t.y + head / 2, 0, 0.5, t.w - 14 - (geared (t) ? GEAR : 0), head)) break;
            cr.set_source_rgba (1, 1, 1, 0.65);
            if (geared (t)) gear (cr, t.x + t.w - GEAR / 2 - 1, t.y + head / 2, 5.5);
            return;
        }
        heat (cr, t.change, range);
        cr.rectangle (t.x + 1, t.y + 1, t.w - 2, t.h - 2);
        cr.fill ();
        if (charts) chart (cr, t);
        if (any_held && t.value <= 0 && t.folder.arrange == Arrange.VALUE) {
            // Watched, among tiles sized by what they are worth: a dashed outline says this one's size isn't money.
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
            return;
        }
        // An index or a currency pair that is only watched is known by its name and its level, not by
        // Yahoo's ticker for it; show as much as fits.
        double size = double.min (t.w / 11, t.h / 3.6).clamp (7, 15);
        var level = "<span font_desc='%.0f'>%s   %s</span>".printf (size * 0.85, money (t.price, t.currency), pct (t.change));
        string[] fits = {
            "<span font_desc='Bold %.0f'>%s</span>\n%s".printf (size, name, level),
            "<span font_desc='Bold %.0f'>%s</span>\n%s".printf (size, symbol, level),
            "<span font_desc='Bold %.0f'>%s</span>\n<span font_desc='%.0f'>%s</span>".printf (size, symbol, size * 0.85, pct (t.change)),
            "<span font_desc='Bold %.0f'>%s</span>".printf (size, symbol)
        };
        foreach (var markup in fits) {
            var text = text_layout (this, markup, true);
            int w, h;
            text.get_pixel_size (out w, out h);
            if (w > t.w - 10 || h > t.h - 6) continue;
            cr.move_to (t.x + (t.w - w) / 2, t.y + (t.h - h) / 2);
            Pango.cairo_show_layout (cr, text);
            // Its logo just to the left of the text, if the tile is wide enough to spare the room.
            var image = logos[t.symbol];
            if (image != null && (t.w - w) / 2 >= 24 + 14) badge (cr, image, t.x + (t.w - w) / 2 - 24 - 8, t.y + (t.h - 24) / 2, 24);
            break;
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
