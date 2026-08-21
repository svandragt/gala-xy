project('gala-xy', 'vala', 'c', version: '0.2.0')

gnome = import('gnome')

gala_dep = dependency('gala')
libmutter_dep = dependency('libmutter-14')
mutter_dep = [
    libmutter_dep,
    dependency('mutter-mtk-14'),
    dependency('mutter-cogl-14'),
    dependency('mutter-cogl-pango-14'),
    dependency('mutter-clutter-14'),
]

plugins_dir = gala_dep.get_variable(pkgconfig: 'libdir') / 'gala' / 'plugins'
mutter_typelib_dir = libmutter_dep.get_variable(pkgconfig: 'typelibdir')

# Ubuntu's libmutter-14-dev ships no Vala vapi; Gala vendors and maintains
# its own in-tree, so point valac at a Gala source checkout's copy.
gala_vapi_dir = get_option('gala_vapi_dir')
add_project_arguments([
    '--vapidir', gala_vapi_dir,
    '--define', 'HAS_MUTTER43',
    '--define', 'HAS_MUTTER44',
    '--define', 'HAS_MUTTER45',
    '--define', 'HAS_MUTTER46',
], language: 'vala')

install_data(
    'data/org.pantheon.desktop.gala.plugins.xy.gschema.xml',
    install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

shared_library('gala-xy',
    files(
        'src/Main.vala',
        'src/FocusRing.vala',
        'src/WindowSwitcher.vala',
    ),
    dependencies: [gala_dep, dependency('gee-0.8'), dependency('gio-unix-2.0'), dependency('pango'), dependency('pangocairo'), dependency('gdk-pixbuf-2.0'), dependency('granite-7'), dependency('gtk4')] + mutter_dep,
    install: true,
    install_dir: plugins_dir,
    install_rpath: mutter_typelib_dir,
)

# Switchboard settings plug: a GUI over the same gsettings keys the plugin
# itself reads (keybindings + window-exclusion lists), nothing more.
switchboard_dep = dependency('switchboard-3')
switchboard_plugs_dir = switchboard_dep.get_variable(pkgconfig: 'plugsdir')

shared_module('xy-settings',
    files(
        'switchboard-plug/Plug.vala',
        'switchboard-plug/SettingsView.vala',
    ),
    dependencies: [switchboard_dep, dependency('granite-7'), dependency('gtk4'), dependency('gee-0.8')],
    install: true,
    install_dir: switchboard_plugs_dir / 'personal',
)

gnome.post_install(glib_compile_schemas: true)
