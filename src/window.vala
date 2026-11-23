// The window: the table of tracked stocks and its chart, the two heatmap pages, and the add-stock dialog.
namespace Stonks {

const string APP_ID = "io.github.igneous.Stonks";
const string[] CURRENCIES = { "USD", "EUR", "JPY", "KRW", "VND", "CNY", "HKD", "GBP" };
const string[] COLUMNS = { "Symbol", "Name", "Shares", "Bought", "Cost", "Price", "Cur", "Change", "Value", "Gain", "Annual" };
const int COL_CHANGE = 7;
const int COL_VALUE = 8;
const int COL_GAIN = 9;

public class Window : Adw.ApplicationWindow {
    Portfolio p = new Portfolio ();
    Feed feed = new Feed (new Cache (Path.build_filename (Environment.get_user_cache_dir (), "stonks", "cache.db")));
    Range range = Range.D1;
    string path = Path.build_filename (Environment.get_user_data_dir (), "stonks", "portfolio.json");
    GenericSet<string> loading = new GenericSet<string> (str_hash, str_equal);
    GenericSet<string> peeking = new GenericSet<string> (str_hash, str_equal);   // see peek()
    string updated = "";
    bool round_failed;   // a fetch failed since quotes last settled
    bool failing;        // ...and so did the round before: the outage has been announced already
    Adw.Toast? error_toast;

