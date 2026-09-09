# PBS Backup

Scheduled Proxmox Backup Server (PBS) snapshots, with a snapshot browser in
the Omarchy bar. Click the icon to see when each group last ran, kick off an
ad-hoc backup, or browse the file tree of any snapshot to restore individual
files.

## Install

```bash
# 1. Install the PBS client (Arch / Omarchy):
yay -S proxmox-backup-client-bin

# 2. Add the plugin:
omarchy plugin add https://github.com/teohz/omarchy-pbs-backup --enable

# 3. Click the bar icon → "Create Configuration". The starter file opens in
#    your editor. Replace the CHANGEME- placeholders with your PBS server,
#    datastore, namespace, and group(s). Save and close.

# 4. Set the PBS password (or API token secret):
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup key set

# 5. Install the systemd units and timers:
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup install
```

After step 5 the bar icon turns green and the per-group timers run on the
schedule you set in `config.json`.

## How it talks to PBS

The plugin shells out to `proxmox-backup-client` for every action that
touches the server, and reads `status.json` (a local file) on every idle tick.
That means the bar tooltip — "Last backup: 3 hours ago" — never makes a
network call.

The full invocation the plugin uses for a backup:

```
proxmox-backup-client backup \
  --change-detection-mode metadata \
  --backup-id external-drive \
  --exclude "*/.cache/" \
  --exclude "*/.local/share/Trash/" \
  external-drive.pxar:/mnt/external-drive
```

`--backup-id` defaults to `sanitize_for_pbs_id "$(basename source)"` (matching
the existing `pbs-adhoc-backup.sh` convention), so a backup triggered from the
plugin and a backup triggered from the manual script land on the same PBS
group and share chunks.

## Restore

Click **Restore Files…** in the panel. The plugin mounts the chosen
archive via PBS's FUSE backend at
`~/.local/state/omarchy-pbs-backup/mounts/<group>/<snapshot-id>/`. Each
folder click is a single `readdir` on that mount; restoring a file or
folder calls `proxmox-backup-client restore <snap> <archive> ~/Restored/`
(without `--overwrite`, so it fails loudly if anything already exists).

Two affordances are exposed at the bottom of the restore panel:

- The mount path itself, so you can open a terminal and use `cp`, `find`,
  `grep`, `tar` against the snapshot directly while the panel is open.
- "Restore this folder" and "Restore <filename>" menu rows, which extract
  to `~/Restored/<timestamp>/<basename>/`.

Restores never overwrite files. The panel closes automatically on unmount.

### Future: `proxmox-backup-client catalog shell` (interactive TUI)

PBS ships an interactive restore shell that walks the snapshot the way
`mc` or a TUI FTP client does:

```
$ proxmox-backup-client catalog shell \
    host/external-drive/2026-09-08T03:00:00Z external-drive.pxar
Starting interactive shell
pxar:/ > ls
bin        boot       dev        etc        home       lib        lib32
pxar:/ > cd home/teohz
pxar:/home/teohz > find *.conf --select
pxar:/home/teohz > restore-selected ~/Restored/
```

The plugin doesn't drive this TUI in v1 — it relies on the FUSE mount
instead, which is faster (a single `readdir` per click) and scriptable from
a terminal directly. A future release could add a "Browse in terminal TUI"
menu row that runs the catalog shell in a Hyprland terminal window, for
users who prefer PBS's own interactive UI over the bar widget's.

## Config schema

`~/.config/omarchy-pbs-backup/config.json`:

```json
{
  "pbs": {
    "repository": "backup@pbs!backup@pbs-host.example.com:datastore-name",
    "fingerprint": "aa:bb:cc:dd:...:aa:bb:cc:dd:...:aa:bb:cc:dd:...",
    "change_detection_mode": "metadata"
  },
  "namespace": "your-name/your-group",
  "groups": [
    {
      "name": "external-drive",
      "display_name": "External drive",
      "source": "/mnt/external-drive",
      "schedule": "Sun *-*-* 03:00:00",
      "randomized_delay": "10m",
      "backup_id": null,
      "excludes": [
        "*/.cache/",
        "*/.local/share/Trash/"
      ],
      "retention": { "daily": 7, "weekly": 4, "monthly": 12, "yearly": 3 },
      "prune_after_backup": true
    }
  ]
}
```

