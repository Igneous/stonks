// The window: holdings table and chart, the two heatmap pages, and the add-position dialog.
namespace Stonks {

const string APP_ID = "io.github.igneous.Stonks";
const string[] CURRENCIES = { "USD", "EUR", "JPY", "KRW", "VND", "CNY", "HKD", "GBP" };
const string[] COLUMNS = { "Symbol", "Name", "Shares", "Bought", "Cost", "Price", "Cur", "Change", "Value", "Gain", "Annual" };
const int COL_CHANGE = 7;
const int COL_VALUE = 8;
const int COL_GAIN = 9;

public class Window : Adw.ApplicationWindow {
    Portfolio p = new Portfolio ();
    Yahoo yahoo = new Yahoo ();
    Range range = Range.D1;
    string path = Path.build_filename (Environment.get_user_data_dir (), "stonks", "portfolio.json");
    GenericSet<string> loading = new GenericSet<string> (str_hash, str_equal);
    string updated = "";
    Adw.Toast? error_toast;

    Adw.ToastOverlay toasts = new Adw.ToastOverlay ();
    Gtk.Stack stack = new Gtk.Stack ();
    Gtk.Label status = new Gtk.Label ("") { css_classes = { "dim-label", "caption" } };
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

    public Window (Adw.Application app) {
        Object (application: app, title: "Stonks", default_width: 1240, default_height: 820);
        load ();

        // Header bar: add, page switcher, totals currency, refresh.
        var pages = new Adw.ViewStack ();
        var header = new Adw.HeaderBar () { title_widget = new Adw.ViewSwitcher () { stack = pages, policy = Adw.ViewSwitcherPolicy.WIDE } };
        header.pack_start (new Gtk.Button.from_icon_name ("list-add-symbolic") { action_name = "win.add", tooltip_text = "Add position (Ctrl+N)" });
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

        // Holdings page: headline numbers, chart, table.
        var stats = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 40) { margin_start = 18, margin_end = 18, margin_top = 4 };
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

        var holdings = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        holdings.append (stats);
        holdings.append (chart_head);
        holdings.append (chart);
        holdings.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        holdings.append (new Gtk.ScrolledWindow () { child = view, vexpand = true });

        treemap = new Treemap (p) { margin_start = 12, margin_end = 12, margin_bottom = 12 };
        matrix = new Matrix (p) { margin_start = 12, margin_end = 12, margin_bottom = 12, valign = Gtk.Align.START };
        pages.add_titled_with_icon (holdings, "holdings", "Holdings", "view-list-symbolic");
        pages.add_titled_with_icon (treemap, "heatmap", "Heatmap", "view-grid-symbolic");
        pages.add_titled_with_icon (new Gtk.ScrolledWindow () { child = matrix }, "performance", "Performance", "power-profile-performance-symbolic");

