# resticagent

One command to configure, schedule and monitor [restic](https://restic.net) backups with systemd timers on any Linux machine.

Settings are collected through interactive prompts and stored on the host, not in this repository. Every backup job gets its own systemd timer, and every command is safe to run again. No root is needed. Run as yourself, it backs up your files with your own systemd user units. Run with sudo, it manages system-wide backups instead.

```sh
./bin/resticagent add home     # answer a few questions about the job
./bin/resticagent install      # install the units and enable the timer
resticagent status             # what ran, how it went, what runs next
```

## Features

- **No root required.** Your own backups run as systemd user units under your account. Root is only needed for system-wide backups, of files such as `/etc`.
- **Interactive setup.** Prompts check each answer as soon as you enter it. Schedules are checked by systemd itself, and the next run time is shown.
- **Or import a file.** `import` sets up a job, and on a new host the global settings too, from one env file, so a machine can be configured without any prompts.
- **Idempotent.** Re-running a command pre-fills the current values, rewrites only files whose content changed, and reloads systemd only when a unit changed.
- **One timer per job.** A single systemd template unit serves every job, and each job's schedule lives in its own small drop-in file.
- **Retention that stays in its lane.** Every snapshot is tagged `job:<name>`, so old snapshots are forgotten per job, even when several jobs share a repository.
- **Monitoring built in.** `status` shows the last result and next run of every job and exits non-zero after a failure. `logs` opens the journal of a job or of its latest run.
- **Notifications.** Desktop notifications say when a scheduled backup starts (🔄), succeeds (✅) or fails (❌). A failure also mails the local account the job belongs to: yours, or root's for system-wide jobs.
- **Run on demand.** `start` runs a job through systemd right now and streams its log, without ever overlapping a scheduled run.
- **Snapshots per job.** `snapshots` lists a job's snapshots, and `show` shows what is in one with `ls -alh` or `tree`. `forget` deletes its oldest ones, or all but its newest, and lists exactly which ones go before asking.
- **Restore with a preview.** `restore` puts files back in place or into another folder. It shows first what it would overwrite or delete, and asks.
- **Clean removal.** `remove` deactivates and deletes jobs. It never touches the snapshots in a repository.
- **One-step install, no root.** `setup.sh` installs it into `~/.local`, together with restic and tree if this machine lacks them, and removes it all again with `--uninstall`.
- **No extra dependencies.** It needs bash, systemd and restic. Only `show` needs more: FUSE for its `ls` listing, and `tree` for `--tree`.

## Requirements

- Linux with systemd, including `systemctl`, `journalctl` and `systemd-analyze`
- Bash 4.4 or newer
- restic 0.17 or newer. `setup.sh` installs the latest release into `~/.local/bin` if needed.
- For `show` only: FUSE (the `fuse3` package) to list a snapshot with `ls`, and the `tree` command for `show --tree`. `setup.sh` builds tree if it is missing and a C compiler is available. FUSE needs root to install.
- Standard coreutils, diffutils and sed, which every mainstream distribution ships
- Root access only for system-wide backups, see [Your backups or the system's](#your-backups-or-the-systems)

It was developed on Ubuntu 26.04 with systemd 259 and restic 0.18.1. Older systemd versions are supported, with small fallbacks for features added in systemd 247 and 257.

## Quick start

1. Get resticagent and install it into `~/.local`. This needs no root. It also installs restic if this machine lacks it or has a version older than 0.17. See [Installing with setup.sh](#installing-with-setupsh).

   ```sh
   git clone https://github.com/chaudhryjunaid/restic-agent.git
   cd restic-agent
   ./setup.sh
   ```

2. Create a backup job. The first time, this also asks for the global settings, such as the repository and its password:

   ```sh
   resticagent add home
   ```

   If you keep the settings in a file, import it instead. See [USAGE.md](USAGE.md#resticagent-import-file-job---global--y) for the format.

   ```sh
   resticagent import home.env
   ```

3. Activate it. This checks the repository, offers to initialize it if it doesn't exist yet, and enables the job's timer:

   ```sh
   resticagent install
   ```

4. Run the first backup now and check on it:

   ```sh
   resticagent start home
   resticagent status
   ```

## Installing with setup.sh

`./setup.sh` installs resticagent for your own user, the way `make install PREFIX=~/.local` would:

```text
~/.local/bin/resticagent                  the program
~/.local/share/resticagent/systemd/       its systemd unit templates
~/.local/share/resticagent/manifest       every file setup.sh installed
~/.local/share/doc/resticagent/           README.md, USAGE.md, LICENSE
~/.local/bin/restic                       only if restic is missing or older than 0.17
~/.local/bin/tree                         only if tree is missing, with its man page
```

- **restic** comes from its official GitHub release. setup.sh checks the release's SHA-256 sums, and their GPG signature against the key restic publishes (fingerprint `CF8F 18F2 8445 7597 3F79 D4E1 91A6 868B D3F7 A907`). Without `gpg` on the machine, only the sums are checked. It installs the latest release, or the one in `RESTIC_VERSION`, as in `RESTIC_VERSION=0.18.1 ./setup.sh`.
- **tree** is built from source, so that needs a C compiler and `make`. Without them, setup.sh prints the command that installs tree from your distribution. Only `show --tree` needs it.
- **FUSE** is only checked. `fusermount3` must be owned by root, so it cannot go into `~/.local`. setup.sh prints the command that installs it, such as `sudo apt install fuse3`. Only `show` needs it, to list snapshots with `ls`.
- **The restic next to resticagent comes first.** resticagent runs a restic in its own directory before any on your PATH, so scheduled runs find it too. systemd's PATH does not include `~/.local/bin`.
- **Running it again updates everything,** including the restic that setup.sh installed, to the latest release. A restic or tree that came from elsewhere is never touched.
- **`./setup.sh --uninstall`** deletes the files in the manifest. Run `resticagent remove --all` first, which stops and removes your jobs. Your settings and snapshots stay.

setup.sh installs for your own user only. For system-wide jobs, install the program with `sudo ./bin/resticagent install`.

## Your backups or the system's

resticagent decides where everything goes from who runs it:

| | Run as yourself | Run as root, with `sudo` |
| --- | --- | --- |
| Can back up | files you can read | any file on the machine |
| Settings | `~/.config/resticagent/` | `/etc/resticagent/` |
| Units | `~/.config/systemd/user/`, run by your systemd user manager | `/etc/systemd/system/`, run by the system manager |
| Program | `~/.local/bin/resticagent` | `/usr/local/bin/resticagent` |
| Timers fire | while you are logged in, or always with lingering | whenever the machine is on |

`~/.config` stands for `$XDG_CONFIG_HOME` if you set it. The two sets of jobs are separate, and each command only sees one of them. A regular user sees their own jobs. Add `--system` to see the system-wide jobs without root, as in `resticagent --system status`.

Use your own jobs for your home directory and other files you own. Use `sudo` for files you can't read, such as `/etc` or other users' homes, and for repositories that only root can write to.

Things to know about your own jobs:

- **Timers fire only while you are logged in.** Timers are persistent, so a run that was missed while you were away starts at your next login. To let them fire whenever the machine is on, enable lingering once with `loginctl enable-linger`.
- **They don't wait for the network.** User units can't depend on the system's `network-online.target`. With a remote repository, a run started right at login may fail before the network is up. The next run then catches up.

## Commands

| Command | What it does |
| --- | --- |
| `init` | Create or update the global settings |
| `add [JOB]` | Create or update a backup job |
| `import FILE [JOB]` | Create or replace a job from an env file, without prompts |
| `list [JOB]` | Show every job's settings and install state, or one job in full |
| `install [JOB...]` | Install the program and units, check repositories, enable timers |
| `start JOB` | Run a job now through systemd and follow its log |
| `run JOB` | Run a job directly in the terminal, outside systemd |
| `status [JOB]` | Show timer state, last run, result and next run |
| `logs [JOB]` | Show the journal of all jobs or one job |
| `stats [JOB...]` | Show each job's snapshots and the space they take |
| `notify [JOB] --test` | Send a test failure alert. A failed run sends a real one through systemd. |
| `snapshots JOB` | List a job's snapshots |
| `show JOB [SNAPSHOT] [PATH]` | Show the files in a snapshot with `ls -alh`, or with `tree` given `--tree` |
| `diff JOB [SNAPSHOT [SNAPSHOT]]` | Show what changed between two snapshots, by default the last two |
| `mount JOB [DIR]` | Browse a job's snapshots as folders, until Ctrl-C |
| `restore JOB [SNAPSHOT] [PATH]` | Restore files in place, or below `--target DIR`, after previewing the changes |
| `forget JOB` | Forget a job's snapshots by count or age, after listing them |
| `pause JOB...`, `resume JOB...` | Stop jobs' timers for a while, and start them again |
| `remove JOB...` | Deactivate and delete jobs, or everything with `--all` |
| `unlock JOB` | Remove stale locks from a job's repository |
| `key [JOB]` | Change the repository password, and the password file with it |

None of them need root for your own jobs. For system-wide jobs, every command needs `sudo` except `status` and `logs`, which also work with `--system`. `ls`, `rm` and `log` work as short forms of `list`, `remove` and `logs`. See [USAGE.md](USAGE.md) for every option, the configuration file format, restoring files and troubleshooting.

## How it works

Configuration lives on each host, here for your own jobs. System-wide jobs use the same layout in `/etc/resticagent/`.

```text
~/.config/resticagent/
├── config                       global settings: repository, password file, credentials
├── password                     the repository password, by default (mode 0600)
└── config.d/
    └── home/
        ├── env                  schedule, retention and options of job "home"
        ├── src                  paths to back up, one per line
        └── exclude              restic exclude patterns, one per line
```

`install` adds the program and the systemd units. For system-wide jobs, these go to `/usr/local/bin` and `/etc/systemd/system/`.

```text
~/.local/bin/resticagent
~/.local/share/resticagent/systemd/         the unit templates, for the installed program
~/.config/systemd/user/
├── restic-backup@.service                  template service, runs "resticagent run <job>"
├── restic-backup@.timer                    template timer
├── restic-backup-notify@.service           template failure alert, runs "resticagent notify <job>"
└── restic-backup@home.timer.d/
    └── schedule.conf                       the schedule of job "home"
```

When a job's timer fires, systemd starts `restic-backup@home.service`. That runs `resticagent run home`, which reads the global settings and then the job's own settings, runs `restic backup` on the job's paths, and applies its retention rules with `restic forget`. If the run fails, systemd starts `restic-backup-notify@home.service`, which sends the alerts.

## Safety notes

- **Keep a copy of the repository password somewhere else.** Without it, the backups cannot be restored.
- **`remove` never deletes snapshots,** even with `--purge`. Retention and `forget` only forget snapshots tagged with the job's own `job:<name>` tag.
- **The global settings and each job's `env` file are readable only by their owner,** you or root, because they can hold backend credentials.
- **Values cannot contain single quotes or backslashes.** This keeps the files valid for both Bash and systemd, and the prompts refuse those characters.

## Updating

```sh
cd restic-agent
git pull
./setup.sh                        # the program, and restic if setup.sh installed it
resticagent install               # your own jobs' units
sudo ./bin/resticagent install    # system-wide jobs, if you have any
```

`setup.sh` and `install` replace files only if they changed, and leave your configuration alone.

## Development

- Lint with [shellcheck](https://www.shellcheck.net): `shellcheck -x setup.sh bin/resticagent`.
- `setup.sh` sources `bin/resticagent` for its paths and helpers. With `RESTICAGENT_ROOT` set, it installs below that directory too.
- Set `RESTICAGENT_ROOT` to a scratch directory to try commands without changing the host. Every path is placed below that directory, and `--system` then works without root too. For system units, `enable` and `disable` act on the files there; `systemctl` can't do this for user units. Other systemctl calls that change state are only printed, and read-only queries still go to the host.
- The script only runs its `main` function when executed, so a test can `source` it to call individual functions.

## License

[MIT](LICENSE)
