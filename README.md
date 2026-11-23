# Icon Picker Search

A World of Warcraft addon that adds a search box to icon pickers.

It works with every picker built on Blizzard's shared `IconSelectorPopupFrameTemplate`:

- Equipment Manager (new or edit set)
- Macros (`/macro` → New / Change Name/Icon)
- Guild bank tab icons
- Any other addon that reuses the template

## What you can search

- **Icon file names**: `sword`, `inv_misc_gem`, `ability_rogue`. About 34k names come from the community listfile.
- **Names from your character**: spells in your spellbook, collected mounts, equipped gear and items in your bags. For example, `fireball` finds the Fireball icon.
- **File IDs**: `134400`
- **Several words**: `sword fire` must match both words. Put `-` before a word to exclude it: `sword -fire`.

Results are deduplicated. Clicking a result, the OK button and the All/Spell/Item dropdown all behave as normal.

## Install

Copy the `IconPickerSearch` folder into:

```
World of Warcraft/_retail_/Interface/AddOns/
```

If your client's interface version is newer than the one in `IconPickerSearch.toc`, update that number or enable "Load out of date AddOns".

`/iconsearch` prints how many icon names are loaded and how many pickers are hooked. `/iconsearch debug` toggles error output from the name collectors.

## How it works

Each picker reads icons through three frame methods: `GetIconByIndex`, `GetNumIcons` and `GetIndexOfIcon`. The addon wraps these on each frame instance. While a search is active they return a filtered list, so Blizzard's own selection and save code runs unchanged.

Pickers are found by hooking `IconSelectorPopupFrameTemplateMixin.OnShow`. Every subclass calls it before its own `Update()`, so load-on-demand pickers such as the macro UI are covered too.

## Regenerating the icon name list

When a patch adds icons:

```bash
python3 tools/build_icon_names.py
```

This downloads the latest [wowdev/wow-listfile](https://github.com/wowdev/wow-listfile) and rewrites `IconPickerSearch/IconNames.lua`. You can also pass a local `community-listfile.csv` path.

## Offline test

```bash
lua5.1 tools/test_harness.lua
```

This stubs the WoW API and Blizzard's picker to check the hook and filter logic. It does not replace testing in the game.
