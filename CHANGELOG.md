# Changelog

The version lives in `manifest.json`. Every release bumps it, adds an entry
here, and is tagged `vX.Y.Z`: a fix bumps the patch, a new capability the minor.

## 1.3.0 - 2026-09-19

### Added
- **A fifth domain: GPU.** Everything the other four have. An Overview with a
  live die and a VRAM band, a GPU hogs tab, a Graphics lab, an About page, four
  bar readouts (busy, VRAM, temperature, power), constraint scoring on the same
  shared severity scale, seven days of history at the same three ranges, and a
  place in the auto-switching bar icon. The GPU can now take the icon when it is
  the thing holding the machine back.
- **NVIDIA cards are read through the driver's own library, not `nvidia-smi`.**
  A full sample measures 0.017 ms against 46-52 ms to fork that program, which
  is roughly 2,800x cheaper, and it also reports the enforced power limit that
  `nvidia-smi` leaves as N/A on this laptop. Intel and AMD cards are read from
  the kernel's own sysfs counters. Fields a card does not support come back as a
  dash rather than a confident zero: this laptop reports no fan speed.
- **Every GPU is listed, not just the first.** A laptop with a discrete card and
  an integrated one shows both; the discrete one leads the readings because it
  is the one that runs out of memory and holds work up.
- **The GPU hogs tab names what holds video memory**, with the model name pulled
  out of the command line, and the scan is demand-gated like the other process
  tables: nothing is walked unless that tab is open.

### Fixed
- The Constraints page laid its domains out in a single column, which needed
  1,042 px of a 960 px laptop screen once there were five. It now uses two
  columns and needs 757.

### Notes
- GPU throttle counters are cumulative since boot, and a laptop card sits at its
  board power limit essentially always, so the raw total reads as "throttled for
  days" on a perfectly healthy machine. It is scored as a rate, and only when
  the driver reports a reason right now. This is the same trap the CPU domain
   hit in 1.1.0 and the same corroboration rule the disk domain needed for #1.

## 1.3.1 - 2026-09-19

### Added
- **The bar shows every checked module, side by side.** Auto (still the
  default) renders one chip per checked domain — CPU, RAM, Disk, Network and
  GPU —
  instead of a single icon following the worst constraint. The worst domain
  keeps its ▸ marker in the tooltip and the verdict pill, so the constraint is
  still named without opening anything.
- **Checkboxes in both places, one saved config.** The right-click chooser and
  the Settings page edit the same `bar.showCpu` / `bar.showRam` /
  `bar.showDisk` / `bar.showNet` / `bar.showGpu` flags, persisted in the
  widget's own
  `shell.json` entry. Hiding the last module is refused, and touching a
  checkbox leaves a legacy single-pin for the checked set.
- **IPC for the checked set.** `omarchy-shell nixfred.pulse barShow <domain>
  <true|false>` checks or unchecks one module, `showAllBars` checks all,
  and `status` reports `barKeys` plus the `barVisible` map. `pin` keeps its
  single-chip behaviour for existing scripts and entries.

### Hardened
- **The collectors share one safety standard.** CPU, Net and Disk now write
  snapshots the hardened way (fresh owner-only temp file, no `NaN`, fsync),
  refuse an unsafe `collector.lock` instead of truncating through it, ignore a
  relative `XDG_STATE_HOME`, open the history database lazily so a corrupt DB
  costs history rather than the recorder, and validate Herdr/TMUX sockets plus
  process ancestry before focusing a window. RAM gains a `MemAvailable`
  estimate fallback instead of reporting offline.
- **Smaller robustness fixes.** C-locale subprocess parsing, per-line `/proc`
  guards, Net ping child reaping with `tcp_stats` guards, Disk exact-class
  device skipping with local-FUSE treatment and a SMART time budget, installer
  `umask` with a safe rollback and `python3`-on-PATH units, atomic merge-tool
  writes, and IPC input validation (`show`, `showTab`, `barShow`, `panelWidth`)
  with `safeParse` status reporting on the panel side.

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
