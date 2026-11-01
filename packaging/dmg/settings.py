# Booth's disk image, for dmgbuild (make-dmg.sh runs it): Booth beside a link to Applications in
# a plain window with the drop zone drawn around the link. Pass the app and this folder's
# background.tiff with `-D app=PATH -D background=PATH`.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821

format = "ULFO"  # lzfse: smaller and faster to open than zlib, and every macOS Booth runs on reads it
filesystem = "HFS+"
files = [(app, "Booth.app")]
symlinks = {"Applications": "/Applications"}
# The volume's own icon, on the desktop and in the sidebar while the image is open.
icon = os.path.join(app, "Contents", "Resources", "Booth.icns")

# 300 points of the background show under the title bar and macOS 26's tab bar (67 points);
# earlier macOS has only the title bar and shows the 40 more the background runs to.
window_rect = ((240, 160), (600, 367))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
# Icon centres, matching background.html.
icon_locations = {"Booth.app": (160, 124), "Applications": (440, 124)}