        var empty = new Adw.StatusPage () {
            title = "No positions yet",
            description = "Add a ticker, a share count and a buy date to see what that investment would be worth today.",
            child = new Gtk.Button.with_label ("Add position") { action_name = "win.add", halign = Gtk.Align.CENTER, css_classes = { "pill", "suggested-action" } }
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

        // Dev aid, see the Makefile.
        var page = Environment.get_variable ("STONKS_VIEW");
        if (page != null) pages.visible_child_name = page;
        var r = Environment.get_variable ("STONKS_RANGE");
        if (r != null) ranges.active = int.parse (r);

        update ();
        sync (true);
        Timeout.add_seconds (60, () => { sync (true); return Source.CONTINUE; });
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

    void show_gain (Gtk.Label label, double gain, double capital) {
        label.label = capital > 0 ? "%s (%s)".printf (delta (gain), pct (gain / capital)) : "—";
        tint (label, capital > 0 ? gain : 0);
    }

    // ---- holdings table ----

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
    string cell_text (Lot l, int col, out double key) {
        key = double.NAN;
        var now = now_s ();
        var q = p.quotes[l.symbol];
        switch (col) {
        case 0: return l.symbol;
        case 1: return q != null ? q.name : "";
        case 2: key = l.shares; return "%.8g".printf (l.shares);
        case 3: return l.date;
        case 4: key = l.price; return money (l.price);
        case 5: if (q != null) key = q.price; return money (key);
        case 6: return q != null ? q.currency : "";
        case COL_CHANGE: if (q != null) key = q.change (range, now); return pct (key);
        }
        double gain, capital;
        if (!p.lot_gain (l, Range.MAX, now, out gain, out capital)) return "—";
        switch (col) {
        case COL_VALUE: key = capital + gain; return money (key);
        case COL_GAIN: key = gain; return "%s (%s)".printf (delta (gain), pct (gain / capital));
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

        double day, day_capital, total, cost, moved, moved_capital;
        p.gain (Range.D1, now, out day, out day_capital);
        p.gain (Range.MAX, now, out total, out cost);
        p.gain (range, now, out moved, out moved_capital);
        value_lbl.label = "%s %s".printf (money (cost + total), p.currency);
        show_gain (day_lbl, day, day_capital);
        show_gain (total_lbl, total, cost);
        cost_lbl.label = money (cost);

        var lot = selection.selected_item as Lot;
        var q = lot != null ? p.quotes[lot.symbol] : null;
        back.visible = lot != null;
        if (q != null) {
            double basis = q.basis (range, now);
            chart_title.label = "%s · %s · %s %s".printf (q.symbol, q.name, money (q.price), q.currency);
            show_gain (chart_change, q.price - basis, basis);
            chart.plot (q.view (range, now), basis, q.price >= basis, range);
        } else {
            double opening;
            var history = p.history (range, now, out opening);
            chart_title.label = "Portfolio";
            show_gain (chart_change, moved, moved_capital);
            chart.plot (history, opening > 0 ? opening : double.NAN, moved >= 0, range);
        }

        columns[COL_CHANGE].title = "Chg " + RANGE_LABELS[range];
        columns[COL_VALUE].title = "Value " + p.currency;
        columns[COL_GAIN].title = "Gain " + p.currency;
        for (int i = 0; i < cells.length; i++) fill (cells[i]);
        view.sorter.changed (Gtk.SorterChange.DIFFERENT);   // prices moved: re-sort

        treemap.range = range;
        treemap.queue_draw ();
        matrix.refresh ();
    }

    // ---- quotes ----

    // Load quotes for everything we hold or convert through. `all` also refreshes the ones we already
    // have; `full` refetches their whole history instead of just the latest bars.
    void sync (bool all = false, bool full = false) {
        foreach (var symbol in p.wanted ()) {
            bool have = p.quotes.contains (symbol);
            if (!loading.contains (symbol) && (all || !have)) load_symbol.begin (symbol, full || !have);
        }
    }

    async void load_symbol (string symbol, bool full) {
        loading.add (symbol);
        status.label = "Updating…";
        try {
            var q = p.quotes[symbol];
            if (q == null || full) {
                p.quotes[symbol] = yield yahoo.fetch (symbol);
                if (q == null) sync ();   // a new holding can need FX pairs we don't have yet
            } else {
                yield yahoo.refresh (q);
            }
        } catch (Error e) {
            fail (@"$symbol: $(e.message)");
        }
        loading.remove (symbol);
        if (loading.length == 0) {
            updated = new DateTime.now_local ().format ("Updated %H:%M");
            var shot = Environment.get_variable ("STONKS_SHOT");
            if (shot != null) Timeout.add (400, () => { snapshot_to (shot); return Source.REMOVE; });
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

    // ---- adding and removing lots ----

    void add_dialog (Lot? draft) {
        var symbol = new Adw.EntryRow () { title = "Symbol or company name", activates_default = true };
        var shares = new Adw.EntryRow () { title = "Shares", activates_default = true };
        var date = new Adw.EntryRow () { title = "Buy date (YYYY-MM-DD)", activates_default = true };
        var price = new Adw.EntryRow () { title = "Price per share (empty: that day's close)", activates_default = true };
        var hits = new Gtk.ListBox () { selection_mode = Gtk.SelectionMode.NONE, css_classes = { "boxed-list" }, visible = false };
        var top = new Adw.PreferencesGroup ();
        top.add (symbol);
        var rest = new Adw.PreferencesGroup ();
        rest.add (shares);
        rest.add (date);
        rest.add (price);
        var form = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        form.append (top);
        form.append (hits);
        form.append (rest);

        var dialog = new Adw.AlertDialog ("Add position", "Search by name, or type a Yahoo Finance ticker: AAPL, 7203.T, 005930.KS, VNM.VN, 600519.SS, 0700.HK.") {
            extra_child = form, default_response = "add", close_response = "cancel", prefer_wide_layout = true
        };
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("add", "Add");
        dialog.set_response_appearance ("add", Adw.ResponseAppearance.SUGGESTED);

        // Symbol search as you type; `serial` drops answers to anything but the latest keystroke.
        uint serial = 0;
        string picked = "";
        symbol.changed.connect (() => {
            uint mine = ++serial;
            var text = symbol.text.strip ();
            if (text == picked || text.length < 2) {
                hits.visible = false;
                return;
            }
            Timeout.add (250, () => {
                if (mine == serial) yahoo.search.begin (text, (obj, res) => {
                    Hit[] found = {};
                    try { found = yahoo.search.end (res); } catch (Error e) {}
                    if (mine != serial) return;
                    hits.remove_all ();
                    foreach (var hit in found)
                        hits.append (new Adw.ActionRow () { title = hit.symbol, subtitle = hit.detail, use_markup = false, activatable = true });
                    hits.visible = found.length > 0;
                });
                return Source.REMOVE;
            });
        });
        hits.row_activated.connect ((row) => {
            picked = ((Adw.ActionRow) row).title;
            symbol.text = picked;
            shares.grab_focus ();
        });

        // Add stays disabled until the form parses; `lot` always holds the latest valid reading.
        var lot = new Lot ();
        Adw.EntryRow[] rows = { symbol, shares, date, price };
        foreach (var row in rows) row.changed.connect (() => {
            double n = 0, cost = 0;
            string s = symbol.text.strip ().up (), d = date.text.strip (), c = price.text.strip ();
            var day = new DateTime.from_iso8601 (d + "T00:00:00Z", null);
            bool n_ok = double.try_parse (shares.text.strip (), out n) && n > 0 && n.is_finite ();
            bool d_ok = d.length == 10 && day != null && day.compare (new DateTime.now_utc ().add_days (1)) < 0;
            bool c_ok = c == "" || (double.try_parse (c, out cost) && cost > 0 && cost.is_finite ());
            mark (shares, n_ok || shares.text == "");
            mark (date, d_ok);
            mark (price, c_ok);
            dialog.set_response_enabled ("add", s != "" && n_ok && d_ok && c_ok);
            lot.symbol = s;
            lot.shares = n;
            lot.date = d;
            lot.price = cost;
        });
        date.text = draft != null ? draft.date : new DateTime.now_local ().format ("%Y-%m-%d");
        if (draft != null) {
            shares.text = "%.8g".printf (draft.shares);
            symbol.text = draft.symbol;
        }
        dialog.response.connect ((id) => { if (id == "add") add_lot.begin (lot); });
        dialog.present (this);
    }

    void mark (Adw.EntryRow row, bool ok) {
        if (ok) row.remove_css_class ("error"); else row.add_css_class ("error");
    }

    async void add_lot (Lot lot) {
        if (!p.quotes.contains (lot.symbol)) yield load_symbol (lot.symbol, true);
        var q = p.quotes[lot.symbol];
        if (q == null) {
            add_dialog (lot);   // load_symbol already said why; let them fix the symbol
            return;
        }
        if (lot.price <= 0) lot.price = q.daily.v[q.bar (lot.ts (q.gmtoffset))];
        p.lots.append (lot);
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
            saved.get_array_member ("lots").foreach_element ((array, i, lot) => {
                if (lot.get_node_type () == Json.NodeType.OBJECT) p.lots.append (Json.gobject_deserialize (typeof (Lot), lot));
            });
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
        saved.set_string_member ("currency", p.currency);
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
    var app = new Adw.Application (APP_ID, ApplicationFlags.DEFAULT_FLAGS);
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
