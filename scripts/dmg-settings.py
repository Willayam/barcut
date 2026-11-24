# dmgbuild settings for the BarCut installer window.
# Icon positions line up with the plate and arrow drawn in Assets/dmg-background.tiff.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
background = "Assets/dmg-background.tiff"
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
# Height includes the 32 pt title bar, so the 640x400 background shows in full.
window_rect = ((200, 120), (640, 432))
icon_size = 128
text_size = 16  # matches the see.computer installer, which Tauri builds at 16
icon_locations = {os.path.basename(app): (170, 214), "Applications": (470, 214)}
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
format = "UDZO"
