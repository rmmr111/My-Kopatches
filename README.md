# KOReader Custom Patches

A small collection of patches I **currently use with KOReader** on my Kobo Libra 2. These are personal customizations that I'm sharing in case others find them useful.

## Patches

- **Clean Bar** (`2-clean-bar.lua`) — A customizable top-menu toolbar with quick actions, icons, lighting controls, and configurable menus.
- **Physical Page Count** (`2-physical-page-count.lua`) — Adjusts a book's stable page numbering to approximate the printed edition's page count.
- **Physical Page Statistics** (`2-physical-page-statistics.lua`) — Keeps the Statistics plugin's page totals and progress aligned with the configured physical page count. Use together with Physical Page Count.
- **Hide NEW Prefix** (`2-ocultar-prefixo-novo.lua`) — Hides the “NEW” prefix in menu items without hiding the items themselves.

## Installation

Copy the `.lua` files you want to use into `.adds/koreader/patches/` on your Kobo, then restart KOReader.

**Clean Bar icon files are not included in this archive.** Its custom SVG icons need to be placed under `.adds/koreader/icons/cleanbar/` for the complete interface to display properly. The icons will need to be added separately.

These patches are from my current setup; compatibility with all KOReader versions or other devices is not guaranteed.

## Credits

**Clean Bar** is based on the **Quick Settings** patch (`2-quick-settings.lua`) by [qewer33](https://github.com/qewer33/koreader-patches). Thanks to the original author for their work!
