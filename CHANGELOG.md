# Changelog

The version lives in `manifest.json`. Every release bumps it, adds an entry
here, and is tagged `vX.Y.Z`: a fix bumps the patch, a new capability the minor.

## 1.2.0 - 2026-09-15

### Performance
- **The panel builds a dashboard when you open it, not on every click.** Every
  domain's whole dashboard, plus Overview, Constraints, Settings, About and the
  chooser, was constructed before anything appeared, and `visible: false` still
  builds the tree. Each domain's dashboard is now created the first time you
  open that domain and kept while you stay on it. Thanks to @jbronssin (#2).

### Fixed
- **The bar chips no longer paint a slab over a transparent bar.** Each chip
  filled itself with the bar's surface colour, which is invisible on a solid bar
  and a 26 px plate over the wallpaper on a transparent one; an inactive reading
  used a muted colour chosen to sit on that slab. The chips now read the bar's
  own ink and drop the fill when the bar is transparent. Thanks to
  @dadofsambonzuki (#3).
- **The installer no longer damages the directory it installs into.** Publishing
  deleted `.git`, `docs/`, `tools/`, `CHANGELOG.md` and the installer itself from
  a directory `omarchy plugin add` had cloned into; a failed swap could leave no
  plugin directory at all while reporting the previous release was still in
  place; and a missed rescan rolled back an install that had in fact completed.
  Thanks to @dadofsambonzuki (#4).
- **Columns follow the screen.** The panel now widens up to 2000 px on a large
  display instead of a fixed 1240, and the Wi-Fi rows and interface cards take
  their column count from the width they are given. Seven interface cards were
  stacking into rows that ran off a 5120x1440 screen.

## 1.1.1 — 2026-09-13

### Fixed
- **Pages no longer run past the bottom of the screen.** Measured on a
  1600×1000 display, six pages needed up to 1,697 px of a 960 px budget. The
  panel is now 1,240 px wide and uses that width instead of height: Settings is
  a 2×2 grid, the Wi-Fi list and the interface cards sit in columns, the
  thread grid and Storage-lab tiles spread to fill the card, and the hogs tables
  and Disk Overview are tighter. Every fixed page now fits. Nothing was removed.
  Only an open-ended list, such as a machine with many interfaces, may scroll.
- `status` reports `contentNeeded`, `availableHeight` and `availableWidth`, so a
  page that outgrows the screen can be caught by measurement rather than by eye.

## 1.1.0 — 2026-09-12

### Added
- **One auto-switching bar icon.** The icon becomes whichever of CPU, RAM, Disk
  and Network is currently the biggest constraint and names it, or reads
  ALL CLEAR when nothing is tight. It needs a clear lead before changing hands,
  and an offline recorder always takes it.
- **Constraints page.** All four domains ranked worst first on one shared 0–1
  severity scale, each reading with a value and a sentence on what it costs.
- **Right-click chooser.** Every readout across the four domains, priced against
  live values. Pick one to pin the icon, or Auto to release it.
- **nixfred.com byline** on the About page, the README and the announcement card.
- The version now leads the bar tooltip, and the README badge reads it straight
  from `manifest.json`.

### Performance
- Opening the panel no longer stalls the shell. The four Overview chips blurred
  their outline on the GUI thread at up to 69 ms per paint; the glow is now drawn
  with a few fading strokes. Worst GUI stall on open went from 768–848 ms to
  138–170 ms.
- The collectors no longer walk every process for the hogs tables unless that
  tab is open, and the CPU collector caches the power profile instead of forking
  `powerprofilesctl` every three seconds. Idle cost fell from 14.5% to 4.3% of a
  core.

### Fixed
- An idle drive was reported as critical because terminals waiting on io_uring
  (Ghostty) inflate `/proc/pressure/io`. I/O pressure now only counts when a drive
  agrees. (#1)
- Thermal throttle counters are cumulative since boot, so any machine that had
  ever throttled read as throttling forever. The collector now reports a smoothed
  rate.
- Pulse could not run without the four plugins it replaced: the systemd units
  pointed at their directories. They now run Pulse's own collectors.
- The bar entry could grow into the widget beside it. Captions are shorter and
  bounded, and a sizing loop that could drop the chip from the measured width is
  gone.
- The installer now rolls back if its second phase fails, handles a machine with
  no `shell.json` yet, and accepts bare-string layout entries.
- Swap was measured with zram folded in, zram's fields were misread, a binding
  loop flickered the panel width, the bar collapsed on vertical bars, and the
  About links could block the shell. All fixed, along with a dozen smaller
  defects from two independent reviews.

## 1.0.0 — 2026-09-11

- CPU Pulse, RAM Pulse, Disk Pulse and Net Pulse merged into one plugin, each
  keeping its full original dashboard behind its own page, with a new Overview
  and a merged Settings page.
