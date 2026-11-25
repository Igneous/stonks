// The window: a sidebar of everything tracked; the Stocks page (the portfolio, or one stock's quote card);
// the two heatmap pages; and the add-stock dialog.
namespace Stonks {

const string APP_ID = "io.github.igneous.Stonks";
const string[] CURRENCIES = { "USD", "EUR", "JPY", "KRW", "VND", "CNY", "HKD", "GBP" };
const string[] COLUMNS = { "Symbol", "Name", "Shares", "Bought", "Cost", "Price", "Cur", "Change", "Value", "Gain", "Annual" };
const int COL_CHANGE = 7;
const int COL_VALUE = 8;
const int COL_GAIN = 9;
// The figures of a quote card, in the order Window.facts_of() gives them: three to a column.
const string[] FACTS = { "Open", "High", "Low", "Prev close", "Volume", "Avg volume", "Mkt cap", "P/E ratio", "EPS", "52-wk high", "52-wk low", "Dividend" };
// "-7.02 today": what the change is over, for each range.
const string[] SPANS = { "today", "past 7 days", "past 30 days", "year to date", "past year", "past 5 years", "all time" };

const int ROUND = 120;   // seconds from one refresh round to the next, see Window.beat()

// A folder's settings, as the user reads them: in the order of Arrange and of Dock.
const string[] ARRANGEMENTS = { "By value", "Horizontal strip", "Vertical strip", "Autogrid", "Fibonacci" };
const string[] DOCKS = { "In line", "Pinned to the top", "Pinned to the bottom", "Pinned to the left", "Pinned to the right" };

// GTK's own call for a display-wide stylesheet. Bound here because Vala files it under Gtk.StyleContext,
// a class deprecated as a whole although this function is not.
[CCode (cname = "gtk_style_context_add_provider_for_display")]
extern void add_style_provider (Gdk.Display display, Gtk.StyleProvider provider, uint priority);

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
    Gtk.Label status = new Gtk.Label ("") { css_classes = { "dim-label", "caption", "numeric" } };
    Gtk.Label live = new Gtk.Label ("") { css_classes = { "success", "caption", "numeric" } };   // the price stream's state, see show_status()
    int64 next_round;   // when the next refresh round is due, on the monotonic clock
    bool traded;        // the stream has sent a price since the card was last filled
    Gtk.Box stats = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 40) { margin_start = 18, margin_end = 18, margin_top = 4 };
    Gtk.Label value_lbl;
    Gtk.Label day_lbl;
    Gtk.Label total_lbl;
    Gtk.Label cost_lbl;
    Gtk.Label chart_title = new Gtk.Label ("") { css_classes = { "heading" }, ellipsize = Pango.EllipsizeMode.END };
    Gtk.Label chart_change = new Gtk.Label ("") { css_classes = { "numeric" } };
    Gtk.Button back = new Gtk.Button.with_label ("Show portfolio") { css_classes = { "flat" }, valign = Gtk.Align.CENTER };
    Adw.ViewStack pages = new Adw.ViewStack ();
    Gtk.Box chart_head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_start = 18, margin_end = 12, margin_top = 12, height_request = 34 };
    // The quote card: what the Stocks page shows around the chart once a stock is selected.
    Gtk.Box card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6) { margin_start = 18, margin_end = 12, margin_top = 10, margin_bottom = 4 };
    Gtk.Image card_logo = new Gtk.Image () { pixel_size = 48, valign = Gtk.Align.CENTER };
    Gtk.Label card_name = new Gtk.Label ("") { xalign = 0, css_classes = { "title-2" }, ellipsize = Pango.EllipsizeMode.END };
    Gtk.Label card_sub = new Gtk.Label ("") { xalign = 0, css_classes = { "dim-label" } };
    Gtk.Label card_price = new Gtk.Label ("") { css_classes = { "title-1", "numeric" } };
    Gtk.Label card_unit = new Gtk.Label ("") { css_classes = { "dim-label" }, valign = Gtk.Align.END, margin_bottom = 4 };
    Gtk.Label card_chip = new Gtk.Label ("") { css_classes = { "chip", "numeric" }, valign = Gtk.Align.CENTER };
    Gtk.Label card_moved = new Gtk.Label ("") { css_classes = { "numeric" }, valign = Gtk.Align.CENTER };
    Gtk.Label card_status = new Gtk.Label ("") { xalign = 0, css_classes = { "caption", "dim-label" } };
    Gtk.Grid facts = new Gtk.Grid () { column_spacing = 14, row_spacing = 6, margin_start = 18, margin_end = 18, margin_top = 2, margin_bottom = 12 };
    Gtk.Label[] fact_values = {};
    // What is pinned on the chart, in words, with the way back: under the chart, over the figures.
    Gtk.Label pin_text = new Gtk.Label ("") { xalign = 0, hexpand = true, use_markup = true, ellipsize = Pango.EllipsizeMode.END, css_classes = { "numeric" } };
    Gtk.Box pin_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) { margin_start = 18, margin_end = 12, visible = false };
    Past? past;            // a stock's days and earnings, fetched when a point of its chart is first pinned...
    string past_of = "";   // ...and whose they are
    bool past_busy;
    GenericSet<string> stats_asked = new GenericSet<string> (str_hash, str_equal);   // see fetch_stats()
    int64 stats_fetched;
    bool stats_busy;
    Chart chart = new Chart ();
    Gtk.ColumnView view = new Gtk.ColumnView (null) { css_classes = { "data-table" } };
    Gtk.ColumnViewColumn[] columns = {};
    GenericArray<Gtk.ColumnViewCell> cells = new GenericArray<Gtk.ColumnViewCell> ();
    string shown = "";            // the symbol whose quote card the Stocks page shows; "" for the portfolio
    string sought = "";           // what the sidebar's search field holds, lower-cased
    Gtk.CustomFilter held_lots;   // what the positions table lists, see the constructor
    Gtk.ScrolledWindow positions = new Gtk.ScrolledWindow () { propagate_natural_height = true, max_content_height = 264 };
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
    HashTable<string, unowned Gtk.Widget> folder_rows = new HashTable<string, unowned Gtk.Widget> (str_hash, str_equal);   // by folder id
    bool upgrading;              // the saved file is from before folders had layouts, see adopt_top_row()

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
        if (upgrading) adopt_top_row ();

        // The styling of our own: the coloured pill a change sits in, and the sidebar row that is open.
        var css = new Gtk.CssProvider ();
        css.load_from_string (".chip { border-radius: 8px; padding: 2px 10px; font-weight: bold; } .chip.success { background: alpha(@success_color, 0.15); } .chip.error { background: alpha(@error_color, 0.15); } row.picked { background: alpha(@accent_bg_color, 0.2); }");
        add_style_provider (display, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        // Header bar: add, page switcher, totals currency, refresh.
        var header = new Adw.HeaderBar () { title_widget = new Adw.ViewSwitcher () { stack = pages, policy = Adw.ViewSwitcherPolicy.WIDE } };
        header.pack_start (new Gtk.Button.from_icon_name ("list-add-symbolic") { action_name = "win.add", tooltip_text = "Add stock (Ctrl+N)" });
        var menu = new Menu ();
        var layouts = new Menu ();
        for (int i = 0; i < ARRANGEMENTS.length; i++) layouts.append_item (menu_item (ARRANGEMENTS[i], "win.arrange", new Variant.int32 (i)));
        menu.append_submenu ("Heatmap Layout", layouts);   // the heatmap is the outermost folder; the others have gears
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
        ranges.notify["active"].connect (() => {
            range = (Range) ranges.active;
            chart.unpin ();
            update ();
        });
        var right = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 14);
        right.append (live);
        right.append (status);
        var bar = new Gtk.CenterBox () { center_widget = ranges, end_widget = right, margin_start = 12, margin_end = 12, margin_bottom = 8 };

        // Stocks page: headline numbers (when something is held), chart, table.
        value_lbl = stat (stats, "Value");
        day_lbl = stat (stats, "Day");
        total_lbl = stat (stats, "Total gain");
        cost_lbl = stat (stats, "Cost basis");
        chart_head.append (chart_title);
        chart_head.append (chart_change);
        back.clicked.connect (() => show_stock (""));

        // The quote card: logo, name and exchange; price and change; when that was. Then, under the
        // chart, the figures.
        var naming = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) { hexpand = true, valign = Gtk.Align.CENTER };
        naming.append (card_name);
        naming.append (card_sub);
        var card_head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        card_head.append (card_logo);
        card_head.append (naming);
        card_head.append (back);
        var pricing = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        pricing.append (card_price);
        pricing.append (card_unit);
        pricing.append (card_chip);
        pricing.append (card_moved);
        card.append (card_head);
        card.append (pricing);
        card.append (card_status);
        for (int i = 0; i < FACTS.length; i++) {
            var value = new Gtk.Label ("—") { xalign = 0, hexpand = true, ellipsize = Pango.EllipsizeMode.END, css_classes = { "numeric" } };
            facts.attach (new Gtk.Label (FACTS[i]) { xalign = 0, css_classes = { "dim-label" } }, i / 3 * 2, i % 3);
            facts.attach (value, i / 3 * 2 + 1, i % 3);
            fact_values += value;
        }

        var unpin = new Gtk.Button.with_label ("Back to now") { css_classes = { "flat" }, tooltip_text = "Unpin (or right-click the chart)" };
        unpin.clicked.connect (() => {
            chart.unpin ();
            update ();
        });
        pin_row.append (pin_text);
        pin_row.append (unpin);
        chart.pinned.connect (() => describe.begin ());

        for (int i = 0; i < COLUMNS.length; i++) add_column (i);
        var bin = new Gtk.SignalListItemFactory ();
        bin.setup.connect ((o) => {
            unowned var cell = (Gtk.ColumnViewCell) o;
            var button = new Gtk.Button.from_icon_name ("user-trash-symbolic") { css_classes = { "flat" }, tooltip_text = "Remove" };
            button.clicked.connect (() => remove_lot ((Lot) cell.item));
            cell.child = button;
        });
        view.append_column (new Gtk.ColumnViewColumn (null, bin));
        // The table lists positions: the lots actually held. All of them under the portfolio, the shown
        // stock's own under its card; a click on one opens that stock.
        held_lots = new Gtk.CustomFilter ((o) => ((Lot) o).shares > 0 && (shown == "" || ((Lot) o).symbol == shown));
        var listed = new Gtk.SortListModel (new Gtk.FilterListModel (p.lots, held_lots), view.sorter);
        view.model = new Gtk.NoSelection (listed);
        view.single_click_activate = true;
        view.activate.connect ((at) => show_stock (((Lot) listed.get_item (at)).symbol));
        positions.child = view;

        // The Stocks page, top to bottom: the portfolio's totals or a stock's card; the chart, which
        // takes whatever height is left; the stock's figures; the positions.
        chart.vexpand = true;
        var stocks = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        stocks.append (stats);
        stocks.append (chart_head);
        stocks.append (card);
        stocks.append (chart);
        stocks.append (pin_row);
        stocks.append (facts);
        stocks.append (positions);

        // Heatmap page: the treemap. Then the sidebar, which all the pages share: everything tracked, in
        // its folders, searchable; the header's toggle shows and hides it.
        treemap = new Treemap (p) { margin_start = 12, margin_end = 12, margin_bottom = 12 };
        treemap.charts = tile_charts;
        treemap.changed.connect (rearranged);
        treemap.configure.connect ((folder, gear) => layout_popover (folder, treemap, gear));
        treemap.peeked.connect ((symbol) => { treemap.card.child = hover_card (symbol); });
        treemap.opened.connect ((symbol) => show_stock (symbol));   // double-clicked
        var side = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) { margin_start = 12, margin_end = 12, margin_bottom = 12 };
        side.append (new Gtk.CenterBox () {
            start_widget = new Gtk.Label ("Folders") { css_classes = { "heading" } },
            end_widget = new Gtk.Button.from_icon_name ("folder-new-symbolic") { action_name = "win.new-folder", action_target = new Variant.string (""), tooltip_text = "New folder", css_classes = { "flat" } }
        });
        var search = new Gtk.SearchEntry () { placeholder_text = "Find a stock" };
        search.search_changed.connect (() => {
            sought = search.text.strip ().down ();
            show_folders ();
        });
        side.append (search);
        side.append (new Gtk.Label ("Click to open. Drag to arrange, here or on the heatmap: a stock onto a folder or beside another stock; a folder into another, or beside it by its edge.") { wrap = true, xalign = 0, css_classes = { "dim-label", "caption" } });
        side.append (folders);
        // A plain list doesn't pass a click on to its rows; the folders' own lists do.
        folders.row_activated.connect ((row) => { if (row is Adw.ActionRow) ((Adw.ActionRow) row).activate (); });
        var split = new Adw.OverlaySplitView () {
            sidebar = new Gtk.ScrolledWindow () { child = side, hscrollbar_policy = Gtk.PolicyType.NEVER },
            content = pages, min_sidebar_width = 260, max_sidebar_width = 340
        };
        var toggle = new Gtk.ToggleButton () { icon_name = "sidebar-show-symbolic", tooltip_text = "Sidebar", active = true };
        toggle.bind_property ("active", split, "show-sidebar", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
        header.pack_start (toggle);

        matrix = new Matrix (p) { margin_start = 12, margin_end = 12, margin_bottom = 12, valign = Gtk.Align.START };
        pages.add_titled_with_icon (stocks, "stocks", "Stocks", "view-list-symbolic");
        pages.add_titled_with_icon (treemap, "heatmap", "Heatmap", "view-grid-symbolic");
        pages.add_titled_with_icon (new Gtk.ScrolledWindow () { child = matrix }, "performance", "Performance", "power-profile-performance-symbolic");
        pages.notify["visible-child"].connect (() => tune ());
        feed.heard.connect (() => { traded = true; });

        var empty = new Adw.StatusPage () {
            title = "No stocks yet",
            description = "Add a stock to follow its price. Give it a share count and a buy date to see what that investment would be worth today.",
            child = new Gtk.Button.with_label ("Add stock") { action_name = "win.add", halign = Gtk.Align.CENTER, css_classes = { "pill", "suggested-action" } }
        };
        stack.add_named (empty, "empty");
        stack.add_named (split, "main");
        var toolbar = new Adw.ToolbarView () { content = stack };
        toolbar.add_top_bar (header);
        toolbar.add_top_bar (bar);
        toasts.child = toolbar;
        content = toasts;

        var add = new SimpleAction ("add", null);
        add.activate.connect (() => add_dialog (null));
        add_action (add);
        var refresh = new SimpleAction ("refresh", null);
        refresh.activate.connect (() => {
            stats_fetched = 0;
            next_round = get_monotonic_time () + ROUND * 1000000;
            sync (true, true);
            fetch_stats.begin ();
        });
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

        var arrange = new SimpleAction.stateful ("arrange", VariantType.INT32, new Variant.int32 (p.root.arrange));
        arrange.activate.connect ((to) => {
            p.root.arrange = (Arrange) to.get_int32 ();
            arrange.set_state (to);
            rearranged ();
        });
        add_action (arrange);

        // Folder actions; the sidebar's menus carry the id of the folder (or the stock) they act on as the target.
        var new_folder = new SimpleAction ("new-folder", VariantType.STRING);   // inside that one; "" for the top level
        new_folder.activate.connect ((id) => folder_dialog (null, p.folder (id.get_string ())));
        add_action (new_folder);
        var rename_folder = new SimpleAction ("rename-folder", VariantType.STRING);
        rename_folder.activate.connect ((id) => folder_dialog (p.folder (id.get_string ()), p.root));
        add_action (rename_folder);
        var delete_folder = new SimpleAction ("delete-folder", VariantType.STRING);
        delete_folder.activate.connect ((id) => {
            p.remove_group (p.folder (id.get_string ()));   // what was in it moves up a level; nothing is removed
            rearranged ();
        });
        add_action (delete_folder);
        var layout_folder = new SimpleAction ("layout-folder", VariantType.STRING);
        layout_folder.activate.connect ((id) => {
            var row = folder_rows[id.get_string ()];
            if (row != null) layout_popover (p.folder (id.get_string ()), row, null);
        });
        add_action (layout_folder);
        var add_to = new SimpleAction ("add-to", VariantType.STRING);
        add_to.activate.connect ((id) => add_dialog (new Lot () { group = id.get_string () }));
        add_action (add_to);
        var remove = new SimpleAction ("remove", VariantType.STRING);
        remove.activate.connect ((symbol) => remove_symbol (symbol.get_string ()));
        add_action (remove);
        var move = new SimpleAction ("move", new VariantType ("(ss)"));
        move.activate.connect ((target) => {
            string symbol, folder;
            target.get ("(ss)", out symbol, out folder);
            p.assign (symbol, folder);
            rearranged ();
        });
        add_action (move);

        // Dev aid, see the Makefile.
        var page = Environment.get_variable ("STONKS_VIEW");
        if (page != null) pages.visible_child_name = page;
        var r = Environment.get_variable ("STONKS_RANGE");
        if (r != null) ranges.active = int.parse (r);
        var row = Environment.get_variable ("STONKS_ROW");
        if (row != null && int.parse (row) < p.lots.get_n_items ()) shown = ((Lot) p.lots.get_item (int.parse (row))).symbol;
        var size = (Environment.get_variable ("STONKS_SIZE") ?? "").split ("x");
        if (size.length == 2) set_default_size (int.parse (size[0]), int.parse (size[1]));

        update ();
        sync (true);
        feed.load_names.begin ();
        next_round = get_monotonic_time () + ROUND * 1000000;
        Timeout.add_seconds (1, () => { beat (); return Source.CONTINUE; });
    }

    // Once a second: start a refresh round when one is due, bring the card up to the stream's latest
    // price, and count down.
    // ponytail: a round every two minutes (ROUND), which is one request per twenty Yahoo symbols whose
    // market is open (see Feed.refresh). Yahoo publishes no limit for these endpoints; lengthen it if
    // a large portfolio starts drawing HTTP 429.
    void beat () {
        if (get_monotonic_time () >= next_round) {
            next_round = get_monotonic_time () + ROUND * 1000000;
            sync (true);
        }
        var q = shown != "" ? p.quotes[shown] : null;
        if (traded && q != null) {
            // ponytail: the card, its chart and its positions only. Totals, the sidebar and (for a
            // holding in another currency) its Value and Gain wait for the next round: update() would
            // reprice every history we hold, every second.
            show_card (q, now_s ());
            for (int i = 0; i < cells.length; i++) fill (cells[i]);
        }
        traded = false;
        show_status ();
    }

    // The right of the range bar. Whether the open stock's price is streaming, and how often one
    // comes; then when quotes were last fetched, and how long until they are again.
    void show_status () {
        int left = (int) ((next_round - get_monotonic_time ()) / 1000000).clamp (0, ROUND);
        var next = "next in %d:%02d".printf (left / 60, left % 60);
        status.label = updated != "" ? @"$updated · $next" : next.splice (0, 1, "N");
        if (loading.length > 0) status.label = "Updating…";

        double pace = feed.pace, quiet = feed.quiet ();
        var streaming = "● Live · waiting for a trade";
        if (pace.is_finite ()) streaming = pace < 1.5 ? "● Live · a price about every second" : "● Live · a price about every %.0f s".printf (pace);
        if (quiet > double.max (60, pace * 5)) streaming = "● Live · no trades in the last %.0f min".printf (Math.floor (quiet / 60));
        live.label = streaming;
        live.visible = feed.live;
    }

    // Stream the price of the stock whose card is on screen; of nothing, when none is.
    void tune () {
        feed.follow (shown != "" && pages.visible_child_name == "stocks" ? p.quotes[shown] : null);
        show_status ();
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
            // Only the name gives way when the table is narrow: a cut-off date or gain is no use.
            cell.child = new Gtk.Label (null) { xalign = text_column ? 0 : 1, ellipsize = col == 1 ? Pango.EllipsizeMode.END : Pango.EllipsizeMode.NONE, css_classes = { "numeric" } };
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

        // With nothing held there is no portfolio to total or chart: hide the totals and chart a stock.
        bool held = false;
        for (uint i = 0; i < p.lots.get_n_items (); i++) held |= ((Lot) p.lots.get_item (i)).shares > 0;
        if (shown != "" && !p.tracks (shown)) shown = "";   // it was removed
        if (shown == "" && !held && p.lots.get_n_items () > 0) shown = ((Lot) p.lots.get_item (0)).symbol;
        held_lots.changed (Gtk.FilterChange.DIFFERENT);
        positions.visible = view.model.get_n_items () > 0;

        double day, day_capital, total, cost, moved, moved_capital;
        p.gain (Range.D1, now, out day, out day_capital);
        p.gain (Range.MAX, now, out total, out cost);
        p.gain (range, now, out moved, out moved_capital);
        value_lbl.label = "%s %s".printf (money (cost + total, p.currency), p.currency);
        show_gain (day_lbl, day, day_capital, p.currency);
        show_gain (total_lbl, total, cost, p.currency);
        cost_lbl.label = money (cost, p.currency);

        // The shown stock gets its quote card around the chart; otherwise it is the portfolio's totals.
        var q = shown != "" ? p.quotes[shown] : null;
        card.visible = facts.visible = q != null;
        chart_head.visible = stats.visible = q == null && held;
        back.visible = held;
        if (q != null) {
            show_card (q, now);
        } else {
            double opening;
            var history = p.history (range, now, out opening);
            chart_title.label = "Portfolio";
            show_gain (chart_change, moved, moved_capital, p.currency);
            chart.plot (history, opening > 0 ? opening : double.NAN, moved >= 0, range, p.currency);
            show_pins ();
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
        tune ();
    }

    // ---- the quote card ----

    // Open a stock's quote card on the Stocks page, or the portfolio with "".
    void show_stock (string symbol) {
        if (symbol != shown) chart.unpin ();
        shown = symbol;
        pages.visible_child_name = "stocks";
        update ();
    }

    // Fill the quote card and the figures under the chart for the selected stock, Google Finance style.
    void show_card (Quote q, int64 now) {
        double basis = q.basis (range, now), moved = q.price - basis;
        var s = q.stats;
        var texture = logos[q.symbol];
        card_logo.visible = texture != null;
        if (texture != null) card_logo.paintable = texture;
        card_name.label = feed.full_name (q.symbol) ?? q.name;
        card_sub.label = s.exchange != "" ? @"$(s.exchange): $(q.symbol)" : q.symbol;
        card_price.label = q.price < 1 ? "%.4g".printf (q.price) : money (q.price, q.currency);
        card_unit.label = q.currency;
        card_chip.label = "%s %.2f%%".printf (moved >= 0 ? "▲" : "▼", Math.fabs (moved / basis) * 100);
        tint (card_chip, moved);
        card_moved.label = "%s %s".printf (delta (moved, q.currency), SPANS[range]);
        tint (card_moved, moved);
        string[] when = {};
        if (s.time > 0) {
            var at = new DateTime.from_unix_utc (s.time + q.gmtoffset).format ("%b %e, %H:%M");   // on the exchange's clock
            when += "%s: %s %s".printf (s.state == "REGULAR" ? "Market open" : "Closed", at, s.zone);
        }
        if (s.extra != "") when += "%s %s %s".printf (s.extra, money (s.extra_price, q.currency), pct (s.extra_change / 100));
        card_status.label = string.joinv ("  ·  ", when);
        card_status.visible = when.length > 0;
        int today;
        var points = q.trail (range, now, out today);
        chart.plot (points, basis, moved >= 0, range, q.currency, today);

        // The figures under the chart: as they stand now or, with a point of the chart pinned, as
        // they stood then. With a span pinned, at its start and at its end.
        var values = facts_of (q, now);
        int64 from = chart.pin_from, to = chart.pin_to;
        show_pins ();
        for (int i = 0; from != 0 && i < FACTS.length; i++) values[i] = past_of == q.symbol ? "—" : "…";   // can't be had, or on its way
        if (from != 0 && past_of == q.symbol && past != null) {
            values = facts_of (q, now, stats_at (q, from, points.at (from), now), to != from);
            var later = facts_of (q, now, stats_at (q, to, points.at (to), now), to != from);
            for (int i = 0; i < FACTS.length; i++) if (later[i] != values[i]) values[i] += " → " + later[i];
        }
        for (int i = 0; i < FACTS.length; i++) fact_values[i].label = values[i];
    }

    // Under the chart, whatever it is of: what is pinned on it, and the button that unpins.
    void show_pins () {
        pin_row.visible = chart.pin_from != 0;
        pin_text.label = chart.pin_text ();
    }

    // The chart's pins changed. Figures for a moment in the past need the stock's past, which is
    // fetched the first time it is wanted (Feed.past keeps it from then on).
    async void describe () {
        var q = shown != "" ? p.quotes[shown] : null;
        show_pins ();
        if (q == null) return;   // the portfolio's chart: it has no figures to go with them
        if (chart.pin_from != 0 && !past_busy) {
            past_busy = true;
            var got = yield feed.past (q);
            past_busy = false;
            past = got;
            past_of = q.symbol;
            if (got == null) fail (@"$(q.symbol): its history can't be had right now");
        }
        if (shown == q.symbol) show_card (q, now_s ());
        else if (chart.pin_from != 0) describe.begin ();   // another stock was opened, and pinned, meanwhile
    }

    // A quote's figures as they stood at `t`, when it cost `price` (see Past.at). For the latest
    // session, the day's own are the live ones: its bar was still being made when the past was fetched.
    Stats stats_at (Quote q, int64 t, double price, int64 now) {
        var s = past.at (t, price, q.gmtoffset);
        if (t < q.start (Range.D1, now)) return s;
        if (q.stats.open.is_finite ()) s.open = q.stats.open;
        if (q.stats.high.is_finite ()) s.high = q.stats.high;
        if (q.stats.low.is_finite ()) s.low = q.stats.low;
        if (q.stats.volume.is_finite ()) s.volume = q.stats.volume;
        return s;
    }

    // The figures of a quote, in FACTS' order: the feed's own, or `then`, those of a moment in its
    // past (`brief` for when two such moments have to share a cell). Where the feed has none (a Hanoi stock has no Yahoo quote) the day's range, the previous
    // close and the year's range are worked out from the closes we hold, so those are close-to-close
    // rather than the true highs and lows.
    string[] facts_of (Quote q, int64 now, Stats? then = null, bool brief = false) {
        var s = then ?? q.stats;
        var cur = q.currency;
        double day_low = double.NAN, day_high = double.NAN, year_low = double.NAN, year_high = double.NAN, prev = s.prev_close;
        if (then == null) {
            Quote.extremes (q.intra.n > 0 ? q.intra : q.daily, q.start (Range.D1, now), out day_low, out day_high);
            Quote.extremes (q.daily, now - 365 * 86400, out year_low, out year_high);
            if (!prev.is_finite ()) prev = q.basis (Range.D1, now);
        }
        string dividend = "—";
        if (s.dividend_yield > 0) dividend = "%.2f%%".printf (s.dividend_yield);
        if (s.dividend_yield > 0 && s.dividend_rate > 0 && !brief) dividend += " (%s a year)".printf (money (s.dividend_rate, cur));
        string volume = "—", average = "—", cap = "—", pe = "—";
        if (s.volume.is_finite ()) volume = compact (s.volume);
        if (s.avg_volume.is_finite ()) average = compact (s.avg_volume);
        if (s.cap.is_finite ()) cap = brief ? compact (s.cap) : compact (s.cap) + " " + cur;
        if (s.pe.is_finite ()) pe = "%.2f".printf (s.pe);
        return {
            money (s.open, cur),
            money (s.high.is_finite () ? s.high : day_high, cur),
            money (s.low.is_finite () ? s.low : day_low, cur),
            money (prev, cur),
            volume, average, cap, pe,
            money (s.eps, cur),
            money (s.high52.is_finite () ? s.high52 : year_high, cur),
            money (s.low52.is_finite () ? s.low52 : year_low, cur),
            dividend
        };
    }

    // The heatmap's hover card: the quote card in miniature, plus what is held of it.
    Gtk.Widget? hover_card (string symbol) {
        var q = p.quotes[symbol];
        if (q == null) return null;
        var now = now_s ();
        double basis = q.basis (range, now), moved = q.price - basis;
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) { margin_start = 8, margin_end = 8, margin_top = 8, margin_bottom = 8, width_request = 340 };

        var naming = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) { valign = Gtk.Align.CENTER };
        naming.append (new Gtk.Label (feed.full_name (symbol) ?? q.name) { xalign = 0, wrap = true, max_width_chars = 34, css_classes = { "heading" } });
        naming.append (new Gtk.Label (q.stats.exchange != "" ? @"$(q.stats.exchange): $symbol" : symbol) { xalign = 0, css_classes = { "caption", "dim-label" } });
        var head = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        if (logos.contains (symbol)) head.append (new Gtk.Image.from_paintable (logos[symbol]) { pixel_size = 32 });
        head.append (naming);
        box.append (head);

        var chip = new Gtk.Label ("%s %.2f%%".printf (moved >= 0 ? "▲" : "▼", Math.fabs (moved / basis) * 100)) { css_classes = { "chip", "numeric" }, valign = Gtk.Align.CENTER };
        tint (chip, moved);
        var pricing = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        pricing.append (new Gtk.Label (price_text (q.price, q.currency)) { css_classes = { "title-3", "numeric" } });
        pricing.append (chip);
        pricing.append (new Gtk.Label (SPANS[range]) { css_classes = { "caption", "dim-label" }, valign = Gtk.Align.CENTER });
        box.append (pricing);

        var grid = new Gtk.Grid () { column_spacing = 10, row_spacing = 3 };
        var values = facts_of (q, now);
        for (int i = 0; i < FACTS.length; i++) {
            grid.attach (new Gtk.Label (FACTS[i]) { xalign = 0, css_classes = { "caption", "dim-label" } }, i / 6 * 2, i % 6);
            grid.attach (new Gtk.Label (values[i]) { xalign = 0, hexpand = true, css_classes = { "caption", "numeric" } }, i / 6 * 2 + 1, i % 6);
        }
        box.append (grid);

        // What is held of it, every lot together.
        double shares = 0, gain = 0, capital = 0;
        for (uint i = 0; i < p.lots.get_n_items (); i++) {
            var l = (Lot) p.lots.get_item (i);
            double g, k;
            if (l.symbol != symbol) continue;
            if (!p.lot_gain (l, Range.MAX, now, out g, out k)) continue;
            shares += l.shares;
            gain += g;
            capital += k;
        }
        if (capital > 0) {
            var holding = new Gtk.Label ("%.8g shares  ·  %s %s  ·  %s (%s)".printf (shares, money (capital + gain, p.currency), p.currency, delta (gain, p.currency), pct (gain / capital))) { xalign = 0, css_classes = { "caption", "numeric" } };
            tint (holding, gain);
            box.append (holding);
        }
        return box;
    }

    // Ask for the figures the cards show: one request for everything tracked, and no more often than
    // every five minutes unless something new has been added (or the user refreshes).
    async void fetch_stats () {
        var now = now_s ();
        var wanted = new GenericArray<Quote> ();
        bool news = false;
        for (uint i = 0; i < p.lots.get_n_items (); i++) {
            var symbol = ((Lot) p.lots.get_item (i)).symbol;
            var q = p.quotes[symbol];
            if (q == null || wanted.find (q)) continue;
            wanted.add (q);
            news |= !stats_asked.contains (symbol);
        }
        if (stats_busy || wanted.length == 0 || (!news && now - stats_fetched < 300)) return;
        stats_busy = true;
        yield feed.load_stats (wanted);
        for (int i = 0; i < wanted.length; i++) stats_asked.add (wanted[i].symbol);
        stats_fetched = now;
        stats_busy = false;
        update ();
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

    // The arrangement changed, here or on the heatmap.
    void rearranged () {
        save ();
        update ();
    }

    MenuItem menu_item (string label, string action, Variant target) {
        var item = new MenuItem (label, null);
        item.set_action_and_target_value (action, target);
        return item;
    }

    // "Tech > AI": a folder's name with those of the folders it is in.
    string path_of (Group g) {
        var text = g.name;
        for (unowned Group? up = g.parent; up != null && up != p.root; up = up.parent) text = up.name + " › " + text;
        return text;
    }

    // The sidebar, shared by every page: the portfolio; each folder with the folders and stocks in it;
    // then the stocks in none. A click opens a stock's card, the search field narrows the list. Rebuilt
    // only when the arrangement (or what is open, or sought) changes, so a price refresh doesn't fold
    // up what is open.
    void show_folders () {
        var tiles = p.tiles (range, now_s (), 1, 1);
        var all = p.folders ();
        var shape = new StringBuilder (@"$shown\n$sought\n");
        bool held = false;
        for (int i = 0; i < all.length; i++) shape.append ("%s\t%s\t%s\n".printf (all[i].id, all[i].name, all[i].parent.id));
        for (int i = 0; i < tiles.length; i++) {
            if (tiles[i].kind == TileKind.GROUP) continue;
            held |= tiles[i].value > 0;
            shape.append ("%s\t%s\t%s\t%d\n".printf (tiles[i].symbol, tiles[i].folder.id, tiles[i].name, (int) logos.contains (tiles[i].symbol)));
        }
        shape.append (held ? "held" : "");
        if (shape.str == folders_shown) return;
        folders_shown = shape.str;
        folders.remove_all ();
        folder_rows.remove_all ();

        if (held && sought == "") {
            var portfolio = new Adw.ActionRow () { title = "Portfolio", subtitle = "Totals and positions", activatable = true };
            portfolio.add_prefix (new Gtk.Image.from_icon_name ("view-list-symbolic"));
            portfolio.activated.connect (() => show_stock (""));
            if (shown == "") portfolio.add_css_class ("picked");
            folders.append (portfolio);
        }
        int found;
        for (int i = 0; i < p.root.children.length; i++) {
            var row = folder_row (p.root.children[i], tiles, out found);
            if (sought == "" || found > 0) folders.append (row);   // while searching, only where something was found
        }
        // The stocks in no folder. Listed even with none while there are folders, so there is somewhere
        // to drag one back out to.
        var loose = folder_row (p.root, tiles, out found);
        if (sought != "" ? found > 0 : (found > 0 || all.length > 0)) folders.append (loose);
    }

    // A folder's row in the sidebar, holding a row for each folder and each stock in it. `found` is how
    // many stocks that comes to, however deep. The root's stands for the stocks in no folder.
    Adw.ExpanderRow folder_row (Group g, GenericArray<Tile> tiles, out int found) {
        bool loose = g == p.root;
        var row = new Adw.ExpanderRow () { use_markup = false, title = loose ? "Ungrouped" : g.name, expanded = true };
        row.add_prefix (new Gtk.Image.from_icon_name ("folder-symbolic"));
        folder_rows[g.id] = row;
        if (!loose && g.parent != p.root) row.margin_start = 14;   // set in from the folder it is in
        int count = 0;
        for (int i = 0; !loose && i < g.children.length; i++) {
            int inner;
            var child = folder_row (g.children[i], tiles, out inner);
            if (sought == "" || inner > 0) row.add_row (child);
            count += inner;
        }
        for (int i = 0; i < tiles.length; i++) {
            var t = tiles[i];
            if (t.kind == TileKind.GROUP || t.folder != g || !(@"$(t.symbol) $(t.name)".down ().contains (sought))) continue;
            row.add_row (sidebar_row (t));
            count++;
        }
        found = count;
        // Spelled out with ifs: valac 0.56 frees the inner result of a nested ?: over strings too early.
        row.subtitle = "Empty";
        if (count == 1) row.subtitle = "1 stock";
        if (count > 1) row.subtitle = @"$count stocks";

        // Drop a stock on the folder to file it here (its rows take drops themselves, to place it among
        // them). Drop another folder on its heading: the middle puts it inside, the top edge before
        // this one and the bottom edge after it.
        var drop = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        unowned Adw.ExpanderRow self = row;
        drop.drop.connect ((value, x, y) => {
            var payload = value.get_string ();
            var box = self.get_first_child ();
            double head = box != null && box.get_first_child () != null ? box.get_first_child ().get_height () : 50;
            // Later, not from inside the drop: it rebuilds this very list.
            Idle.add (() => {
                var moving = p.folder (payload.has_prefix ("folder:") ? payload.substring (7) : "");
                if (!payload.has_prefix ("folder:")) p.assign (payload, g.id);
                else if (loose || y > head || (y > head * 0.25 && y < head * 0.75)) p.move_group (moving, g);
                else p.move_group (moving, g.parent, g, y > head / 2);
                rearranged ();
                return Source.REMOVE;
            });
            return true;
        });
        row.add_controller (drop);
        if (loose) return row;

        var grab = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
        grab.prepare.connect ((x, y) => new Gdk.ContentProvider.for_value ("folder:" + g.id));
        row.add_controller (grab);
        row.add_suffix (new Gtk.Button.from_icon_name ("list-add-symbolic") {
            tooltip_text = "Add a stock to this folder", valign = Gtk.Align.CENTER, css_classes = { "flat" },
            action_name = "win.add-to", action_target = new Variant.string (g.id)
        });
        var actions = new Menu ();
        actions.append_item (menu_item ("Layout…", "win.layout-folder", new Variant.string (g.id)));
        actions.append_item (menu_item ("New Subfolder…", "win.new-folder", new Variant.string (g.id)));
        actions.append_item (menu_item ("Rename…", "win.rename-folder", new Variant.string (g.id)));
        actions.append_item (menu_item ("Delete", "win.delete-folder", new Variant.string (g.id)));
        row.add_suffix (new Gtk.MenuButton () { icon_name = "view-more-symbolic", valign = Gtk.Align.CENTER, css_classes = { "flat" }, menu_model = actions });
        return row;
    }

    // One row of the sidebar: a tracked symbol. Click it to open its card; drag it to arrange; its menu
    // moves it between folders, or takes it off the list.
    Adw.ActionRow sidebar_row (Tile t) {
        var row = new Adw.ActionRow () { use_markup = false, title = t.symbol, subtitle = t.name, subtitle_lines = 1, activatable = true };
        if (t.symbol == shown) row.add_css_class ("picked");
        if (logos.contains (t.symbol)) row.add_prefix (new Gtk.Image.from_paintable (logos[t.symbol]) { pixel_size = 24 });
        row.activated.connect (() => show_stock (t.symbol));

        // Drag the row onto a folder or another row here, or onto the heatmap.
        var drag = new Gtk.DragSource () { actions = Gdk.DragAction.MOVE };
        unowned Gtk.DragSource source = drag;   // unowned, or the handler below would keep
        unowned Adw.ActionRow self = row;       // both alive after the list is rebuilt
        drag.prepare.connect ((x, y) => new Gdk.ContentProvider.for_value (t.symbol));
        drag.drag_begin.connect ((d) => { source.set_icon (new Gtk.WidgetPaintable (self), 0, 0); });
        row.add_controller (drag);
        // A stock dropped on this row goes beside it, above or below by which half was hit; a folder,
        // into the folder this row is in.
        var beside = new Gtk.DropTarget (typeof (string), Gdk.DragAction.MOVE);
        beside.drop.connect ((value, x, y) => {
            var payload = value.get_string ();
            bool after = y > self.get_height () / 2;
            if (payload == t.symbol) return false;
            Idle.add (() => {
                if (payload.has_prefix ("folder:")) {
                    p.move_group (p.folder (payload.substring (7)), t.folder);
                } else {
                    p.move (payload, t.symbol, after);
                    p.assign (payload, t.folder.id);
                }
                rearranged ();
                return Source.REMOVE;
            });
            return true;
        });
        row.add_controller (beside);

        var menu = new Menu ();
        var targets = new Menu ();
        var all = p.folders ();
        for (int k = 0; k < all.length; k++)
            if (all[k] != t.folder) targets.append_item (menu_item (path_of (all[k]), "win.move", new Variant ("(ss)", t.symbol, all[k].id)));
        if (t.folder != p.root) targets.append_item (menu_item ("Ungrouped", "win.move", new Variant ("(ss)", t.symbol, "")));
        if (targets.get_n_items () > 0) menu.append_section ("Move to", targets);
        var last = new Menu ();
        last.append_item (menu_item ("Remove", "win.remove", new Variant.string (t.symbol)));
        menu.append_section (null, last);
        row.add_suffix (new Gtk.MenuButton () { icon_name = "view-more-symbolic", valign = Gtk.Align.CENTER, css_classes = { "flat" }, menu_model = menu });
        return row;
    }

    // Name a new folder inside `into`, or rename `old`.
    void folder_dialog (Group? old, Group into) {
        var entry = new Gtk.Entry () { text = old != null ? old.name : "", activates_default = true };
        var title = "New folder";
        if (old != null) title = "Rename folder";
        else if (into != p.root) title = "New folder in " + into.name;
        var dialog = new Adw.AlertDialog (title, null) { extra_child = entry, default_response = "ok", close_response = "cancel" };
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("ok", old == null ? "Create" : "Rename");
        dialog.set_response_appearance ("ok", Adw.ResponseAppearance.SUGGESTED);
        dialog.response.connect ((id) => {
            var name = entry.text.strip ();
            if (id != "ok" || name == "") return;
            if (old != null) old.name = name; else p.add_group (name, into);
            rearranged ();
        });
        dialog.present (this);
    }

    // A folder's layout settings, in a popover on `parent` (pointing at `at`, if given): from its gear
    // on the heatmap, or its menu in the sidebar. They take effect as they are changed.
    void layout_popover (Group g, Gtk.Widget parent, Gdk.Rectangle? at) {
        var arrange = new Gtk.DropDown.from_strings (ARRANGEMENTS) { selected = g.arrange, hexpand = true };
        var dock = new Gtk.DropDown.from_strings (DOCKS) { selected = g.dock };
        var scroll = new Gtk.CheckButton.with_label ("Scroll rather than shrink the tiles") { active = g.scroll, tooltip_text = "For a strip with more in it than fits" };
        var size = new Gtk.Button.with_label ("Reset size") { tooltip_text = "A pinned folder is resized by dragging its inner edge on the heatmap; this undoes that" };
        scroll.sensitive = g.arrange == Arrange.ROW || g.arrange == Arrange.COLUMN;
        size.sensitive = g.size > 0;
        var form = new Gtk.Grid () { row_spacing = 8, column_spacing = 12, margin_top = 8, margin_bottom = 8, margin_start = 8, margin_end = 8 };
        form.attach (new Gtk.Label (g.name) { xalign = 0, css_classes = { "heading" }, ellipsize = Pango.EllipsizeMode.END }, 0, 0, 2, 1);
        form.attach (new Gtk.Label ("Arrangement") { xalign = 0 }, 0, 1);
        form.attach (arrange, 1, 1);
        form.attach (new Gtk.Label ("Position") { xalign = 0 }, 0, 2);
        form.attach (dock, 1, 2);
        form.attach (scroll, 0, 3, 2, 1);
        form.attach (size, 0, 4, 2, 1);
        arrange.notify["selected"].connect (() => {
            g.arrange = (Arrange) arrange.selected;
            scroll.sensitive = g.arrange == Arrange.ROW || g.arrange == Arrange.COLUMN;
            rearranged ();
        });
        dock.notify["selected"].connect (() => {
            p.dock_group (g, (Dock) dock.selected);
            arrange.selected = g.arrange;   // a strip turns to run along the edge it is pinned to
            size.sensitive = false;
            rearranged ();
        });
        scroll.toggled.connect (() => { g.scroll = scroll.active; rearranged (); });
        size.clicked.connect (() => { g.size = 0; size.sensitive = false; rearranged (); });

        var popover = new Gtk.Popover () { child = form };
        unowned Gtk.Popover self = popover;   // its parent holds it from here until it is closed
        popover.set_parent (parent);
        if (at != null) popover.pointing_to = at;
        popover.closed.connect (() => { Idle.add (() => { self.unparent (); return Source.REMOVE; }); });
        popover.popup ();
    }

    // Before folders had layouts, whatever was watched that wasn't a company's stock sat in a row along
    // the top of the heatmap, by rule. That is a folder like any other now: make it, and file them in it.
    void adopt_top_row () {
        Group? top = null;
        var tiles = p.tiles (range, now_s (), 1, 1);
        for (int i = 0; i < tiles.length; i++) {
            if (tiles[i].kind != TileKind.BENCHMARK) continue;
            if (top == null) {
                top = p.add_group ("Top row", p.root);
                p.move_group (top, p.root, p.root.children[0]);   // first in the sidebar
                top.arrange = Arrange.ROW;
                p.dock_group (top, Dock.TOP);
            }
            p.assign (tiles[i].symbol, top.id);
        }
        save ();
    }

    // ---- quotes ----

    // Load quotes for everything we track or convert through. `all` also refreshes the ones we already
    // have, but only those that are due (see Quote.due); `force` refreshes them regardless.
    void sync (bool all = false, bool force = false) {
        var now = now_s ();
        var stale = new GenericArray<Quote> ();
        foreach (var symbol in p.wanted ()) {
            if (loading.contains (symbol)) continue;
            var q = p.quotes[symbol];
            if (q == null) {
                load_symbol.begin (symbol);
                continue;
            }
            // A pair we only convert totals through needn't be to the minute: a quarter of an hour will do.
            bool due = p.tracks (symbol) ? q.due (now) : now - q.refreshed >= 900;
            if (all && (force || due)) stale.add (q);
        }
        if (stale.length > 0) freshen.begin (stale, false, force);
    }

    // Bring quotes we hold up to date, all in one go so that the feed can answer for many at once.
    // A background round reports an outage once, not every two minutes. `thorough`: see Feed.refresh.
    async void freshen (GenericArray<Quote> quotes, bool asked = false, bool thorough = false) {
        for (int i = 0; i < quotes.length; i++) loading.add (quotes[i].symbol);
        show_status ();
        var wrong = yield feed.refresh (quotes, thorough);
        if (wrong != null && (asked || !failing)) fail (wrong);
        if (wrong != null && !asked) round_failed = true;
        for (int i = 0; i < quotes.length; i++) loading.remove (quotes[i].symbol);
        settle ();
    }

    // A symbol we hold nothing of yet: out of the cache and freshened if it has been seen before,
    // otherwise its one big download. `asked`: the user is waiting on it, so always say why it failed.
    async void load_symbol (string symbol, bool asked = false) {
        var q = feed.cached (symbol);
        if (q != null) {
            p.quotes[symbol] = q;   // shown as it was, even if the refresh fails
            var one = new GenericArray<Quote> ();
            one.add (q);
            yield freshen (one, asked);
        } else {
            loading.add (symbol);
            show_status ();
            try {
                p.quotes[symbol] = yield feed.download (symbol);
            } catch (Error e) {
                if (asked || !failing) fail (@"$symbol: $(e.message)");
                if (!asked) round_failed = true;
            }
            loading.remove (symbol);
            settle ();
        }
        if (p.quotes.contains (symbol)) sync ();   // a new holding can need FX pairs we don't have yet
    }

    // After each load: once nothing is loading any more, the round is over.
    void settle () {
        if (loading.length == 0) {
            fetch_stats.begin ();
            updated = new DateTime.now_local ().format (round_failed ? "Update failed %H:%M" : "Updated %H:%M");
            failing = round_failed;
            round_failed = false;
            // Dev aids, see the Makefile.
            var shot = Environment.get_variable ("STONKS_SHOT");
            var pin = (Environment.get_variable ("STONKS_PIN") ?? "").split (",");
            if (pin.length > 0) Timeout.add (500, () => { chart.pin (double.parse (pin[0]), double.parse (pin[pin.length - 1])); return Source.REMOVE; });
            if (shot != null) Timeout.add (int.parse (Environment.get_variable ("STONKS_WAIT") ?? "1500"), () => { snapshot_to (shot); return Source.REMOVE; });
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
        // Beside the search field: keep the search to one market. "Auto" searches everywhere.
        var markets = new Gtk.StringList (null);
        for (int i = 0; i < Feed.MARKETS.length; i += 2) markets.append (Feed.MARKETS[i]);
        var market = new Gtk.DropDown (markets, new Gtk.PropertyExpression (typeof (Gtk.StringObject), null, "string")) {
            enable_search = true, search_match_mode = Gtk.StringFilterMatchMode.SUBSTRING,
            valign = Gtk.Align.CENTER, tooltip_text = "Search within one market"
        };
        symbol.add_suffix (market);
        market.notify["selected"].connect (() => { Signal.emit_by_name (symbol, "changed"); });   // search again, there

        var stock = new Adw.PreferencesGroup () {
            title = "Stock",
            description = "Search by name or ticker: AAPL, 7203.T, 005930.KS, 600519.SS, or PVS.VN for any Vietnamese exchange. Pick a market beside the field to search only there."
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
        var all = p.folders ();
        var choices = new Gtk.StringList (null);
        choices.append ("None");
        for (int i = 0; i < all.length; i++) choices.append (path_of (all[i]));
        var folder = new Adw.ComboRow () { title = "Folder", subtitle = "Where it sits on the heatmap", model = choices };
        for (int i = 0; draft != null && i < all.length; i++) if (all[i].id == draft.group) folder.selected = i + 1;
        // Until the user picks one, a folder is suggested (see autofill): "suggest" holds which, "chosen" that they did.
        for (int i = all.length - 1; i >= 0; i--) if (all[i].arrange == Arrange.ROW || all[i].arrange == Arrange.COLUMN) folder.set_data<uint> ("suggest", i + 1);
        folder.set_data<bool> ("chosen", folder.selected > 0);
        folder.notify["selected"].connect (() => { if (!folder.get_data<bool> ("suggesting")) folder.set_data<bool> ("chosen", true); });
        var filing = new Adw.PreferencesGroup () { visible = all.length > 0 };
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
                if (mine == serial) feed.search.begin (text, p.currency, Feed.MARKETS[market.selected * 2 + 1], (obj, res) => {
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
            autofill (symbol, shares, date, price, folder);
        });
        shares.changed.connect (() => autofill (symbol, shares, date, price, folder));
        date.changed.connect (() => autofill (symbol, shares, date, price, folder));

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
            lot.group = folder.selected > 0 ? all[(int) folder.selected - 1].id : "";
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

    // Fill in what the add dialog can work out once it knows the symbol's quote.
    //  - The close on the buy date goes into the price row, unless the user has typed a price of their
    //    own. The row remembers what was filled in ("auto") so a later date change can replace it.
    //  - Something to watch that isn't a company's stock (an index, a fund, a pair) is offered the
    //    first strip there is as its folder, until the user picks a folder themselves.
    void autofill (Adw.EntryRow symbol, Adw.EntryRow shares, Adw.EntryRow date, Adw.EntryRow price, Adw.ComboRow folder) {
        var asked = symbol.text.strip ().up ();
        if (asked == "") return;
        peek.begin (asked, (obj, res) => {
            var q = peek.end (res);
            if (q != null && symbol.text.strip ().up () == asked && !folder.get_data<bool> ("chosen")) {
                folder.set_data<bool> ("suggesting", true);
                folder.selected = !q.is_stock && shares.text.strip () == "" ? folder.get_data<uint> ("suggest") : 0;
                folder.set_data<bool> ("suggesting", false);
            }
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
                if (chosen != "" && chosen != other.group) {
                    p.assign (lot.symbol, chosen);
                    rearranged ();
                } else toasts.add_toast (new Adw.Toast (@"$(lot.symbol) is already listed"));
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

    // Take a symbol off the list, every lot of it, with a way back.
    void remove_symbol (string symbol) {
        Lot[] gone = {};
        uint[] places = {};
        for (int i = (int) p.lots.get_n_items () - 1; i >= 0; i--) {
            var lot = (Lot) p.lots.get_item (i);
            if (lot.symbol != symbol) continue;
            gone += lot;
            places += (uint) i;
            p.lots.remove (i);
        }
        if (gone.length == 0) return;
        save ();
        update ();
        var toast = new Adw.Toast (@"Removed $symbol") { button_label = "Undo" };
        toast.button_clicked.connect (() => {
            for (int i = gone.length - 1; i >= 0; i--) p.lots.insert (uint.min (places[i], p.lots.get_n_items ()), gone[i]);   // lowest place first
            save ();
            update ();
        });
        toasts.add_toast (toast);
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
            if (saved.has_member ("heatmap")) {
                read_folder (saved.get_object_member ("heatmap"), p.root);
            } else {
                // A file from before folders nested and had layouts: just their names, which serve as
                // their ids from here on. Keep a copy of it as it was, the once.
                upgrading = true;
                if (!FileUtils.test (path + ".before-layouts", FileTest.EXISTS)) {
                    try { FileUtils.set_contents (path + ".before-layouts", text); } catch (Error e) {}
                }
                if (saved.has_member ("groups")) saved.get_array_member ("groups").foreach_element ((array, i, name) => {
                    if (name.get_node_type () == Json.NodeType.VALUE && name.get_string () != null) p.add_group (name.get_string (), p.root).id = name.get_string ();
                });
                // A folder some lot names but the list forgot (a hand-edited file) still exists.
                for (uint i = 0; i < p.lots.get_n_items (); i++) {
                    var group = ((Lot) p.lots.get_item (i)).group;
                    if (group != "" && p.folder (group) == p.root) p.add_group (group, p.root).id = group;
                }
            }
        } catch (Error e) {
            // Move it aside so the next save can't overwrite a file we failed to read.
            FileUtils.rename (path, path + ".bad");
            fail (@"Couldn't read the saved portfolio; kept it as $path.bad");
        }
    }

    // A folder as saved, and those inside it.
    Json.Object folder_json (Group g) {
        var o = new Json.Object ();
        if (g != p.root) {
            o.set_string_member ("id", g.id);
            o.set_string_member ("name", g.name);
            o.set_int_member ("dock", g.dock);
            o.set_double_member ("size", g.size);
            o.set_boolean_member ("scroll", g.scroll);
        }
        o.set_int_member ("arrange", g.arrange);
        var inner = new Json.Array ();
        for (int i = 0; i < g.children.length; i++) inner.add_object_element (folder_json (g.children[i]));
        o.set_array_member ("folders", inner);
        return o;
    }

    void read_folder (Json.Object o, Group g) {
        g.arrange = (Arrange) o.get_int_member_with_default ("arrange", 0).clamp (0, Arrange.FIBONACCI);
        g.dock = (Dock) o.get_int_member_with_default ("dock", 0).clamp (0, Dock.RIGHT);
        g.size = o.get_double_member_with_default ("size", 0).clamp (0, 0.8);
        g.scroll = o.get_boolean_member_with_default ("scroll", false);
        if (!o.has_member ("folders")) return;
        o.get_array_member ("folders").foreach_element ((array, i, node) => {
            if (node.get_node_type () != Json.NodeType.OBJECT) return;
            var inner = node.get_object ();
            var child = p.add_group (inner.get_string_member_with_default ("name", ""), g);
            child.id = inner.get_string_member_with_default ("id", child.id);
            read_folder (inner, child);
        });
    }

    void save () {
        var lots = new Json.Array ();
        for (uint i = 0; i < p.lots.get_n_items (); i++) lots.add_element (Json.gobject_serialize (p.lots.get_item (i)));
        var saved = new Json.Object ();
        saved.set_string_member ("currency", p.currency);
        saved.set_boolean_member ("tile_charts", tile_charts);
        saved.set_object_member ("heatmap", folder_json (p.root));
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
