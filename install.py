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
import re
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


def entry_id(entry):
    """The id of a layout entry, which the shell lets you write either way.

    A bare string is legal in bar.layout — the shell's own BarModel accepts it —
    so rejecting the file over one would refuse to install on a perfectly valid
    config.
    """
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        return entry.get('id')
    return None


def update_layout(raw):
    data = json.loads(raw) if raw.strip() else {}
    if not isinstance(data, dict):
        raise ValueError('shell.json must contain an object at the top level.')
    bar = data.setdefault('bar', {})
    if not isinstance(bar, dict):
        raise ValueError('shell.json must contain an object at bar.')
    layout = bar.setdefault('layout', {})
    if not isinstance(layout, dict):
        raise ValueError('shell.json must contain an object at bar.layout.')
    for section in ('left', 'center', 'right'):
        entries = layout.setdefault(section, [])
        if not isinstance(entries, list):
            raise ValueError('bar.layout.' + section + ' must be an array.')
    found = False
    for section in ('left', 'center', 'right'):
        entries = []
        for entry in layout[section]:
            if entry_id(entry) == PLUGIN_ID:
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


def adopt_working_tree(retired, dest):
    """Move the entries a release does not own from the old tree into the new one.

    `omarchy plugin add` clones the plugin into the directory this installer
    publishes to, and the README's own `git clone` invites the same when it is
    run in place. Renaming the old tree aside and publishing a payload-only
    release over it deleted everything outside PAYLOAD: `.git` first, so the
    checkout had no history and no way back, then `docs/`, `tools/`,
    `CHANGELOG.md` and the installer itself.

    Entries the payload owns are left alone - those are the release. Anything
    else was the user's before this ran and still is.
    """
    if not retired.is_dir():
        return []
    kept = []
    for entry in sorted(retired.iterdir()):
        if entry.name in PAYLOAD:
            continue
        target = dest / entry.name
        if target.exists():
            continue
        try:
            entry.rename(target)
        except OSError:
            continue
        kept.append(entry.name)
    return kept


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
    # the install rather than being discovered after the copy. A machine that
    # has never run the shell has no shell.json yet, which is a first install,
    # not an error.
    config.parent.mkdir(parents=True, exist_ok=True)
    raw = config.read_bytes() if config.exists() else b'{}'
    update_layout(raw)
    config_mode = stat.S_IMODE(config.stat().st_mode) & 0o777 if config.exists() else 0o644

    backups = home / '.local/state/omarchy/backups'
    backups.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = Path(tempfile.mkdtemp(prefix='pulse-' + stamp + '-', dir=backups))
    if config.exists():
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
    retired = dest.parent / ('.' + PLUGIN_ID + '.previous')
    # Entries the release does not own, carried over from the tree it replaced.
    # Bound here rather than where it is filled in, so the name unpublish()
    # reads is never the one that is missing.
    adopted = []
    shutil.rmtree(staging, ignore_errors=True)
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        staging.mkdir()
        stage(source, staging)
        shutil.rmtree(retired, ignore_errors=True)
        if dest.exists():
            dest.rename(retired)
        staging.rename(dest)
        # The release does not own `.git`, `docs/`, `tools/` or the installer
        # itself, and on a directory `omarchy plugin add` created they are the
        # user's checkout rather than ours to delete.
        adopted = adopt_working_tree(retired, dest)
        # `retired` is NOT deleted here. It is the only copy of the release
        # that was working a second ago, and phase two can still fail.
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        # A failure after the old tree was renamed aside leaves no plugin
        # directory at all, and the line printed below would be false: the
        # release that was working a second ago is sitting in `.previous` under
        # a hidden name the shell never looks at. Put it back before saying
        # anything, so the message is true and the bar keeps its plugin.
        if retired.is_dir() and not dest.exists():
            try:
                retired.rename(dest)
            except OSError:
                pass
        print('Publication failed; the previous release is still in place. '
              'Rollback copies: ' + str(backup))
        raise

    # Everything from here runs with the new tree already live, so a failure
    # must put the previous one back. Without this, a missing user D-Bus
    # session (installing over SSH) left the new Panel.qml running with no
    # collectors and no bar entry, and the installer only printed a path.
    def unpublish():
        if not retired.exists():
            return
        # Anything the release adopted came from the tree being restored, so it
        # goes back before that tree is renamed over this one. A rollback that
        # ate `.git` would be worse than the failure it is undoing.
        for name in adopted:
            entry = dest / name
            if not entry.exists():
                continue
            try:
                entry.rename(retired / name)
            except OSError:
                pass
        shutil.rmtree(dest, ignore_errors=True)
        retired.rename(dest)
        for unit in UNITS:
            saved = backup / unit
            if saved.is_file():
                shutil.copy2(saved, units / unit)
        subprocess.run(['systemctl', '--user', 'daemon-reload'],
                       capture_output=True, timeout=30, check=False)
        for unit in UNITS:
            subprocess.run(['systemctl', '--user', 'restart', unit],
                           capture_output=True, timeout=30, check=False)

    try:
        units.mkdir(parents=True, exist_ok=True)
        for unit in UNITS:
            payload = dest / 'collectors' / unit
            text = payload.read_text()
            # These units began life in the four plugins Pulse replaces, and
            # their ExecStart still named those directories. On a machine that
            # never had them — every new install — all four collectors would
            # fail to start and every domain would read "recorder offline".
            # The path is rewritten here as well as in the file, so an edited
            # or stale unit cannot reintroduce it.
            domain = unit.split('-')[0]
            text = re.sub(r'ExecStart=\S+ \S*%h/\.config/omarchy/plugins/\S+?/' + domain + r'_pulse\.py',
                          'ExecStart=/usr/bin/python3 %h/.config/omarchy/plugins/' + PLUGIN_ID
                          + '/collectors/' + domain + '_pulse.py', text)
            if (PLUGIN_ID + '/collectors/' + domain + '_pulse.py') not in text:
                raise RuntimeError('Could not point ' + unit + ' at this plugin\'s collector.')
            atomic_write(units / unit, text.encode('utf-8'),
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
        unpublish()
        print('Install did not complete; the previous release was put back. '
              'Rollback copies: ' + str(backup))
        raise
    shutil.rmtree(retired, ignore_errors=True)
    if adopted:
        print('Kept, not published over: ' + ', '.join(adopted))
    print('Installed Pulse. Backup: ' + str(backup))


if __name__ == '__main__':
    main()
