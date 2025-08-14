# VendorFilter (MoP Classic)

VendorFilter adds a dropdown to the Merchant frame to filter items by type (e.g., Shoulders). It builds the dropdown dynamically from the items that the current vendor actually sells, and when filtered, shows a clean scrollable list with prices and currencies.

## Features
- Dynamic filter dropdown based on the current vendor’s items (no hardcoded list)
- “All” option restores Blizzard’s default grid and paging
- Scrollable overlay list when a filter is active (no taint, FauxScrollFrame)
- Affordability coloring for gold and currencies (green = enough, red = not enough)
- Buy button per row (disabled if sold out or unaffordable)
- Shift-click Buy purchases max stack for gold-only items
- Friendly label for non-equippable entries (INVTYPE_NON_EQUIP_IGNORE → “Misc (Currency/Satchels)”) 

## Install
1) Exit the game.
2) Copy the entire `VendorFilter` folder to your AddOns directory:
	- Windows (MoP Classic/Classic-like): `World of Warcraft/_classic_/Interface/AddOns/`
3) Launch the game and enable “Load out of date AddOns” if needed.

## Usage
1) Open a vendor (e.g., Avatar of the August Celestials).
2) Use the “Filter: …” dropdown at the top of the Merchant frame.
	- Pick a type like “Shoulder” to see only those items.
	- Pick “All” to return to Blizzard’s grid and paging.
3) In filtered mode, use the Buy button on each row.
	- Shift-click buys a full stack when possible (gold-only, non-extended-cost items).

## Notes / Compatibility
- The addon uses `GetItemInfoInstant` when available, falling back to `GetItemInfo` until the client caches data.
- Costs for extended-currency items show as icon + amount with green/red coloring based on what you have.
- If your client variant uses slightly different Merchant update functions, the addon calls common, safe refreshes.

## Troubleshooting
- “All” shows nothing: Try closing and reopening the vendor. We explicitly restore Blizzard’s grid; if another addon interferes, load only VendorFilter and retry.
- Buy does nothing: You may not have enough currency; the Buy button disables if unaffordable. Hover the button to see a detailed breakdown.
- Dropdown missing categories: The list is dynamic; change vendors or wait for item info to cache.

## Development
Project files:
- `VendorFilter.toc` — addon manifest
- `VendorFilter.lua` — addon logic, dropdown, filtering, overlay list
- `VendorFilterDropdown.xml` — reserved for future skinning (currently minimal)

Key concepts (high level):
- Compute filters: scan vendor items, collect their equip locations (INVTYPE_*), map to labels.
- Filtering: when a filter is active, hide the Blizzard grid and draw our own scrollable rows.
- Restoring: selecting “All” hides our overlay and restores Blizzard’s grid and paging.
- Affordability: compare your gold and currency/item counts against costs to colorize and enable/disable Buy.

Contributing:
- Keep UI logic isolated; avoid calling Blizzard helpers that depend on internal frames.
- Keep dynamic dropdown generation fast—scan once per vendor refresh.
- PRs for localization and additional filters (quality/class/armor type) are welcome.

## Releasing on CurseForge
- This repository includes `.pkgmeta` for the CurseForge/WowAce packager.
- Tag a release (e.g., `v0.1.0`) and upload the packaged zip (or let the packager build it).
- Ensure `VendorFilter.toc` has the correct `## Interface` value for the current client.
- Include `CHANGELOG.md` updates for each release.
