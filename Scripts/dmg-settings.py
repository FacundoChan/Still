# dmgbuild settings for Still's DMG window. Scripts/package.sh passes the paths with -D.
#
# The icon positions match the background drawn by Scripts/dmg-background.swift, which is 660 × 400 points.

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Still.app"]
icon = defines["volume_icon"]

background = defines["background"]
# The window's frame, title bar included. The bottom of the background stays empty, where Finder's path bar can cover it.
window_rect = ((200, 160), (660, 420))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False

icon_size = 128
text_size = 14
icon_locations = {"Still.app": (170, 150), "Applications": (490, 150)}

format = "UDZO"
filesystem = "APFS"
