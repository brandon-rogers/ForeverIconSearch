# Forever Icon Search

A World of Warcraft addon that adds a search box to icon pickers.

It works with every picker built on Blizzard's shared `IconSelectorPopupFrameTemplate`:

- Equipment Manager (new or edit set)
- Macros (`/macro` → New / Change Name/Icon)
- Guild bank tab icons
- Any other addon that reuses the template

## What you can search

- **Icon file names**: `sword`, `inv_misc_gem`, `ability_rogue`. About 34k names come from the community listfile.
- **Spell and item names**: every spell and item in WoW: Forever that uses the icon, whether or not your character has it. For example, `razzashi` finds `ability_mount_raptor`. That's about 37k names across 4k icons, from the game's own data tables.
- **Names from your character**: spells in your spellbook, collected mounts, equipped gear and items in your bags. This covers anything newer than the bundled data.
- **File IDs**: `134400`
- **Several words**: `sword fire` must match both words. Put `-` before a word to exclude it: `sword -fire`.

Results are deduplicated. Clicking a result, the OK button and the All/Spell/Item dropdown all behave as normal.

## Install

Copy the `ForeverIconSearch` folder into:

```
World of Warcraft/_forever_/Interface/AddOns/
```

If your client's interface version is newer than the one in `ForeverIconSearch.toc`, update that number or enable "Load out of date AddOns".

`/iconsearch` prints how many icon names and spell/item names are loaded, and how many pickers are hooked. `/iconsearch debug` toggles error output from the name collectors.

## How it works

Each picker reads icons through three frame methods: `GetIconByIndex`, `GetNumIcons` and `GetIndexOfIcon`. The addon wraps these on each frame instance. While a search is active they return a filtered list, so Blizzard's own selection and save code runs unchanged.

Pickers are found by hooking `IconSelectorPopupFrameTemplateMixin.OnShow`. Every subclass calls it before its own `Update()`, so load-on-demand pickers such as the macro UI are covered too.

## Regenerating the search data

When a patch adds icons, spells or items:

```bash
python3 tools/build_icon_names.py
```

This rewrites two generated files:

- `ForeverIconSearch/IconNames.lua`: icon file names, from the latest [wowdev/wow-listfile](https://github.com/wowdev/wow-listfile).
- `ForeverIconSearch/IconGameNames.lua`: the spell and item names that use each icon, built from the WoW: Forever game tables (`SpellName`, `SpellMisc`, `ItemSparse`, `Item`) on [wago.tools](https://wago.tools).

Run it with `--help` for options, such as using local copies or rebuilding only one file.

## Offline test

```bash
lua5.1 tools/test_harness.lua
```

This stubs the WoW API and Blizzard's picker to check the hook and filter logic. It does not replace testing in the game.

## Releasing

Pushing a `v*` tag runs the [BigWigs packager](https://github.com/BigWigsMods/packager) in GitHub Actions. It builds the zip, uploads it to [CurseForge](https://www.curseforge.com/wow/addons/forever-icon-search) and creates the GitHub release. The version in the `.toc` is filled in from the tag.

```bash
git tag v0.1.1
git push origin v0.1.1
```

This needs a CurseForge API token stored as the `CF_API_KEY` repository secret.

## License

[MIT](LICENSE). `ForeverIconSearch/IconNames.lua` is generated from the [wowdev/wow-listfile](https://github.com/wowdev/wow-listfile) community listfile. `ForeverIconSearch/IconGameNames.lua` is generated from game data published on [wago.tools](https://wago.tools).