| Field | Purpose |
|---|---|
| `pbs.repository` | Full `PBS_REPOSITORY` string. Carries the server, datastore, namespace, and auth identity (`user@realm` for password auth, `user@realm!tokenname` for an API token). Same shape your `pbs-adhoc-backup.sh` uses. |
| `pbs.fingerprint` | TLS cert fingerprint (sha256). Required for self-signed PBS certs. |
| `pbs.change_detection_mode` | `legacy`, `data`, or `metadata`. Default `metadata`. |
| `namespace` | PBS namespace. Top-level for now; per-group override may come later. |
| `groups[].name` | Identifier — names the systemd unit, log dir, and restore browser slot. |
| `groups[].display_name` | Human label shown in the bar panel. |
| `groups[].source` | Absolute path to back up. |
| `groups[].schedule` | systemd `OnCalendar` value. Empty = run on demand only. |
| `groups[].randomized_delay` | systemd `RandomizedDelaySec` for the timer. |
| `groups[].backup_id` | Optional override for the PBS `--backup-id`. Defaults to `sanitize_for_pbs_id "$(basename source)"`. |
| `groups[].excludes` | Array of glob patterns, passed as repeated `--exclude`. |
| `groups[].retention` | `keep-daily` / `keep-weekly` / `keep-monthly` / `keep-yearly` integers. |
| `groups[].prune_after_backup` | `true` (default) runs `prune` after each successful backup; `false` defers retention to PBS admin. |

## State directories

| Path | Purpose |
|---|---|
| `~/.config/omarchy-pbs-backup/config.json` | Plugin config (mode 600). |
| `~/.config/omarchy-pbs-backup/.secret` | PBS password / API token secret (mode 600). |
| `~/.local/state/omarchy-pbs-backup/status.json` | Per-group last-run, snapshot_count, repo_size_bytes. |
| `~/.local/state/omarchy-pbs-backup/progress-<group>.json` | Live progress (10s TTL on the bar widget's "running" detection). |
| `~/.local/state/omarchy-pbs-backup/logs/<group>/<date>.log` | Per-run log files, 30-day retention. |
| `~/.local/state/omarchy-pbs-backup/mounts/<group>/<snapshot-id>/` | FUSE mount points, unmounted on panel close. |
| `~/.config/systemd/user/omarchy-pbs-backup@.service` | Template service, one per group. |
| `~/.config/systemd/user/omarchy-pbs-backup@<group>.timer` | Per-group timer. |
| `~/.config/systemd/user/omarchy-pbs-backup-failed@.service` | `OnFailure=` hook, sends a notification. |

## Manual usage

```bash
# Dry-run a backup (prints the proxmox-backup-client command):
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup \
  backup --dest external-drive --dry-run

# Inspect what the bar would show:
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup status --json

# Inspect every group:
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup groups

# Browse a snapshot (interactive use; the panel does this for you):
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup \
  mount --dest external-drive --snapshot host/external-drive/2026-09-08T03:00:00Z \
       --archive external-drive.pxar
ls ~/.local/state/omarchy-pbs-backup/mounts/external-drive/...
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup \
  unmount --dest external-drive

# Show the most recent log file:
~/.config/omarchy/plugins/teohz.pbs-backup/bin/omarchy-pbs-backup log --dest external-drive
```

## Coexistence with the system timer

The plugin's user-scope timer and the existing system-scope
`pbs-adhoc-backup.timer` can run side-by-side. PBS serialises concurrent
backups to the same group (the second waits for the first's lock), so no
extra coordination is needed. When you're ready to fully drive backups
from the bar, disable and remove the system unit:

```bash
sudo systemctl disable --now pbs-adhoc-backup.timer
sudo rm /etc/systemd/system/pbs-adhoc-backup.{service,timer}
```

The data on PBS is untouched; the plugin and the existing script produce
identical `--backup-id` and archive names and share chunks.

## Compatibility

- **PBS version**: ≥ 2.0 (for `--output-format json` on `snapshot list` and
  `snapshot files`).
- **PBS client**: `proxmox-backup-client-bin` 4.x (Arch / Omarchy). The
  plugin does not bundle or link against the AGPL-3.0-or-later client; it
  shells out to it.
- **Filesystem**: requires `fuse3` for the restore browser (installed as
  a transitive dependency of `proxmox-backup-client-bin`).
- **Plugin id**: `teohz.pbs-backup`. One PBS per install; for multiple PBS
  servers, install the plugin into multiple Omarchy profiles.

## Licence

MIT. The plugin icon embeds the `fa-database` outline from Font Awesome Free
under CC BY 4.0.