    Adw.ToastOverlay toasts = new Adw.ToastOverlay ();
    Gtk.Stack stack = new Gtk.Stack ();
    Gtk.Label status = new Gtk.Label ("") { css_classes = { "dim-label", "caption" } };
    Gtk.Box stats = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 40) { margin_start = 18, margin_end = 18, margin_top = 4 };
    Gtk.Label value_lbl;
    Gtk.Label day_lbl;
    Gtk.Label total_lbl;
    Gtk.Label cost_lbl;
    Gtk.Label chart_title = new Gtk.Label ("") { css_classes = { "heading" }, ellipsize = Pango.EllipsizeMode.END };
    Gtk.Label chart_change = new Gtk.Label ("") { css_classes = { "numeric" } };
    Gtk.Button back = new Gtk.Button.with_label ("Show portfolio") { css_classes = { "flat" }, hexpand = true, halign = Gtk.Align.END };
    Chart chart = new Chart ();
    Gtk.ColumnView view = new Gtk.ColumnView (null) { css_classes = { "data-table" } };
    Gtk.ColumnViewColumn[] columns = {};
    GenericArray<Gtk.ColumnViewCell> cells = new GenericArray<Gtk.ColumnViewCell> ();
    Gtk.SingleSelection selection;
    Treemap treemap;
    Matrix matrix;
    // Logos, by symbol: looked up once each (see want_logo) and then kept in the cache for good.
    HashTable<string, Gdk.Texture> logos = new HashTable<string, Gdk.Texture> (str_hash, str_equal);
    GenericSet<string> logo_seen = new GenericSet<string> (str_hash, str_equal);   // dealt with this session
    GenericArray<string> logo_queue = new GenericArray<string> ();                 // still to be fetched
    bool logo_busy;
    bool tile_charts = true;   // the heatmap's background charts; saved with the portfolio
    Gtk.ListBox folders = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, css_classes = { "boxed-list" } };
    string folders_shown = "";   // what the sidebar was last built from, see show_folders()

    public Window (Adw.Application app) {
        Object (application: app, title: "Stonks", default_width: 1240, default_height: 820);
        load ();
        // Start from what the cache holds, so the window is complete at once and works offline; sync()
        // then asks the feeds only for what is new. Two passes: the first reveals which FX pairs are needed.
        for (int pass = 0; pass < 2; pass++) {
            foreach (var symbol in p.wanted ()) {
                var q = p.quotes.contains (symbol) ? null : feed.cached (symbol);
                if (q != null) p.quotes[symbol] = q;
            }
        }

        // Header bar: add, page switcher, totals currency, refresh.
        var pages = new Adw.ViewStack ();
        var header = new Adw.HeaderBar () { title_widget = new Adw.ViewSwitcher () { stack = pages, policy = Adw.ViewSwitcherPolicy.WIDE } };
        header.pack_start (new Gtk.Button.from_icon_name ("list-add-symbolic") { action_name = "win.add", tooltip_text = "Add stock (Ctrl+N)" });
        var menu = new Menu ();
        menu.append ("Charts in Heatmap Tiles", "win.tile-charts");
        menu.append ("Reload Logos", "win.reload-logos");
        header.pack_end (new Gtk.MenuButton () { icon_name = "open-menu-symbolic", tooltip_text = "Main menu", primary = true, menu_model = menu });
        header.pack_end (new Gtk.Button.from_icon_name ("view-refresh-symbolic") { action_name = "win.refresh", tooltip_text = "Refresh (Ctrl+R)" });
        var currency = new Gtk.DropDown.from_strings (CURRENCIES) { tooltip_text = "Currency for totals" };
        for (uint i = 0; i < CURRENCIES.length; i++) if (CURRENCIES[i] == p.currency) currency.selected = i;
        p.currency = CURRENCIES[currency.selected];
        currency.notify["selected"].connect (() => {
            p.currency = CURRENCIES[currency.selected];
            save ();
            sync ();
            update ();
        });
        header.pack_end (currency);

        // Range selector, shared by the chart, the Change column and the treemap.
        var ranges = new Adw.ToggleGroup () { halign = Gtk.Align.CENTER };
        foreach (unowned string label in RANGE_LABELS) ranges.add (new Adw.Toggle () { label = label });
        ranges.notify["active"].connect (() => { range = (Range) ranges.active; update (); });
        var bar = new Gtk.CenterBox () { center_widget = ranges, end_widget = status, margin_start = 12, margin_end = 12, margin_bottom = 8 };

        // Stocks page: headline numbers (when something is held), chart, table.
        value_lbl = stat (stats, "Value");
        day_lbl = stat (stats, "Day");
        total_lbl = stat (stats, "Total gain");
        cost_lbl = stat (stats, "Cost basis");
        var chart_head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_start = 18, margin_end = 12, margin_top = 12, height_request = 34 };
        chart_head.append (chart_title);
        chart_head.append (chart_change);
        chart_head.append (back);
        back.clicked.connect (() => { selection.selected = Gtk.INVALID_LIST_POSITION; });

        for (int i = 0; i < COLUMNS.length; i++) add_column (i);
        var bin = new Gtk.SignalListItemFactory ();
        bin.setup.connect ((o) => {
            unowned var cell = (Gtk.ColumnViewCell) o;
            var button = new Gtk.Button.from_icon_name ("user-trash-symbolic") { css_classes = { "flat" }, tooltip_text = "Remove" };
            button.clicked.connect (() => remove_lot ((Lot) cell.item));
            cell.child = button;
        });
        view.append_column (new Gtk.ColumnViewColumn (null, bin));
        selection = new Gtk.SingleSelection (new Gtk.SortListModel (p.lots, view.sorter)) { autoselect = false, can_unselect = true };
        selection.selected = Gtk.INVALID_LIST_POSITION;
        selection.notify["selected-item"].connect (() => update ());   // a selected row charts that symbol
        view.model = selection;

        var stocks = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        stocks.append (stats);
        stocks.append (chart_head);
        stocks.append (chart);
        stocks.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        stocks.append (new Gtk.ScrolledWindow () { child = view, vexpand = true });

        // Heatmap page: the treemap, and a sidebar of folders that the header's toggle shows and hides.
        treemap = new Treemap (p) { margin_start = 12, margin_end = 12, margin_bottom = 12 };
        treemap.charts = tile_charts;
        treemap.dropped.connect ((payload, folder, target, after) => dropped (payload, folder, target, after));
        var side = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) { margin_start = 12, margin_end = 12, margin_bottom = 12 };
        side.append (new Gtk.CenterBox () {
            start_widget = new Gtk.Label ("Folders") { css_classes = { "heading" } },
            end_widget = new Gtk.Button.from_icon_name ("folder-new-symbolic") { action_name = "win.new-folder", tooltip_text = "New folder", css_classes = { "flat" } }
        });
        side.append (new Gtk.Label ("Arrange by dragging, here or on the heatmap: a stock onto a folder to file it, onto another stock to put it beside that one. Folders can be dragged into order too.") { wrap = true, xalign = 0, css_classes = { "dim-label", "caption" } });
        side.append (folders);
        var split = new Adw.OverlaySplitView () {
            sidebar = new Gtk.ScrolledWindow () { child = side, hscrollbar_policy = Gtk.PolicyType.NEVER },
            content = treemap, min_sidebar_width = 260, max_sidebar_width = 340
        };
        var toggle = new Gtk.ToggleButton () { icon_name = "sidebar-show-symbolic", tooltip_text = "Folders", active = true, visible = false };
        toggle.bind_property ("active", split, "show-sidebar", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
        header.pack_start (toggle);
        pages.notify["visible-child-name"].connect (() => { toggle.visible = pages.visible_child_name == "heatmap"; });

        matrix = new Matrix (p) { margin_start = 12, margin_end = 12, margin_bottom = 12, valign = Gtk.Align.START };
        pages.add_titled_with_icon (stocks, "stocks", "Stocks", "view-list-symbolic");
        pages.add_titled_with_icon (split, "heatmap", "Heatmap", "view-grid-symbolic");
        pages.add_titled_with_icon (new Gtk.ScrolledWindow () { child = matrix }, "performance", "Performance", "power-profile-performance-symbolic");

        var empty = new Adw.StatusPage () {
            title = "No stocks yet",
            description = "Add a stock to follow its price. Give it a share count and a buy date to see what that investment would be worth today.",
            child = new Gtk.Button.with_label ("Add stock") { action_name = "win.add", halign = Gtk.Align.CENTER, css_classes = { "pill", "suggested-action" } }
        };
        stack.add_named (empty, "empty");
        stack.add_named (pages, "main");
        var toolbar = new Adw.ToolbarView () { content = stack };
        toolbar.add_top_bar (header);
        toolbar.add_top_bar (bar);
        toasts.child = toolbar;
        content = toasts;

        var add = new SimpleAction ("add", null);
        add.activate.connect (() => add_dialog (null));
        add_action (add);
        var refresh = new SimpleAction ("refresh", null);
        refresh.activate.connect (() => sync (true, true));
        add_action (refresh);

        // The main menu.
        var charts = new SimpleAction.stateful ("tile-charts", null, new Variant.boolean (tile_charts));
        charts.activate.connect (() => {
            tile_charts = !tile_charts;
            charts.set_state (new Variant.boolean (tile_charts));
            treemap.charts = tile_charts;
            treemap.queue_draw ();
            save ();
        });
        add_action (charts);
        var reload_logos = new SimpleAction ("reload-logos", null);
        reload_logos.activate.connect (() => {
            // The one way a logo is ever fetched twice: because the user asked.
            feed.forget_logos ();
            logos.remove_all ();
            logo_seen.remove_all ();
            if (logo_queue.length > 0) logo_queue.remove_range (0, logo_queue.length);   // update() queues them all again
            treemap.clear_logos ();
            update ();
        });
        add_action (reload_logos);

        // Folder actions; the sidebar's menus carry the folder or stock they act on as the target.
        var new_folder = new SimpleAction ("new-folder", null);
        new_folder.activate.connect (() => folder_dialog (""));
        add_action (new_folder);
        var rename_folder = new SimpleAction ("rename-folder", VariantType.STRING);
        rename_folder.activate.connect ((name) => folder_dialog (name.get_string ()));
        add_action (rename_folder);
        var delete_folder = new SimpleAction ("delete-folder", VariantType.STRING);
        delete_folder.activate.connect ((name) => {
            p.rename_group (name.get_string (), "");   // its stocks become ungrouped; nothing is removed
            save ();
            update ();
        });
        add_action (delete_folder);
        var add_to = new SimpleAction ("add-to", VariantType.STRING);
        add_to.activate.connect ((name) => add_dialog (new Lot () { group = name.get_string () }));
        add_action (add_to);
        var move = new SimpleAction ("move", new VariantType ("(ss)"));
        move.activate.connect ((target) => {
            string symbol, folder;
            target.get ("(ss)", out symbol, out folder);
            file (symbol, folder);
        });
        add_action (move);

        // Dev aid, see the Makefile.
        var page = Environment.get_variable ("STONKS_VIEW");
        if (page != null) pages.visible_child_name = page;
        var r = Environment.get_variable ("STONKS_RANGE");
        if (r != null) ranges.active = int.parse (r);
        var row = Environment.get_variable ("STONKS_ROW");
        if (row != null) selection.selected = int.parse (row);

        update ();
        sync (true);
        feed.load_names.begin ();
        // ponytail: one request per symbol every two minutes. Yahoo publishes no limit for these
        // endpoints; lengthen this if a large portfolio starts drawing HTTP 429.
        Timeout.add_seconds (120, () => { sync (true); return Source.CONTINUE; });
    }

    Gtk.Label stat (Gtk.Box box, string caption) {
        var column = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        column.append (new Gtk.Label (caption) { xalign = 0, css_classes = { "caption", "dim-label" } });
        var number = new Gtk.Label ("—") { xalign = 0, css_classes = { "title-2", "numeric" } };
        column.append (number);
        box.append (column);
        return number;
    }

    // Green for gains, red for losses.
    void tint (Gtk.Label label, double v) {
        label.remove_css_class ("success");
        label.remove_css_class ("error");
        if (v > 0) label.add_css_class ("success");
        if (v < 0) label.add_css_class ("error");
    }

    void show_gain (Gtk.Label label, double gain, double capital, string currency) {
        label.label = capital > 0 ? "%s (%s)".printf (delta (gain, currency), pct (gain / capital)) : "—";
        tint (label, capital > 0 ? gain : 0);
    }

    // ---- stocks table ----

    // ponytail: one row per lot. Two buys of the same symbol are two rows (the heatmaps merge them);
    // group rows by symbol here if that gets noisy.
    void add_column (int col) {
        bool text_column = col <= 1 || col == 3 || col == 6;
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((o) => {
            var cell = (Gtk.ColumnViewCell) o;
            cell.child = new Gtk.Label (null) { xalign = text_column ? 0 : 1, ellipsize = Pango.EllipsizeMode.END, css_classes = { "numeric" } };
            cell.set_data<int> ("col", col);
            cells.add (cell);
        });
        factory.bind.connect ((o) => fill ((Gtk.ColumnViewCell) o));
        factory.teardown.connect ((o) => { cells.remove ((Gtk.ColumnViewCell) o); });
        var column = new Gtk.ColumnViewColumn (COLUMNS[col], factory) { expand = col == 1, resizable = true };
        column.sorter = new Gtk.CustomSorter ((a, b) => {
            double ka, kb;
            string ta = cell_text ((Lot) a, col, out ka), tb = cell_text ((Lot) b, col, out kb);
            if (ka.is_finite () && kb.is_finite ()) return ka < kb ? -1 : (ka > kb ? 1 : 0);
            if (ka.is_finite () || kb.is_finite ()) return ka.is_finite () ? 1 : -1;   // not loaded yet sorts first
            return strcmp (ta, tb);
        });
        view.append_column (column);
        columns += column;
    }

    void fill (Gtk.ColumnViewCell cell) {
        var lot = cell.item as Lot;
        if (lot == null) return;
        int col = cell.get_data<int> ("col");
        var label = (Gtk.Label) cell.child;
        double key;
        label.label = cell_text (lot, col, out key);
        if (col == COL_CHANGE || col >= COL_GAIN) tint (label, key);
    }

    // A cell's text, plus its number for sorting and coloring (NaN for text and not-yet-loaded cells).
    // Cost, Price and Change are the instrument's own; Value, Gain and Annual are in the totals currency.
    // A watched stock (no shares) leaves everything about a position blank.
    string cell_text (Lot l, int col, out double key) {
        key = double.NAN;
        var now = now_s ();
        var q = p.quotes[l.symbol];
        var own = q != null ? q.currency : "";
        bool held = l.shares > 0;
        switch (col) {
        case 0: return l.symbol;
        case 1: return q != null ? q.name : "";
        case 2: if (held) key = l.shares; return held ? "%.8g".printf (l.shares) : "";
        case 3: return held ? l.date : "";
        case 4: if (held) key = l.price; return held ? money (l.price, own) : "";
        case 5: if (q != null) key = q.price; return money (key, own);
        case 6: return own;
        case COL_CHANGE: if (q != null) key = q.change (range, now); return pct (key);
        }
        if (!held) return "";
        double gain, capital;
        if (!p.lot_gain (l, Range.MAX, now, out gain, out capital)) return "—";
        switch (col) {
        case COL_VALUE: key = capital + gain; return money (key, p.currency);
        case COL_GAIN: key = gain; return "%s (%s)".printf (delta (gain, p.currency), pct (gain / capital));
        default:
            double years = (now - l.ts (q.gmtoffset)) / (365.25 * 86400);
            if (years < 1) return "—";   // annualising a few months of return is noise
            key = Math.pow (1 + gain / capital, 1 / years) - 1;
            return pct (key);
        }
    }

    // ---- recompute everything on screen from the lots and quotes we have ----

    void update () {
        var now = now_s ();
        p.rebase ();
        stack.visible_child_name = p.lots.get_n_items () == 0 ? "empty" : "main";
        status.label = loading.length > 0 ? "Updating…" : updated;

        // With nothing held there is no portfolio to total or chart: hide the totals and chart a stock.
        bool held = false;
        for (uint i = 0; i < p.lots.get_n_items (); i++) held |= ((Lot) p.lots.get_item (i)).shares > 0;
        stats.visible = held;
        foreach (int col in new int[] { 2, 3, 4, COL_VALUE, COL_GAIN, COL_GAIN + 1 }) columns[col].visible = held;   // the position columns
        if (!held && selection.selected_item == null && selection.get_n_items () > 0) selection.selected = 0;

        double day, day_capital, total, cost, moved, moved_capital;
        p.gain (Range.D1, now, out day, out day_capital);
        p.gain (Range.MAX, now, out total, out cost);
        p.gain (range, now, out moved, out moved_capital);
        value_lbl.label = "%s %s".printf (money (cost + total, p.currency), p.currency);
        show_gain (day_lbl, day, day_capital, p.currency);
        show_gain (total_lbl, total, cost, p.currency);
        cost_lbl.label = money (cost, p.currency);

        var lot = selection.selected_item as Lot;
        var q = lot != null ? p.quotes[lot.symbol] : null;
        back.visible = lot != null && held;
        if (q != null) {
            double basis = q.basis (range, now);
            chart_title.label = "%s · %s · %s %s".printf (q.symbol, q.name, money (q.price, q.currency), q.currency);
            show_gain (chart_change, q.price - basis, basis, q.currency);
            chart.plot (q.view (range, now), basis, q.price >= basis, range, q.currency);
        } else {
            double opening;
            var history = p.history (range, now, out opening);
            chart_title.label = "Portfolio";
            show_gain (chart_change, moved, moved_capital, p.currency);
            chart.plot (history, opening > 0 ? opening : double.NAN, moved >= 0, range, p.currency);
        }

        columns[COL_CHANGE].title = "Chg " + RANGE_LABELS[range];
        columns[COL_VALUE].title = "Value " + p.currency;
        columns[COL_GAIN].title = "Gain " + p.currency;
        for (int i = 0; i < cells.length; i++) fill (cells[i]);
        view.sorter.changed (Gtk.SorterChange.DIFFERENT);   // prices moved: re-sort

        for (uint i = 0; i < p.lots.get_n_items (); i++) want_logo (((Lot) p.lots.get_item (i)).symbol);
        treemap.range = range;
        treemap.queue_draw ();
        matrix.refresh ();
        show_folders ();
    }

    // ---- logos ----

    // See to a symbol's logo, once its quote is in (the quote says what kind of thing it is): from the
    // cache if we ever looked, otherwise it joins the queue to be fetched.
    void want_logo (string symbol) {
        if (logo_seen.contains (symbol) || !p.quotes.contains (symbol)) return;
        logo_seen.add (symbol);
        bool known;
        var image = feed.cached_logo (symbol, out known);
        if (image != null) show_logo (symbol, image);
        if (known) return;
        logo_queue.add (symbol);
        fetch_logos.begin ();
    }

    // False if the bytes are not an image we can draw.
    bool show_logo (string symbol, Bytes image) {
        try {
            var texture = Gdk.Texture.from_bytes (image);
            logos[symbol] = texture;
            treemap.set_logo (symbol, texture);
            return true;
        } catch (Error e) {
            return false;
        }
    }

    // Fetch the logos still missing, one after another: there is no hurry, and the sites are not ours.
    async void fetch_logos () {
        if (logo_busy) return;
        logo_busy = true;
        while (logo_queue.length > 0) {
            string symbol = logo_queue[0];
            logo_queue.remove_index (0);
            var q = p.quotes[symbol];
            try {
                var image = yield feed.logo (symbol, q != null ? q.kind : "");
                if (image != null && !show_logo (symbol, image)) feed.no_logo (symbol);
                show_folders ();
            } catch (Error e) {
                // Couldn't find out (offline, say). Nothing was recorded, so the next launch asks again.
            }
        }
        logo_busy = false;
    }

    // ---- heatmap folders ----

    // Put a stock in a folder ("" for none): from the Move menu or the add dialog.
    void file (string symbol, string folder) {
        p.assign (symbol, folder);
        save ();
        update ();
    }

    // Something was dragged and dropped, in the sidebar or on the heatmap. A symbol goes into `folder`,
    // and beside `target` (before it, or after) if it was dropped on one. A payload of "folder:" and a
    // name is a folder being moved to just before `folder`.
    void dropped (string payload, string folder, string? target, bool after) {
        if (payload.has_prefix ("folder:")) {
            p.move_group (payload.substring (7), folder);
        } else {
            if (target != null) p.move (payload, target, after);
            p.assign (payload, folder);
        }
        save ();
        update ();
    }

    MenuItem menu_item (string label, string action, Variant target) {
        var item = new MenuItem (label, null);
        item.set_action_and_target_value (action, target);
        return item;
    }

    // The sidebar: each folder with the stocks filed in it, then the unfiled. Only stocks the heatmap
    // lays out in its body are listed; an index or currency pair sits in the top row whatever folder
    // it might be given. Rebuilt only when the arrangement changes, so a price refresh doesn't fold up
    // what is open.
    void show_folders () {
        var tiles = p.tiles (range, now_s (), 1, 1);
        var shape = new StringBuilder ();
        for (int i = 0; i < p.groups.length; i++) shape.append (p.groups[i] + "\n");
        for (int i = 0; i < tiles.length; i++)
            if (tiles[i].kind == TileKind.STOCK) shape.append ("%s\t%s\t%s\t%d\n".printf (tiles[i].symbol, tiles[i].group, tiles[i].name, (int) logos.contains (tiles[i].symbol)));
        if (shape.str == folders_shown) return;
        folders_shown = shape.str;
        folders.remove_all ();

        string[] names = {};
        for (int i = 0; i < p.groups.length; i++) names += p.groups[i];
        names += "";   // the unfiled, last
        foreach (var name in names) {
            var folder = new Adw.ExpanderRow () { use_markup = false, title = name != "" ? name : "Ungrouped", expanded = true };
            folder.add_prefix (new Gtk.Image.from_icon_name ("folder-symbolic"));
            // Drop a stock on the folder to file it here (its rows take drops themselves, to place it
            // among them); drop another folder on it to move that one to just before this.
            var drop = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
            drop.drop.connect ((value, x, y) => {
                var payload = value.get_string ();
                // Later, not from inside the drop: it rebuilds this very list.
                Idle.add (() => { dropped (payload, name, null, false); return Source.REMOVE; });
                return true;
            });
            folder.add_controller (drop);
            if (name != "") {
                var grab = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
                grab.prepare.connect ((x, y) => new Gdk.ContentProvider.for_value ("folder:" + name));
                folder.add_controller (grab);
            }
            if (name != "") {
                folder.add_suffix (new Gtk.Button.from_icon_name ("list-add-symbolic") {
                    tooltip_text = "Add a stock to this folder", valign = Gtk.Align.CENTER, css_classes = { "flat" },
                    action_name = "win.add-to", action_target = new Variant.string (name)
                });
                var actions = new Menu ();
                actions.append_item (menu_item ("Rename…", "win.rename-folder", new Variant.string (name)));
                actions.append_item (menu_item ("Delete", "win.delete-folder", new Variant.string (name)));
                folder.add_suffix (new Gtk.MenuButton () { icon_name = "view-more-symbolic", valign = Gtk.Align.CENTER, css_classes = { "flat" }, menu_model = actions });
            }
            int count = 0;
            for (int i = 0; i < tiles.length; i++) {
                var t = tiles[i];
                if (t.kind != TileKind.STOCK || t.group != name) continue;
                var targets = new Menu ();
                for (int k = 0; k < p.groups.length; k++)
                    if (p.groups[k] != name) targets.append_item (menu_item (p.groups[k], "win.move", new Variant ("(ss)", t.symbol, p.groups[k])));
                if (name != "") targets.append_item (menu_item ("Ungrouped", "win.move", new Variant ("(ss)", t.symbol, "")));
                var destinations = new Menu ();
                destinations.append_section ("Move to", targets);
                var row = new Adw.ActionRow () { use_markup = false, title = t.symbol, subtitle = t.name, subtitle_lines = 1 };
                if (logos.contains (t.symbol)) row.add_prefix (new Gtk.Image.from_paintable (logos[t.symbol]) { pixel_size = 24 });
                // Drag the row onto a folder here, or onto a folder's block in the heatmap.
                var drag = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
                unowned Gtk.DragSource source = drag;   // unowned, or the handler below would keep
                unowned Adw.ActionRow shown = row;      // both alive after the list is rebuilt
                drag.prepare.connect ((x, y) => new Gdk.ContentProvider.for_value (t.symbol));
                drag.drag_begin.connect ((d) => { source.set_icon (new Gtk.WidgetPaintable (shown), 0, 0); });
                row.add_controller (drag);
                // Dropped on this row: beside this stock, above or below by which half was hit.
                var beside = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
                beside.drop.connect ((value, x, y) => {
                    var payload = value.get_string ();
                    bool after = y > shown.get_height () / 2;
                    if (payload == t.symbol) return false;
                    Idle.add (() => { dropped (payload, name, t.symbol, after); return Source.REMOVE; });
                    return true;
                });
                row.add_controller (beside);
                row.add_suffix (new Gtk.MenuButton () {
                    icon_name = "folder-symbolic", tooltip_text = "Move to folder", valign = Gtk.Align.CENTER,
                    css_classes = { "flat" }, menu_model = destinations, sensitive = targets.get_n_items () > 0
                });
                folder.add_row (row);
                count++;
            }
            // Spelled out with ifs: valac 0.56 frees the inner result of a nested ?: over strings too early.
            folder.subtitle = "Empty";
            if (count == 1) folder.subtitle = "1 stock";
            if (count > 1) folder.subtitle = @"$count stocks";
            // Ungrouped stays listed while there are folders, so there is somewhere to drag a stock back out to.
            if (name != "" || count > 0 || p.groups.length > 0) folders.append (folder);
        }
    }

    // Name a new folder (old = "") or rename an existing one.
    void folder_dialog (string old) {
        var entry = new Gtk.Entry () { text = old, activates_default = true };
        var dialog = new Adw.AlertDialog (old == "" ? "New folder" : "Rename folder", null) { extra_child = entry, default_response = "ok", close_response = "cancel" };
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("ok", old == "" ? "Create" : "Rename");
        dialog.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
        dialog.response.connect ((id) => {
            var name = entry.text.strip ();
            if (id != "ok" || name == "" || p.groups.find_with_equal_func (name, str_equal)) return;   // also covers "unchanged"
            if (old == "") p.groups.add (name); else p.rename_group (old, name);
            save ();
            update ();
        });
        dialog.present (this);
    }

    // ---- quotes ----

    // Load quotes for everything we track or convert through. `all` also refreshes the ones we already
    // have, but only those that are due (see Quote.due); `force` refreshes them regardless.
    void sync (bool all = false, bool force = false) {
        var now = now_s ();
        foreach (var symbol in p.wanted ()) {
            var q = p.quotes[symbol];
            // A pair we only convert totals through needn't be to the minute: a quarter of an hour will do.
            bool due = q != null && (p.tracks (symbol) ? q.due (now) : now - q.refreshed >= 900);
            if (!loading.contains (symbol) && (q == null || (all && (force || due)))) load_symbol.begin (symbol);
        }
    }

    // `asked`: the user is waiting on this symbol, so always say why it failed.
    async void load_symbol (string symbol, bool asked = false) {
        loading.add (symbol);
        status.label = "Updating…";
        try {
            var q = p.quotes[symbol];
            bool known = q != null;
            if (q == null) {
                q = feed.cached (symbol);
                if (q != null) p.quotes[symbol] = q;   // shown as it was, even if the refresh below fails
            }
            if (q == null) p.quotes[symbol] = yield feed.download (symbol);
            else yield feed.refresh (q);
            if (!known) sync ();   // a new holding can need FX pairs we don't have yet
        } catch (Error e) {
            if (asked || !failing) fail (@"$symbol: $(e.message)");   // background refreshes report an outage once
            if (!asked) round_failed = true;
        }
        loading.remove (symbol);
        if (loading.length == 0) {
            updated = new DateTime.now_local ().format (round_failed ? "Update failed %H:%M" : "Updated %H:%M");
            failing = round_failed;
            round_failed = false;
            var shot = Environment.get_variable ("STONKS_SHOT");
            if (shot != null) Timeout.add (1500, () => { snapshot_to (shot); return Source.REMOVE; });
        }
        update ();
    }

    // Dev aid, see the Makefile: render the window to a PNG and quit.
    void snapshot_to (string file) {
        var snapshot = new Gtk.Snapshot ();
        new Gtk.WidgetPaintable (this).snapshot (snapshot, get_width (), get_height ());
        get_renderer ().render_texture (snapshot.to_node (), null).save_to_png (file);
        close ();
    }

    // One error toast at a time: being offline would otherwise queue one per symbol.
    void fail (string message) {
        if (error_toast != null) return;
        error_toast = new Adw.Toast (message) { timeout = 8 };
        error_toast.dismissed.connect (() => { error_toast = null; });
        toasts.add_toast (error_toast);
    }

    // ---- adding and removing stocks ----

    void add_dialog (Lot? draft) {
        var symbol = new Adw.EntryRow () { title = "Symbol or company name", activates_default = true };
        var shares = new Adw.EntryRow () { title = "Shares", activates_default = true };
        var date = new Adw.EntryRow () { title = "Buy date (YYYY-MM-DD)", activates_default = true };
        var price = new Adw.EntryRow () { title = "Price per share", activates_default = true };
        var calendar = new Gtk.Calendar ();
        calendar.day_selected.connect (() => { date.text = calendar.get_date ().format ("%Y-%m-%d"); });
        date.add_suffix (new Gtk.MenuButton () {
            icon_name = "x-office-calendar-symbolic", tooltip_text = "Pick a date", valign = Gtk.Align.CENTER,
            css_classes = { "flat" }, popover = new Gtk.Popover () { child = calendar }
        });
        var hits = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, css_classes = { "boxed-list" }, visible = false, margin_top = 12 };

        var stock = new Adw.PreferencesGroup () {
            title = "Stock",
            description = "Search by name or ticker: AAPL, 7203.T, 005930.KS, 600519.SS, or PVS.VN for any Vietnamese exchange."
        };
        stock.add (symbol);
        stock.add (hits);
        var position = new Adw.PreferencesGroup () {
            title = "Position",
            description = "Optional. Leave Shares empty to just follow the stock."
        };
        position.add (shares);
        position.add (date);
        position.add (price);
        // Optional too: file it in a heatmap folder straight away. Row 0 is "None".
        var choices = new Gtk.StringList (null);
        choices.append ("None");
        for (int i = 0; i < p.groups.length; i++) choices.append (p.groups[i]);
        var folder = new Adw.ComboRow () { title = "Folder", subtitle = "Where it sits on the heatmap", model = choices };
        for (int i = 0; draft != null && i < p.groups.length; i++) if (p.groups[i] == draft.group) folder.selected = i + 1;
        var filing = new Adw.PreferencesGroup () { visible = p.groups.length > 0 };
        filing.add (folder);
        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 24) { margin_top = 12, margin_bottom = 24, margin_start = 24, margin_end = 24 };
        form.append (stock);
        form.append (position);
        form.append (filing);

        var add = new Gtk.Button.with_label ("Add") { css_classes = { "suggested-action" }, sensitive = false };
        var cancel = new Gtk.Button.with_label ("Cancel");
        var bar = new Adw.HeaderBar () { show_start_title_buttons = false, show_end_title_buttons = false };
        bar.pack_start (cancel);
        bar.pack_end (add);
        var body = new Adw.ToolbarView () { content = new Gtk.ScrolledWindow () { child = form, hscrollbar_policy = Gtk.PolicyType.NEVER } };
        body.add_top_bar (bar);
        // A fixed size: wide enough for a security's full name, and no jumping about as results come and go.
        var dialog = new Adw.Dialog () { title = "Add stock", content_width = 760, content_height = 660, child = body, default_widget = add };

        // Symbol search as you type; `serial` drops answers to anything but the latest keystroke.
        uint serial = 0;
        string picked = "";
        symbol.changed.connect (() => {
            uint mine = ++serial;
            var text = symbol.text.strip ();
            // A different stock: the price filled in for the last one no longer applies.
            if (price.text != "" && price.text == price.get_data<string> ("auto")) price.text = "";
            price.title = "Price per share";
            if (text == picked || text.length < 2) {
                hits.visible = false;
                return;
            }
            Timeout.add (250, () => {
                if (mine == serial) feed.search.begin (text, p.currency, (obj, res) => {
                    var found = feed.search.end (res);
                    if (mine != serial) return;
                    hits.remove_all ();
                    foreach (var hit in found) {
                        var row = new Adw.ActionRow () { use_markup = false, title = hit.symbol, subtitle = hit.name + "\n" + hit.detail, activatable = true };
                        // On the right: the price now and, where there is one, the market cap.
                        if (hit.price.is_finite ()) {
                            // In its own currency, then (if that isn't ours and we know the rate) in ours.
                            var numbers = price_text (hit.price, hit.currency);
                            if (hit.rate.is_finite ()) numbers += " (%s)".printf (price_text (hit.price * hit.rate, p.currency));
                            if (hit.cap.is_finite ()) {
                                var cap = compact (hit.cap);
                                if (hit.rate.is_finite ()) cap += " (%s %s)".printf (compact (hit.cap * hit.rate), p.currency);
                                numbers += "\n<span alpha='65%%'><small>Mkt cap %s</small></span>".printf (cap);
                            }
                            row.add_suffix (new Gtk.Label (numbers) { use_markup = true, xalign = 1, justify = Gtk.Justification.RIGHT, css_classes = { "numeric" } });
                        }
                        hits.append (row);
                    }
                    hits.visible = found.length > 0;
                });
                return Source.REMOVE;
            });
        });
        hits.row_activated.connect ((row) => {
            picked = ((Adw.ActionRow) row).title;
            symbol.text = picked;
            shares.grab_focus ();
            autofill (symbol, date, price);
        });
        shares.changed.connect (() => autofill (symbol, date, price));
        date.changed.connect (() => autofill (symbol, date, price));

        // Add stays disabled until the form parses; `lot` always holds the latest valid reading.
        // No shares means a stock to watch, so the rest of the position is switched off and ignored.
        var lot = new Lot ();
        Adw.EntryRow[] rows = { symbol, shares, date, price };
        foreach (var row in rows) row.changed.connect (() => {
            double n = 0, cost = 0;
            string s = symbol.text.strip ().up (), d = date.text.strip (), c = price.text.strip ();
            bool watching = shares.text.strip () == "";
            var day = new DateTime.from_iso8601 (d + "T00:00:00Z", null);
            bool n_ok = watching || (double.try_parse (shares.text.strip (), out n) && n > 0 && n.is_finite ());
            bool d_ok = watching || (d.length == 10 && day != null && day.compare (new DateTime.now_utc ().add_days (1)) < 0);
            bool c_ok = watching || c == "" || (double.try_parse (c, out cost) && cost > 0 && cost.is_finite ());
            mark (shares, n_ok);
            mark (date, d_ok);
            mark (price, c_ok);
            date.sensitive = price.sensitive = !watching;
            add.sensitive = s != "" && n_ok && d_ok && c_ok;
            lot.symbol = s;
            lot.shares = watching ? 0 : n;
            lot.date = watching ? "" : d;
            lot.price = watching ? 0 : cost;
        });
        if (draft != null) symbol.text = draft.symbol;
        date.text = draft != null && draft.shares > 0 ? draft.date : new DateTime.now_local ().format ("%Y-%m-%d");
        if (draft != null && draft.shares > 0) shares.text = "%.8g".printf (draft.shares);
        cancel.clicked.connect (() => { dialog.close (); });
        add.clicked.connect (() => {
            lot.group = folder.selected > 0 ? p.groups[(int) folder.selected - 1] : "";
            dialog.close ();
            add_lot.begin (lot);
        });
        dialog.present (this);
    }

    // "264.00 USD". Penny stocks and small coins would all read 0.00 at two decimals, so they get four digits.
    string price_text (double price, string currency) {
        var number = "%.4g".printf (price);
        if (price >= 1) number = money (price, currency);
        return @"$number $currency";
    }

    void mark (Adw.EntryRow row, bool ok) {
        if (ok) row.remove_css_class ("error"); else row.add_css_class ("error");
    }

    // The quote for a symbol still being filled in on the form: the one we have, or fetched without
    // complaint if that fails (Add will say why). Null while another peek for it is on its way.
    async Quote? peek (string symbol) {
        if (p.quotes.contains (symbol) || peeking.contains (symbol)) return p.quotes[symbol];
        var kept = feed.cached (symbol);   // good enough to price a past date; sync() freshens it once added
        if (kept != null) {
            p.quotes[symbol] = kept;
            return kept;
        }
        peeking.add (symbol);
        try { p.quotes[symbol] = yield feed.download (symbol); } catch (Error e) {}
        peeking.remove (symbol);
        return p.quotes[symbol];
    }

    // Put the close on the buy date into the price row, unless the user has typed a price of their own.
    // The row remembers what was filled in ("auto") so a later date change can replace it.
    void autofill (Adw.EntryRow symbol, Adw.EntryRow date, Adw.EntryRow price) {
        var asked = symbol.text.strip ().up ();
        if (asked == "") return;
        peek.begin (asked, (obj, res) => {
            var q = peek.end (res);
            var day = new DateTime.from_iso8601 (date.text.strip () + "T00:00:00Z", null);
            // Read the form now, not when we asked: it may have moved on while the quote loaded.
            if (q == null || day == null || date.text.strip ().length != 10 || symbol.text.strip ().up () != asked) return;
            if (price.text != "" && price.text != price.get_data<string> ("auto")) return;
            var close = "%.8g".printf (q.daily.v[q.bar (day.to_unix () - q.gmtoffset)]);
            price.set_data<string> ("auto", close);
            price.text = close;
            price.title = @"Price per share ($(q.currency))";
        });
    }

    async void add_lot (Lot lot) {
        if (!p.quotes.contains (lot.symbol)) yield load_symbol (lot.symbol, true);
        var q = p.quotes[lot.symbol];
        if (q == null) {
            add_dialog (lot);   // load_symbol already said why; let them fix the symbol
            return;
        }
        // A stock is listed once unless it's bought more than once: a purchase takes over the stock's
        // watch-only row, and watching something already listed changes nothing but its folder.
        var chosen = lot.group;
        for (uint i = 0; i < p.lots.get_n_items (); i++) {
            var other = (Lot) p.lots.get_item (i);
            if (other.symbol != lot.symbol) continue;
            if (chosen == "") lot.group = other.group;   // a symbol has one folder: without a new choice, the one it has
            if (lot.shares <= 0) {
                if (chosen != "" && chosen != other.group) file (lot.symbol, chosen);
                else toasts.add_toast (new Adw.Toast (@"$(lot.symbol) is already listed"));
                return;
            }
            if (other.shares <= 0) {
                p.lots.remove (i);
                break;
            }
        }
        if (lot.shares > 0 && lot.price <= 0) lot.price = q.daily.v[q.bar (lot.ts (q.gmtoffset))];
        p.lots.append (lot);
        if (chosen != "") p.assign (lot.symbol, chosen);   // earlier lots of it follow
        save ();
        sync ();
        update ();
    }

    void remove_lot (Lot lot) {
        uint at;
        if (!p.lots.find (lot, out at)) return;
        p.lots.remove (at);
        save ();
        update ();
        var toast = new Adw.Toast (@"Removed $(lot.symbol)") { button_label = "Undo" };
        toast.button_clicked.connect (() => {
            p.lots.insert (uint.min (at, p.lots.get_n_items ()), lot);
            save ();
            update ();
        });
        toasts.add_toast (toast);
    }

    // ---- persistence: ~/.local/share/stonks/portfolio.json ----

    void load () {
        string text;
        try { FileUtils.get_contents (path, out text); } catch (Error e) { return; }   // first run
        try {
            var node = Json.from_string (text);
            if (node == null || node.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA ("not a portfolio");
            var saved = node.get_object ();
            p.currency = saved.get_string_member_with_default ("currency", "USD");
            tile_charts = saved.get_boolean_member_with_default ("tile_charts", true);
            saved.get_array_member ("lots").foreach_element ((array, i, lot) => {
                if (lot.get_node_type () == Json.NodeType.OBJECT) p.lots.append (Json.gobject_deserialize (typeof (Lot), lot));
            });
            if (saved.has_member ("groups")) saved.get_array_member ("groups").foreach_element ((array, i, name) => {
                if (name.get_node_type () == Json.NodeType.VALUE && name.get_string () != null) p.groups.add (name.get_string ());
            });
            // A folder some lot names but the list forgot (a hand-edited file) still exists.
            for (uint i = 0; i < p.lots.get_n_items (); i++) {
                var group = ((Lot) p.lots.get_item (i)).group;
                if (group != "" && !p.groups.find_with_equal_func (group, str_equal)) p.groups.add (group);
            }
        } catch (Error e) {
            // Move it aside so the next save can't overwrite a file we failed to read.
            FileUtils.rename (path, path + ".bad");
            fail (@"Couldn't read the saved portfolio; kept it as $path.bad");
        }
    }

    void save () {
        var lots = new Json.Array ();
        for (uint i = 0; i < p.lots.get_n_items (); i++) lots.add_element (Json.gobject_serialize (p.lots.get_item (i)));
        var saved = new Json.Object ();
        var groups = new Json.Array ();
        for (int i = 0; i < p.groups.length; i++) groups.add_string_element (p.groups[i]);
        saved.set_string_member ("currency", p.currency);
        saved.set_boolean_member ("tile_charts", tile_charts);
        saved.set_array_member ("groups", groups);
        saved.set_array_member ("lots", lots);
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (saved);
        try {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            FileUtils.set_contents (path, Json.to_string (node, true));   // atomic: temp file + rename
        } catch (Error e) {
            fail (@"Couldn't save the portfolio: $(e.message)");
        }
    }
}

int main (string[] args) {
    // A screenshot run (dev aid, see the Makefile) must not just raise the copy the user has open.
    bool shot = Environment.get_variable ("STONKS_SHOT") != null;
    var app = new Adw.Application (APP_ID, shot ? ApplicationFlags.NON_UNIQUE : ApplicationFlags.DEFAULT_FLAGS);
    app.activate.connect (() => {
        var window = app.active_window ?? new Window (app);
        window.present ();
    });
    app.set_accels_for_action ("win.add", { "<Ctrl>n" });
    app.set_accels_for_action ("win.refresh", { "<Ctrl>r", "F5" });
    app.set_accels_for_action ("window.close", { "<Ctrl>w", "<Ctrl>q" });
    return app.run (args);
}

}
