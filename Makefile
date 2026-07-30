BUILD_DIR := build
PLUGIN_DIR := /usr/lib/x86_64-linux-gnu/gala/plugins
SWITCHBOARD_PLUG_DIR := /usr/lib/x86_64-linux-gnu/switchboard-3/personal
# meson's default prefix is /usr/local, so install_data() puts the gschema
# here — not next to the .so's, which land under /usr/lib via gala's and
# switchboard's own pkg-config paths.
SCHEMA_DIR := /usr/local/share/glib-2.0/schemas
SCHEMA := org.pantheon.desktop.gala.plugins.xy.gschema.xml

.PHONY: all setup build install uninstall clean lint format

all: build

setup:
	meson setup $(BUILD_DIR)

build: setup
	ninja -C $(BUILD_DIR)

install: build
	sudo ninja -C $(BUILD_DIR) install

uninstall:
	sudo rm -f $(PLUGIN_DIR)/libgala-xy.so
	sudo rm -f $(SWITCHBOARD_PLUG_DIR)/libxy-settings.so
	sudo rm -f $(SCHEMA_DIR)/$(SCHEMA)
	sudo glib-compile-schemas $(SCHEMA_DIR)

clean:
	rm -rf $(BUILD_DIR)

lint:
	io.elementary.vala-lint src/*.vala switchboard-plug/*.vala

format:
	io.elementary.vala-lint -f src/*.vala switchboard-plug/*.vala
