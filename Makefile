# Stonks: GTK4/libadwaita portfolio tracker in Vala.
#
#   make            build/stonks, needs the gtk4, libadwaita, libsoup3, json-glib and sqlite -devel packages
#   make sdk        the same, compiled inside the GNOME SDK flatpak (Silverblue hosts without those headers);
#                   the binary still runs natively on the host
#   make check      run the portfolio-math self-check
#   make install    install binary, launcher, icon and metainfo into ~/.local  (e.g. `make sdk install`)
#
# As a Flatpak: flatpak run org.flatpak.Builder --user --install --force-clean build/flatpak io.github.igneous.Stonks.yml
#
# Dev aid: STONKS_SHOT=out.png [STONKS_VIEW=stocks|heatmap|performance] [STONKS_RANGE=0..6] [STONKS_ROW=n] [STONKS_SIZE=1000x700]
# [STONKS_PIN=0.3 or 0.3,0.8] [STONKS_WAIT=milliseconds] build/stonks renders the window to a PNG once quotes
# have loaded (and STONKS_WAIT has passed: 1500 unless said), then quits. STONKS_PIN pins a point of the
# chart, or a span, by how far across it they are. To keep it off your desktop:
#   mutter --headless --no-x11 --wayland-display shots --virtual-monitor 1400x1000 &
#   WAYLAND_DISPLAY=shots XDG_DATA_HOME=/some/test/dir STONKS_SHOT=out.png build/stonks
# A STONKS_SHOT run is a separate instance, so it works while the app is open. Don't isolate test runs
# with dbus-run-session: the portals it starts unmount the real session's /run/user/UID/doc on exit.

APP    = io.github.igneous.Stonks
PREFIX ?= $(HOME)/.local
SDK    ?= org.gnome.Sdk//51
PKGS   = --pkg gtk4 --pkg libadwaita-1 --pkg libsoup-3.0 --pkg json-glib-1.0 --pkg sqlite3
SRC    = src/model.vala src/cache.vala src/feed.vala src/chart.vala src/heatmap.vala src/window.vala
VALAC  = valac -X -lm -X -w -X -O2

build/stonks: $(SRC)
	@mkdir -p build
	$(VALAC) $(PKGS) $(SRC) -o $@

build/test: src/model.vala src/cache.vala src/test.vala
	@mkdir -p build
	$(VALAC) --pkg gio-2.0 --pkg sqlite3 $^ -o $@

check: build/test
	build/test
	@v=`sed -n 's/.*const string VERSION = "\(.*\)";.*/\1/p' src/feed.vala`; grep -q "<release version=\"$$v\"" data/$(APP).metainfo.xml \
		|| { echo "data/$(APP).metainfo.xml has no release $$v (VERSION in src/feed.vala)"; exit 1; }

sdk:
	flatpak run --filesystem=$(CURDIR) --command=make $(SDK) -C $(CURDIR) build/stonks check

install: build/stonks
	install -Dm755 build/stonks $(PREFIX)/bin/stonks
	install -Dm644 data/$(APP).svg $(PREFIX)/share/icons/hicolor/scalable/apps/$(APP).svg
	install -Dm644 data/$(APP).desktop $(PREFIX)/share/applications/$(APP).desktop
	install -Dm644 data/$(APP).metainfo.xml $(PREFIX)/share/metainfo/$(APP).metainfo.xml
	sed -i 's|^Exec=.*|Exec=$(PREFIX)/bin/stonks|' $(PREFIX)/share/applications/$(APP).desktop

uninstall:
	rm -f $(PREFIX)/bin/stonks $(PREFIX)/share/icons/hicolor/scalable/apps/$(APP).svg $(PREFIX)/share/applications/$(APP).desktop $(PREFIX)/share/metainfo/$(APP).metainfo.xml

clean:
	rm -rf build

.PHONY: check sdk install uninstall clean
