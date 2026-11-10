# Changelog

This project follows semantic versioning. Release dates use ISO 8601 format.

## Unreleased

- Fixed screenshots going missing after the screenshot folder moves, such as when Desktop & Documents
  moves to iCloud Drive or the macOS screenshot location changes.
- Made the whole thumbnail the copy target and moved the annotation controls to its corner, so a
  near miss still copies.
- The menu closes after a copy and opens at the newest image.

## 1.0.0

- Added a menu bar history for screenshots and clipboard images.
- Added text and arrow annotation.
- Added persistent local history with a ten-image limit.
- Added an opt-in launch-at-login setting.
- Kept full-size images on disk and thumbnails in memory.
