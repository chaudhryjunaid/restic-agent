# resticagent

One command to configure, schedule and monitor [restic](https://restic.net) backups with systemd timers on any Linux machine.

Settings are collected through interactive prompts and stored on the host, not in this repository. Every backup job gets its own systemd timer, and every command is safe to run again.

```sh
sudo ./bin/resticagent add home     # answer a few questions about the job
sudo ./bin/resticagent install      # install the units and enable the timer
resticagent status                  # what ran, how it went, what runs next
```

## Features

- **Interactive setup.** Prompts check each answer as soon as you enter it. Schedules are checked by systemd itself, and the next run time is shown.
- **Or import a file.** `import` sets up a job, and on a new host the global settings too, from one env file, so a machine can be configured without any prompts.
- **Idempotent.** Re-running a command pre-fills the current values, rewrites only files whose content changed, and reloads systemd only when a unit changed.
- **One timer per job.** A single systemd template unit serves every job, and each job's schedule lives in its own small drop-in file.
- **Retention that stays in its lane.** Every snapshot is tagged `job:<name>`, so old snapshots are forgotten per job, even when several jobs share a repository.
- **Monitoring built in.** `status` shows the last result and next run of every job and exits non-zero after a failure. `logs` opens the journal of a job or of its latest run.
- **Run on demand.** `start` runs a job through systemd right now and streams its log, without ever overlapping a scheduled run.
- **Clean removal.** `remove` deactivates and deletes jobs. It never touches the snapshots in a repository.
- **No extra dependencies.** It needs bash, systemd and restic, nothing else.

## Requirements

- Linux with systemd, including `systemctl`, `journalctl` and `systemd-analyze`
- Bash 4.4 or newer
- restic 0.17 or newer
- Standard coreutils, diffutils and sed, which every mainstream distribution ships
- Root access, through sudo or a root shell

It was developed on Ubuntu 26.04 with systemd 259 and restic 0.18.1. Older systemd versions are supported, with small fallbacks for features added in systemd 247 and 257.

## Quick start

1. Install restic from your distribution, for example `sudo apt install restic`, `sudo dnf install restic` or `sudo pacman -S restic`. If that version is older than 0.17, download a current release from [GitHub](https://github.com/restic/restic/releases).

2. Get resticagent:

   ```sh
   git clone https://github.com/chaudhryjunaid/restic-agent.git
   cd restic-agent
   ```

3. Create a backup job. The first time, this also asks for the global settings, such as the repository and its password:

   ```sh
   sudo ./bin/resticagent add home
   ```

   If you keep the settings in a file, import it instead. See [USAGE.md](USAGE.md#resticagent-import-file-job---global--y) for the format.

   ```sh
   sudo ./bin/resticagent import home.env
   ```

4. Install and activate it. This copies `resticagent` to `/usr/local/bin`, checks the repository, offers to initialize it if it doesn't exist yet, and enables the job's timer:

   ```sh
   sudo ./bin/resticagent install
   ```

5. Run the first backup now and check on it:

   ```sh
   sudo resticagent start home
   resticagent status
   ```

## Commands

| Command | What it does | Root |
| --- | --- | --- |
| `init` | Create or update the global settings | yes |
| `add [JOB]` | Create or update a backup job | yes |
| `import FILE [JOB]` | Create or replace a job from an env file, without prompts | yes |
| `list [JOB]` | Show every job's settings and install state, or one job in full | yes |
| `install [JOB...]` | Install the program and units, check repositories, enable timers | yes |
| `start JOB` | Run a job now through systemd and follow its log | yes |
| `run JOB` | Run a job directly in the terminal, outside systemd | yes |
| `status [JOB]` | Show timer state, last run, result and next run | no |
| `logs [JOB]` | Show the journal of all jobs or one job | no |
| `remove JOB...` | Deactivate and delete jobs, or everything with `--all` | yes |

`ls`, `rm` and `log` work as short forms of `list`, `remove` and `logs`. See [USAGE.md](USAGE.md) for every option, the configuration file format, restoring files and troubleshooting.

## How it works

Configuration lives on each host:

```text
/etc/resticagent/
├── config                       global settings: repository, password file, credentials
├── password                     the repository password, by default (mode 0600)
└── config.d/
    └── home/
        ├── env                  schedule, retention and options of job "home"
        ├── src                  paths to back up, one per line
        └── exclude              restic exclude patterns, one per line
```

`install` adds the program and the systemd units:

```text
/usr/local/bin/resticagent
/etc/systemd/system/
├── restic-backup@.service                  template service, runs "resticagent run <job>"
├── restic-backup@.timer                    template timer
└── restic-backup@home.timer.d/
    └── schedule.conf                       the schedule of job "home"
```

When a job's timer fires, systemd starts `restic-backup@home.service`. That runs `resticagent run home`, which reads the global settings and then the job's own settings, runs `restic backup` on the job's paths, and applies its retention rules with `restic forget`.

## Safety notes

- **Keep a copy of the repository password somewhere else.** Without it, the backups cannot be restored.
- **`remove` never deletes snapshots,** even with `--purge`. Retention only forgets snapshots tagged with the job's own `job:<name>` tag.
- **The global settings and each job's `env` file are readable by root only,** because they can hold backend credentials.
- **Values cannot contain single quotes or backslashes.** This keeps the files valid for both Bash and systemd, and the prompts refuse those characters.

## Updating

```sh
cd restic-agent
git pull
sudo ./bin/resticagent install
```

`install` replaces the program and the unit templates only if they changed, and leaves your configuration alone.

## Development

- Lint with [shellcheck](https://www.shellcheck.net): `shellcheck bin/resticagent`.
- Set `RESTICAGENT_ROOT` to a scratch directory to try commands without root. Every path is placed below that directory, `enable` and `disable` act on the files there, other systemctl calls that change state are only printed, and read-only queries still go to the host.
- The script only runs its `main` function when executed, so a test can `source` it to call individual functions.

## License

[MIT](LICENSE)
