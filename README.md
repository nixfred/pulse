# Pulse

One Omarchy bar widget for the four readings that say what a machine is doing:
how hard it is thinking, how much it can still remember, how much room it has
left, and whether it can reach anything.

This is the merge of four plugins that each did one of those:

| Was | Now | Recorder |
|---|---|---|
| [CPU Pulse](https://github.com/nixfred/omacpu) | the **CPU** page | `cpu-pulse.service` |
| [RAM Pulse](https://github.com/nixfred/ram.plugin.omarchy) | the **RAM** page | `ram-pulse.service` |
| [Disk Pulse](https://github.com/nixfred/disk.pulse) | the **Disk** page | `disk-pulse.service` |
| [Net Pulse](https://github.com/nixfred/omanet.plugin.omarchy) | the **Network** page | `net-pulse.service` |

**Nothing was summarised away.** Each domain page is the original plugin's
dashboard in full: the same sub-tabs, the same tables, the same controls, the
same seven days of history, reading the same recorder and the same state
directory. The merge added exactly two pages that could not exist before —
Overview and Settings — and took away four bar entries.

## The panel

**Overview** — one card per domain: that domain's own chip, its own readout in
its own grammar, its verdict, and its history line. The card with the least
headroom takes a coloured border, so the reading you came for stands out before
you read a number. Clicking a card opens that domain.

**CPU** · Overview, CPU hogs, Processor lab, About
**RAM** · Overview, RAM hoarders, Memory lab, About
**Disk** · Overview, Disk hogs, Storage lab, About
**Network** · Overview, Wi-Fi, Interfaces, Talkers, Data, Network lab, About

**Settings** — every setting the four had, grouped by domain, plus the two
decisions that only exist once they share a bar entry: which chips appear in
the bar, and which of them carry a readout. Each plugin used to hide its
readout chooser behind a right-click on its own chip; with one bar entry, all
four choosers live here.

**About** — what this is, what it replaced, and where each part came from.

## The bar

Four chips in one entry. Each is the original plugin's own bar chip, so it keeps
its own animation and tint. Click a chip to open that domain directly, click the
gap for the Overview, right-click for Settings.

## Install

```bash
python3 install.py
```

Publishes the plugin, installs and starts the four user services, places the
widget on the right of the bar, and disables the four plugins it replaces
without deleting them — going back is one `omarchy plugin enable` away.

## IPC

```bash
omarchy-shell nixfred.pulse open
omarchy-shell nixfred.pulse show net              # jump to a domain
omarchy-shell nixfred.pulse showTab net 1         # domain, then sub-tab
omarchy-shell nixfred.pulse display cpu 2         # that domain's bar readout
omarchy-shell nixfred.pulse historyRange ram 86400
omarchy-shell nixfred.pulse modes                 # settings
omarchy-shell nixfred.pulse status                # all four, as JSON
```

`status` nests each domain's original status object under its key, so anything
that scraped one of the four plugins needs only to reach one level deeper.

## Why the collectors were left alone

Four Python collectors, four user units, four state directories — unchanged.
They are the part that had been running for weeks and the part that holds the
history, so the merge deliberately stopped at the UI. It cost no recorded data,
and any one of them can still be debugged on its own.

Settings are stored in the widget's `shell.json` entry, namespaced per domain
(`cpu.displayMode`, `ram.groupByApp`, `disk.mountpoint`, `net.inBar`), so the
four no longer compete for the same keys.

MIT.
