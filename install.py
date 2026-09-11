#!/usr/bin/env python3
"""Install Pulse: the merged CPU, RAM, Disk and Network widget.

Adapted from Disk Pulse's installer, which this plugin absorbed. The shape is
the same — validate first, keep a rollback copy, publish atomically, place the
widget through the running shell rather than by editing its config underneath
it — with two differences the merge forces:

  * the payload is a directory tree (Panel.qml plus sections/ and collectors/),
    not a flat list of files, so it is staged and swapped rather than copied
    file by file;
  * there are four user services, not one, because the four collectors were
    deliberately left alone. Nothing about the merge touched how they record,
    so seven days of history survives it.
"""
from pathlib import Path
import datetime
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time

PLUGIN_ID = 'nixfred.pulse'
UNITS = ('cpu-pulse.service', 'ram-pulse.service', 'disk-pulse.service', 'net-pulse.service')
# Files and directories that make up a release. Anything else in the source
# tree (docs, .git, the generator) is not published.
PAYLOAD = ('manifest.json', 'Panel.qml', 'Model.js', 'README.md', 'sections', 'collectors')
# How long to give the shell's plugin scan before falling back to editing the
# layout file directly. The scan is a subprocess and IPC answers before it
# returns, so the first put after a rescan can honestly say "not ready".
PLACEMENT_TRIES = 6
# The four widgets this replaces. Leaving them enabled would put five bar
# entries up showing the same four readings.
SUPERSEDED = ('nixfred.cpu-pulse', 'nixfred.ram-pulse', 'nixfred.disk-pulse', 'nixfred.net-pulse')


def atomic_write(path, payload, mode):
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def update_layout(raw):
    data = json.loads(raw)
    bar = data.get('bar') if isinstance(data, dict) else None
    layout = bar.get('layout') if isinstance(bar, dict) else None
    if not isinstance(layout, dict):
        raise ValueError('shell.json must contain an object at bar.layout.')
    for section in ('left', 'center', 'right'):
        entries = layout.get(section)
        if not isinstance(entries, list) or any(not isinstance(entry, dict) for entry in entries):
            raise ValueError('bar.layout.' + section + ' must be an array of entry objects.')
    found = False
    for section in ('left', 'center', 'right'):
        entries = []
        for entry in layout[section]:
            if entry.get('id') == PLUGIN_ID:
                if found:
                    continue
                found = True
            entries.append(entry)
        layout[section] = entries
    if not found:
        layout['right'].append({'id': PLUGIN_ID})
    return (json.dumps(data, indent=2) + '\n').encode('utf-8')


def symlinked_ancestors(*paths):
    """Symlinks at or above each path, stopping below $HOME.

    Path.is_symlink() tests only the final component, so checking the files
    alone catches a symlinked shell.json while missing the far more common
    dotfiles layout where ~/.config or ~/.config/omarchy is itself the link
    into a tracked repo. $HOME itself is not checked: a symlinked home
    directory is a system choice, not an install destination the user picked.
    """
    home = Path.home()
    found = set()
    for path in paths:
        for candidate in (path, *path.parents):
            if candidate == home:
                break
            if candidate.is_symlink():
                found.add(str(candidate))
    return sorted(found)


def place_through_shell():
    """Ask the running shell to put the widget on the bar, in its own writer.

    The shell serialises every edit to shell.json through one mutator, so a
    placement made this way cannot race a setting another widget saves in the
    same second. put is the unattended verb: a widget already on the bar stays
    where its owner put it.
    """
    for _ in range(PLACEMENT_TRIES):
        try:
            result = subprocess.run(['omarchy-shell', 'shell', 'putBarWidget', PLUGIN_ID, '{"section": "right"}'],
                                    capture_output=True, text=True, timeout=10, check=False)
        except (OSError, subprocess.SubprocessError):
            return False
        answer = (getattr(result, 'stdout', '') or '').strip()
        if result.returncode == 0 and answer == 'ok':
            return True
        if answer != 'not ready':
            return False
        time.sleep(0.5)
    return False


def retire_superseded():
    """Turn off the four plugins this one replaces, without deleting them.

    Disabled rather than removed: their directories, their history and their
    own installers stay where they are, so going back is one enable away.
    """
    for plugin in SUPERSEDED:
        subprocess.run(['omarchy-shell', '-q', 'shell', 'setPluginEnabled', plugin, 'false'],
                       capture_output=True, timeout=10, check=False)


def stage(source, staging):
    for name in PAYLOAD:
        path = source / name
        if not path.exists():
            raise RuntimeError('Missing install payload: ' + name)
        if path.is_dir():
            shutil.copytree(path, staging / name,
                            ignore=shutil.ignore_patterns('.*', '__pycache__', '*.part'))
        else:
            shutil.copy2(path, staging / name)


def main():
    source = Path(__file__).resolve().parent
    home = Path.home()
    config = home / '.config/omarchy/shell.json'
    dest = config.parent / 'plugins' / PLUGIN_ID
    units = home / '.config/systemd/user'
    linked = symlinked_ancestors(config, dest, units)
    if linked:
        raise RuntimeError('Resolve symlinked install destinations explicitly '
                           'before installing: ' + ', '.join(linked))
    # Validate the layout before anything is published, so a broken file stops
    # the install rather than being discovered after the copy.
    update_layout(config.read_bytes())
    config_mode = stat.S_IMODE(config.stat().st_mode) & 0o777

    backups = home / '.local/state/omarchy/backups'
    backups.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = Path(tempfile.mkdtemp(prefix='pulse-' + stamp + '-', dir=backups))
    shutil.copy2(config, backup / 'shell.json')
    if dest.exists():
        shutil.copytree(dest, backup / 'plugin', symlinks=True)
    for unit in UNITS:
        if (units / unit).exists():
            shutil.copy2(units / unit, backup / unit)

    # Stage the whole tree beside the destination and swap it in, so a failure
    # half way through leaves the running release untouched rather than a new
    # Panel.qml beside old sections.
    staging = dest.parent / ('.' + PLUGIN_ID + '.incoming')
    shutil.rmtree(staging, ignore_errors=True)
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        staging.mkdir()
        stage(source, staging)
        retired = dest.parent / ('.' + PLUGIN_ID + '.previous')
        shutil.rmtree(retired, ignore_errors=True)
        if dest.exists():
            dest.rename(retired)
        staging.rename(dest)
        shutil.rmtree(retired, ignore_errors=True)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        print('Publication failed; the previous release is still in place. '
              'Rollback copies: ' + str(backup))
        raise

    try:
        units.mkdir(parents=True, exist_ok=True)
        for unit in UNITS:
            payload = dest / 'collectors' / unit
            atomic_write(units / unit, payload.read_bytes(),
                         stat.S_IMODE(payload.stat().st_mode) & 0o777)
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=30)
        for unit in UNITS:
            subprocess.run(['systemctl', '--user', 'enable', unit], check=True, timeout=30)
            subprocess.run(['systemctl', '--user', 'restart', unit], check=True, timeout=30)
        subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins'], check=True, timeout=30)
        retire_superseded()
        # The bar layout goes through the shell whenever the shell is there to
        # take it. Without a shell (a headless install, a first boot) the file
        # is edited directly, re-read at the moment of writing so a setting
        # saved while the files were being copied is kept.
        if not place_through_shell():
            atomic_write(config, update_layout(config.read_bytes()), config_mode)
    except Exception:
        print('Install did not complete. Rollback copies: ' + str(backup))
        raise
    print('Installed Pulse. Backup: ' + str(backup))


if __name__ == '__main__':
    main()
