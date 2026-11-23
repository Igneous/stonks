# Stonks: GTK4/libadwaita portfolio tracker in Vala.
#
#   make            build/stonks, needs the gtk4, libadwaita, libsoup3 and json-glib -devel packages
#   make sdk        the same, compiled inside the GNOME SDK flatpak (Silverblue hosts without those headers);
#                   the binary still runs natively on the host
#   make check      run the portfolio-math self-check
#   make install    install binary, launcher and icon into ~/.local  (e.g. `make sdk install`)
#
# Dev aid: STONKS_SHOT=out.png [STONKS_VIEW=stocks|heatmap|performance] [STONKS_RANGE=0..6] [STONKS_ROW=n]
# build/stonks renders the window to a PNG once quotes have loaded, then quits. To keep it off your desktop:
#   mutter --headless --no-x11 --wayland-display shots --virtual-monitor 1400x1000 &
#   WAYLAND_DISPLAY=shots XDG_DATA_HOME=/some/test/dir STONKS_SHOT=out.png build/stonks
# A STONKS_SHOT run is a separate instance, so it works while the app is open. Don't isolate test runs
# with dbus-run-session: the portals it starts unmount the real session's /run/user/UID/doc on exit.

APP    = io.github.igneous.Stonks
PREFIX ?= $(HOME)/.local
SDK    ?= org.gnome.Sdk//48
PKGS   = --pkg gtk4 --pkg libadwaita-1 --pkg libsoup-3.0 --pkg json-glib-1.0
SRC    = src/model.vala src/feed.vala src/chart.vala src/heatmap.vala src/window.vala
VALAC  = valac -X -lm -X -w -X -O2

build/stonks: $(SRC)
	@mkdir -p build
	$(VALAC) $(PKGS) $(SRC) -o $@

build/test: src/model.vala src/test.vala
	@mkdir -p build
	$(VALAC) --pkg gio-2.0 $^ -o $@

check: build/test
	build/test

sdk:
	flatpak run --filesystem=$(CURDIR) --command=make $(SDK) -C $(CURDIR) build/stonks check

install: build/stonks
	install -Dm755 build/stonks $(PREFIX)/bin/stonks
	install -Dm644 data/$(APP).svg $(PREFIX)/share/icons/hicolor/scalable/apps/$(APP).svg
	install -Dm644 data/$(APP).desktop $(PREFIX)/share/applications/$(APP).desktop
	sed -i 's|^Exec=.*|Exec=$(PREFIX)/bin/stonks|' $(PREFIX)/share/applications/$(APP).desktop

uninstall:
	rm -f $(PREFIX)/bin/stonks $(PREFIX)/share/icons/hicolor/scalable/apps/$(APP).svg $(PREFIX)/share/applications/$(APP).desktop

clean:
	rm -rf build

.PHONY: check sdk install uninstall clean
