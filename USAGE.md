# Using resticagent

This guide covers every command, the configuration files, restoring data and troubleshooting. For an overview and installation, see the [README](README.md).

- [Concepts](#concepts)
- [Setting up](#setting-up): `init`, `add`, `import`, `install`
- [Running backups](#running-backups): schedules, `start`, `run`
- [Monitoring](#monitoring): `status`, `logs`, `list`
- [Changing a job](#changing-a-job)
- [Forgetting snapshots](#forgetting-snapshots): `forget`
- [Removing jobs](#removing-jobs): `remove`
- [Restoring files](#restoring-files)
- [File reference](#file-reference)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)

## Concepts

- **Your jobs or the system's.** Run as a regular user, resticagent manages your own jobs with your systemd user manager, without root. Run as root, it manages the system-wide jobs. This guide shows the paths and commands for your own jobs. For system-wide jobs, put `sudo` before each command and replace the paths as follows: `/etc/resticagent` for `~/.config/resticagent`, `/etc/systemd/system` for `~/.config/systemd/user`, and `/usr/local/bin` for `~/.local/bin`. See [Your backups or the system's](README.md#your-backups-or-the-systems) for which to choose.
- **Global settings** are shared by every job: the default repository, the password file, the cache directory, compression, and any backend credentials. They live in `~/.config/resticagent/config`.
- **A job** is one set of paths backed up on one schedule with one retention policy. Its name may contain letters, digits, `-` and `_`. Each job has a directory `~/.config/resticagent/config.d/<job>/`.
- **The repository** is where restic stores snapshots. Jobs use the global repository unless they override it, and several jobs can share one repository.
- **The job tag.** Every snapshot a job creates carries the tag `job:<job>`. Retention and `forget` only ever consider snapshots with that tag.
- **The timer** `restic-backup@<job>.timer` starts the service `restic-backup@<job>.service` on the job's schedule.

## Setting up

### `resticagent init`

Creates or updates the global settings. `add` runs it automatically the first time, so you only need it to change these settings later.

| Prompt | Default | Stored as |
| --- | --- | --- |
| Default restic repository | none, required | `RESTIC_REPOSITORY` |
| Default password file | `~/.config/resticagent/password`, or `/etc/resticagent/password` for system-wide jobs | `RESTIC_PASSWORD_FILE` |
| restic cache directory | `~/.cache/restic`, or `/var/cache/restic` for system-wide jobs | `RESTIC_CACHE_DIR` |
| Compression (`auto`, `off`, `max`) | `auto` | `RESTIC_COMPRESSION` |
| Additional environment variables | none | one `KEY=VALUE` per line |

The repository can be any location restic supports, for example `/mnt/backup/restic`, `sftp:backup@nas.local:/srv/restic`, `s3:s3.amazonaws.com/my-bucket/restic` or `rest:https://backup.example.com/`.

Use the additional variables for backend credentials and other restic settings, for example `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` or `RESTIC_PACK_SIZE`. `list` shows only their names, never their values.

If the password file does not exist, `init` offers to create it. It asks for the password twice without echoing it and saves the file with mode 0600.

### `resticagent add [JOB]`

Creates or updates one job. Without a name, it asks for one.

| Section | Prompt | Default | Stored as |
| --- | --- | --- | --- |
| Repository | Repository override | empty, uses the global one | `RESTIC_REPOSITORY` |
| Repository | Password file override | empty, uses the global one | `RESTIC_PASSWORD_FILE` |
| Schedule | When to run | `daily` | `ON_CALENDAR` |
| Schedule | Random delay before each run | `15min` | `RANDOMIZED_DELAY` |
| Retention | Keep the N most recent snapshots | empty | `KEEP_LAST` |
| Retention | Keep N hourly snapshots | empty | `KEEP_HOURLY` |
| Retention | Keep N daily snapshots | `7` | `KEEP_DAILY` |
| Retention | Keep N weekly snapshots | `4` | `KEEP_WEEKLY` |
| Retention | Keep N monthly snapshots | `6` | `KEEP_MONTHLY` |
| Retention | Keep N yearly snapshots | `1` | `KEEP_YEARLY` |
| Retention | Keep every snapshot newer than | empty | `KEEP_WITHIN` |
| Retention | Prune unreferenced data after forgetting | yes | `PRUNE` |
| Options | Tags, comma separated | the job name | `BACKUP_TAGS` |
| Options | Stay on one file system | yes | `ONE_FILE_SYSTEM` |
| Sources | Directories and files to back up | none, at least one | the `src` file |
| Excludes | Patterns restic should skip | none | the `exclude` file |

How the prompts behave:

- **Each answer is checked when you enter it.** A rejected answer is shown again so you can fix it. The schedule is parsed by `systemd-analyze` and the next run time is printed.
- **At least one retention rule is required.** A job without one would keep every snapshot forever.
- **Lists are entered one item per line.** An empty line ends the list. When a job already has entries, they are listed first and you can keep them or enter new ones.
- **Re-running `add` for an existing job pre-fills every prompt** with the current value. In a terminal you can edit the value in place, and clearing an optional value unsets it.
- **Defaults are only offered for a new job.** In an existing job, a rule you left empty stays empty when you accept the prompt.
- **Before writing, `add` shows a summary** and asks for confirmation.

Source paths must be absolute. A path that does not exist on this machine is accepted with a warning, which helps when preparing a job for a new host.

Exclude patterns use restic's syntax, for example `**/node_modules`, `**/.cache`, `*.tmp` or `/home/*/.local/share/Trash`.

### `resticagent import FILE [JOB] [--global] [-y]`

Creates or replaces one job from an env file, without prompts. On a host that has no global settings yet, the same file creates those too. A new machine can then be set up with one file and two commands:

```sh
./bin/resticagent import home.env
./bin/resticagent install
```

An example file:

```sh
# home.env: this laptop's home directory, backed up to the NAS
JOB=home
RESTIC_REPOSITORY=sftp:backup@nas.local:/srv/restic
RESTIC_PASSWORD=correct-horse-battery-staple
ON_CALENDAR=*-*-* 02:00:00
RANDOMIZED_DELAY=30min
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
SRC=/home/me, /etc
EXCLUDE=**/node_modules, **/.cache, *.tmp
```

The file format:

- **One `KEY=VALUE` per line.** Blank lines and lines starting with `#` are ignored, and an `export ` prefix is allowed.
- **Nothing is interpreted.** One pair of single or double quotes around a value is removed. There are no variables, escapes or comments after a value. The file is read, never executed.
- **Values can't contain a single quote or a backslash,** the same rule as for all settings.
- **`SRC` and `EXCLUDE` hold comma-separated lists.** Spaces around each item are removed, so a path may contain spaces but not commas.
- **A key that appears twice** takes its later value, with a warning.

The job's name is the `JOB` argument, else the `JOB` key in the file, else the file name without `.env`. So `import web.env` creates the job `web`.

Where each key goes:

| Keys | Written to |
| --- | --- |
| `SRC` and `EXCLUDE` | the job's `src` and `exclude` files, one item per line |
| `ON_CALENDAR`, `RANDOMIZED_DELAY`, the `KEEP_*` rules, `BACKUP_TAGS`, `ONE_FILE_SYSTEM`, `PRUNE` | the job's `env` file |
| `RESTIC_PASSWORD` | the password file, only if it doesn't exist yet |
| every other key, such as `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE` or backend credentials | the global settings, or an override for this job, as described below |

How restic settings and credentials are stored:

- **On a host without global settings,** they create `~/.config/resticagent/config`. The file must then set `RESTIC_REPOSITORY`. A missing `RESTIC_PASSWORD_FILE`, `RESTIC_CACHE_DIR` or `RESTIC_COMPRESSION` gets the same default as in `init`.
- **On a host with global settings,** a value equal to the global one is skipped. A different value is stored in the job's `env` file and applies to this job only. Importing one job therefore never changes another.
- **With `--global`,** a different value updates the global settings instead, which affects every job.

Job keys the file leaves out get the same defaults as a new job in `add`. Those are a daily schedule, a random delay of up to 15 minutes, the job name as its tag, and staying on one file system with pruning on. The retention defaults of 7 daily, 4 weekly, 6 monthly and 1 yearly snapshot apply only when the file has no `KEEP_*` key at all. `ONE_FILE_SYSTEM` and `PRUNE` accept `1` or `0`, as well as `yes`, `no`, `true`, `false`, `on` and `off`.

`RESTIC_PASSWORD` is written to the job's password file with mode 0600, and never to a settings file. If the password file already exists and holds a different password, `import` stops. Overwriting it would lock you out of an existing repository, so change a repository's password with `restic key passwd` instead. Without `RESTIC_PASSWORD`, `import` offers to create a missing password file when run in a terminal, and only warns when run with `-y`.

`import` checks the whole file before writing anything, the same way the `add` prompts check answers, and lists every problem at once. Problems are reported by line number or key name, never with the value, since values can be secrets. When the file is clean, `import` shows a summary and asks for confirmation. Add `-y` to skip the question in scripts.

The file describes the whole job. Settings it leaves out fall back to the defaults rather than keeping the job's earlier values. Importing the same file again changes nothing. A job created by `import` can be edited with `add` and the other way round, and `add` keeps the overrides that `import` stored.

Keep the file private, for example with `chmod 600 home.env`, because it can hold the repository password and credentials. Don't commit it to a public repository.

### `resticagent install [--skip-repo-check] [JOB...]`

Installs and activates jobs. Without job names it installs every configured job. It is safe to run any number of times.

1. It checks that systemd is running and, for your own jobs, that your systemd user manager can be reached. It also checks that restic 0.17 or newer is installed, and that the global settings exist.
2. It copies itself to `~/.local/bin/resticagent` and the unit templates from the `systemd/` folder to `~/.config/systemd/user/`. The templates get your own program and settings paths. User units leave out `PrivateTmp=`, which needs user namespaces there.
3. It validates each job: source paths, repository, password file, schedule, random delay and retention rules.
4. It opens each job's repository, unless `--skip-repo-check` is given. Jobs that share a repository and password are checked once.
5. It writes each job's schedule to `restic-backup@<job>.timer.d/schedule.conf`.
6. It reloads systemd if any unit file changed, enables and starts each timer, and restarts a running timer whose schedule changed.
7. It prints each job's schedule and next run time. For your own jobs without lingering, it reminds you that the timers fire only while you are logged in.

How the repository check affects a job:

| Outcome | What happens |
| --- | --- |
| The repository opens | The job is activated. |
| The repository does not exist | In a terminal, `install` offers to run `restic init`. Otherwise the job is not activated. |
| Wrong password | The job is not activated. |
| No answer within 120 seconds, or another error | A warning is printed and the job is activated anyway, since the network may only be down for now. |

`install` also warns about timers whose job configuration was deleted. It exits with status 1 if any job could not be activated, after installing all the others.

Run `install` again after changing a job's schedule. Other changes take effect at the job's next run without it.

## Running backups

### Schedules

The schedule is a systemd calendar expression. Some examples:

| Expression | Runs |
| --- | --- |
| `daily` | every day at midnight |
| `hourly` | at the start of every hour |
| `weekly` | Mondays at midnight |
| `*-*-* 02:00:00` | every day at 02:00 |
| `Mon..Fri 18:00` | weekdays at 18:00 |
| `Sun 03:00` | Sundays at 03:00 |
| `*-*-* 00/6:00:00` | every 6 hours, from midnight |
| `*:0/30` | every 30 minutes |
| `*-*-01 04:00:00` | on the first day of each month at 04:00 |

Test an expression with `systemd-analyze calendar 'Mon..Fri 18:00'`.

The random delay spreads runs out, so several machines or jobs don't all start at the same second. Use `0` to turn it off.

Timers are persistent. If the machine was off when a run was due, the job runs shortly after the next boot. Your own jobs' timers only fire while you are logged in, so a run missed while you were logged out starts at your next login. Run `loginctl enable-linger` once to have them fire whenever the machine is on.

### `resticagent start JOB [--no-wait]`

Runs a job now through systemd, exactly as its timer would, and prints its log until the backup ends.

```sh
resticagent start home
resticagent start home --no-wait
```

- The run appears in `status` and `logs`, and it gets the service's lower CPU and disk priority.
- A job never runs twice at the same time. If a backup of the job is already running, `start` says so and follows that run from its beginning.
- Ctrl-C stops following, but the backup keeps running in the background.
- `--no-wait` starts the backup and returns at once.
- The exit status is the backup's own. See [Exit codes](#exit-codes).

The units must be installed first. A configured job without a timer can still be started by hand.

### `resticagent run JOB`

Runs a job directly in your terminal, outside systemd. The service uses this command itself, so a manual `run` does exactly what a scheduled run does. Prefer `start` for manual runs, because a `run` does not appear in `status` or `logs` and is not protected against overlapping a scheduled run.

What a run does:

1. It reads `~/.config/resticagent/config`, then the job's `env`, so job values override global ones.
2. It runs `restic backup` with the job's `src` and `exclude` files, its tags, and `--one-file-system` if enabled.
3. If the backup succeeded, or saved a snapshot with some unreadable files, it runs `restic forget` with the job's retention rules. It considers only snapshots tagged `job:<job>`, grouped by host, and adds `--prune` if enabled.

Both restic commands wait up to 30 minutes for a repository lock, so jobs that share a repository take turns instead of failing.

## Monitoring

### `resticagent status [JOB]`

Shows every configured or installed job. It needs no root, also not for the system-wide jobs, which `resticagent --system status` shows.

```text
  JOB   TIMER   LAST RUN                     RESULT           NEXT RUN
  etc   active  Thu 2026-10-15 07:00:03 PKT  failed (exit 1)  Thu 2026-10-15 08:00:00 PKT
  home  active  Thu 2026-10-15 02:13:05 PKT  ok               Fri 2026-10-16 02:21:44 PKT
```

| Column | Values |
| --- | --- |
| TIMER | `active` or `inactive`, plus `disabled` if it won't start at boot. `not installed` if `install` hasn't run for the job. `no config` if the job's directory was deleted. |
| LAST RUN | When the last run started. For a run before the last boot, it is when that run ended, taken from the journal. |
| RESULT | `ok`, `running`, `failed (exit N)`, `partial (exit 3, unreadable files)` or `never run` |
| NEXT RUN | The next time the timer fires, as systemd reports it |

`status` exits with 1 when any job's last run failed or was partial, so it works as a check in scripts and monitoring.

With a job name, `status home` shows systemd's full status of the job's timer and service, including their most recent log lines.

### `resticagent logs [JOB] [--last] [journalctl options]`

Shows the journal of all jobs, or of one job. Your own jobs log to your user journal, which you can always read. `resticagent --system logs` shows the system-wide jobs without root, if you may read the system journal, for example through the `adm` or `systemd-journal` group.

```sh
resticagent logs                      # all jobs, opened at the newest line
resticagent logs home                 # one job
resticagent logs home --last          # only the most recent run of the job
resticagent logs home -f              # follow new lines as they arrive
resticagent logs --since today        # all jobs, today only
resticagent logs home --since "2 days ago" --grep snapshot
```

Without options it shows the last 200 lines and opens the pager at the end. Any option other than `--last` is passed to `journalctl` unchanged.

### `resticagent list [JOB]`

Shows the global settings and a table of all jobs:

```text
  JOB   STATE          SCHEDULE        RETENTION           SOURCES
  db    not installed  hourly          last 3 7d 4w 6m 1y  1 path(s)
  etc   needs install  Sat 04:00       last 3 7d 4w 6m 1y  1 path(s)
  home  installed      *-*-* 02:00:00  7d 4w 6m 1y         3 path(s)
```

| STATE | Meaning |
| --- | --- |
| `installed` | The timer is enabled and matches the job's schedule. |
| `disabled` | The timer is installed but not enabled. |
| `needs install` | The schedule was changed after the last `install`. |
| `not installed` | The job is configured but `install` hasn't run for it. |
| `timer without config` | A timer is installed, but the job's directory was deleted. |

Retention uses short forms: `7d 4w 6m 1y` means 7 daily, 4 weekly, 6 monthly and 1 yearly snapshot.

`list home` shows one job in full. That includes each setting and whether it comes from the job or the global settings, whether the password file exists, the next run, and every source and exclude line.

## Changing a job

- **Re-run `add`** for the job. Every prompt starts from the current value.
- **Or edit your import file and import it again.** The job is replaced by what the file says.
- **Or edit the files directly.** Keep the `KEY='VALUE'` format described in the [File reference](#file-reference).
- **After changing the schedule, run `install`.** `list` shows `needs install` until you do. Other changes take effect at the next run.
- **To change global settings,** run `init` again.

### Moving a system-wide job to your own

1. Stop the system-wide job: `sudo resticagent remove <job>`. Keep its settings file or note its settings first, since this deletes its configuration.
2. Give yourself the repository, if it is a local directory. Runs as root leave files that only root can read: `sudo chown -R "$USER": /path/to/repository`.
3. Create the job as yourself with `resticagent import` or `resticagent add`. Its password file must be one you can read, such as the default `~/.config/resticagent/password`.
4. Run `resticagent install <job>`.

Snapshots made by the system-wide job stay in the repository. They carry the same `job:<job>` tag, so retention keeps treating them as part of the job.

## Forgetting snapshots

Retention runs after every backup. To forget snapshots now, without a backup or a change to the job's rules, use `forget`:

| Command | Forgets |
| --- | --- |
| `forget home --keep-last 5` | all but the 5 newest snapshots of each host |
| `forget home --older-than 30d` | the snapshots more than 30 days older than the newest one of their host |
| `forget home --keep-last 5 --older-than 30d` | only the snapshots that neither rule keeps |
| `forget home --oldest 3` | the 3 oldest snapshots of the job, whichever host made them |

- **It shows what will go.** `forget` lists the snapshots it picked and asks before forgetting them. `--dry-run` stops after the list, and `-y` skips the question in scripts.
- **Exactly the listed snapshots are forgotten.** They are forgotten by ID, so a backup that finishes while you answer does not change the selection.
- **`--keep-last` and `--older-than` work like the job's retention.** They are restic's `--keep-last` and `--keep-within`, applied per host. `--older-than` counts back from the newest snapshot, not from today, so a job whose backups stopped never loses all of its snapshots this way. Durations use restic's units: `y`, `m`, `d` and `h`, as in `1y6m`.
- **`--oldest N` forgets N more each time it runs.** A number at least as large as the job's snapshot count forgets all of them, and `forget` warns before it does.
- **Pruning follows the job's `PRUNE` setting.** Pruning deletes the data no remaining snapshot uses, which is what frees space. `--prune` or `--no-prune` overrides the setting for one run.
- **Snapshots of other jobs are never touched,** even when they share the repository.

`forget` waits up to 30 minutes for a running backup to release the repository lock.

To delete a whole repository, delete its storage, such as the directory or the bucket, with the tools of its backend. restic has no command for it. Run `remove` for every job that uses it first, since `install` offers to create a new, empty repository where one is missing.

## Removing jobs

| Command | Effect |
| --- | --- |
| `remove home` | Stops and disables the job's timer, and deletes its schedule file and its configuration. |
| `remove home --keep-config` | Deactivates the job but keeps its configuration, so `install` can bring it back. |
| `remove --all` | Removes every job, the unit templates and `~/.local/bin/resticagent`. The global settings and the password file stay. |
| `remove --all --keep-config` | Uninstalls everything but keeps all configuration in `~/.config/resticagent`. |
| `remove --all --purge` | Uninstalls everything and deletes `~/.config/resticagent`, including a password file stored there. |

These only touch one set of jobs: your own, or the system-wide ones with `sudo`.

`remove` lists what it will delete and asks before doing anything. Add `-y` to skip the question in scripts.

A backup that is running when you remove its job is allowed to finish. Snapshots in the repository are never deleted. To delete a job's snapshots too, run `forget` before `remove`, since `forget` needs the job's settings. For a job that is already removed, run `restic forget --tag job:<job> --prune` against its repository, with its settings loaded as shown in the next section.

## Restoring files

resticagent schedules and runs backups. For restores, use restic directly with the job's settings loaded:

```sh
set -a
. ~/.config/resticagent/config
. ~/.config/resticagent/config.d/home/env
set +a

restic snapshots --tag job:home
restic ls latest --tag job:home
restic restore latest --tag job:home --target /tmp/restore
restic restore latest --tag job:home --target /tmp/restore --include /home/me/Documents
```

`set -a` exports every variable the files define, so restic finds the repository, the password file and any credentials. Restore into a separate directory first, then copy back what you need. For a system-wide job, start with `sudo -i` and load the files in `/etc/resticagent` instead.

To browse snapshots like a folder, use `restic mount /mnt/restic`. This needs FUSE.

## File reference

All files are plain text. Values are written as `KEY='VALUE'`, one per line, and lines starting with `#` are comments. This format is valid for Bash and for systemd's `EnvironmentFile=`. A value may not contain a single quote or a backslash.

`config` and each job's `env` have mode 0600, because they can hold credentials. `src` and `exclude` are readable by all users.

### `~/.config/resticagent/config`

| Key | Meaning |
| --- | --- |
| `RESTIC_REPOSITORY` | The default repository for all jobs |
| `RESTIC_PASSWORD_FILE` | The file holding the repository password |
| `RESTIC_CACHE_DIR` | restic's local cache |
| `RESTIC_COMPRESSION` | `auto`, `off` or `max` |
| any other key | Passed to restic as an environment variable, for example backend credentials |

### `~/.config/resticagent/config.d/<job>/env`

| Key | Meaning | Example |
| --- | --- | --- |
| `RESTIC_REPOSITORY` | Overrides the global repository | `sftp:backup@nas:/srv/restic` |
| `RESTIC_PASSWORD_FILE` | Overrides the global password file | `/home/me/.config/resticagent/nas.password` |
| `ON_CALENDAR` | The schedule, as a systemd calendar expression | `*-*-* 02:00:00` |
| `RANDOMIZED_DELAY` | The largest random delay before a run | `30min` |
| `KEEP_LAST` | Keep the N most recent snapshots | `3` |
| `KEEP_HOURLY` | Keep the last snapshot of each of N hours | `24` |
| `KEEP_DAILY` | Keep the last snapshot of each of N days | `7` |
| `KEEP_WEEKLY` | Keep the last snapshot of each of N weeks | `4` |
| `KEEP_MONTHLY` | Keep the last snapshot of each of N months | `6` |
| `KEEP_YEARLY` | Keep the last snapshot of each of N years | `1` |
| `KEEP_WITHIN` | Keep every snapshot newer than a duration | `30d`, `1y6m` |
| `BACKUP_TAGS` | Extra tags for each snapshot, comma separated | `home,laptop` |
| `ONE_FILE_SYSTEM` | `1` to stay on the file system of each source path | `1` |
| `PRUNE` | `1` to prune unreferenced data after forgetting | `1` |

Omit a key to leave it unset. At least one `KEEP_*` key is required.

Any other key is passed to restic for this job only, on top of the global settings. `import` stores a value here when it differs from the global one, for example credentials for a job's own repository. `list <job>` shows these keys by name.

When restic has fewer snapshots than a rule asks for, it may keep an extra older snapshot to fill the rule. New jobs therefore keep a few more snapshots than the numbers suggest until enough history exists.

### `~/.config/resticagent/config.d/<job>/src`

One absolute path per line. The file is passed to `restic backup --files-from-verbatim`, so every line is taken literally. It can't contain comments, and paths with spaces need no quoting.

### `~/.config/resticagent/config.d/<job>/exclude`

One restic exclude pattern per line, passed to `restic backup --exclude-file`. Lines starting with `#` are comments.

## Exit codes

`run` and `start` return restic's exit code:

| Code | Meaning |
| --- | --- |
| 0 | The backup and retention succeeded. |
| 1 | The backup failed. |
| 3 | A snapshot was saved, but some source files could not be read. Retention was still applied. |
| 10 | The repository does not exist. |
| 11 | The repository could not be locked within 30 minutes. |
| 12 | The password is wrong. |
| 130 | `start` stopped following after Ctrl-C. The backup itself keeps running. |

If the backup fails, retention is skipped. If the backup succeeds but `restic forget` fails, `run` returns the code from `forget`.

`forget` returns the exit code of `restic forget` when that fails, for example 11 when the lock could not be taken.

`status` returns 1 when any job's last run failed or was partial, and 0 otherwise. `logs` returns the exit code of `journalctl`. The other commands return 0 on success and 1 on an error.

## Troubleshooting

**`error: system-wide jobs need root`.** The command was given `--system`. Prefix it with `sudo` to change the system-wide jobs, or leave out `--system` to work with your own. Only `status`, `logs`, `help` and `version` work with `--system` and without root.

**`cannot reach the systemd user manager`.** Your own jobs need your systemd user manager, which a login session starts. A shell from `su` or `sudo -u` has none. Log in as that user directly, for example over SSH.

**`permission denied` in a backup of your own job.** Your own jobs can only back up files you can read. Back up other files with a system-wide job, created with `sudo`.

**Your timers don't fire while you're logged out.** That is how user units work. Run `loginctl enable-linger` once to keep your systemd user manager running.

**`repository ... does not exist yet`.** Run `resticagent install <job>` in a terminal and accept the offer to initialize the repository. Or create it yourself with `restic init`, with the settings loaded as shown in [Restoring files](#restoring-files).

**`wrong password for ...`.** The password file doesn't match the repository. Check the path with `resticagent list <job>`, then fix the file's content.

**A backup failed.** Run `resticagent logs <job> --last` to see the whole run, including restic's error message.

**A timer never fires.** Run `resticagent status`. If the timer shows `not installed`, `inactive` or `disabled`, run `resticagent install <job>`. To see systemd's own view, run `systemctl --user list-timers 'restic-backup@*'`, or `systemctl list-timers 'restic-backup@*'` for system-wide jobs.

**The schedule didn't change.** `resticagent list` shows `needs install` for the job. Run `resticagent install <job>`.

**`unable to create lock`, or exit code 11.** Another backup or prune is holding the repository lock, or a crashed run left a stale lock. Once no backup is running, load the job's settings and run `restic unlock`, which only removes stale locks.

**A path in `src` doesn't exist.** restic logs `does not exist, skipping` and backs up the other paths, and the run still succeeds. Only when every path is missing does the backup fail. Check `resticagent logs <job> --last` for these warnings, and update the paths with `resticagent add <job>`.
