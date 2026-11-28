# Installer Log

**Window → Installer Log** (⌘L) opens a live log of what the installer and its privileged helper are doing. It is modelled on the Installer Log of Apple's Install macOS app in macOS Recovery: a separate window with a level filter, a search field and **Save…**, and timestamped monospaced lines that follow new output unless you scroll up.

## What it shows

Each line has a time, a source and a message. Sources are `Installer` for the app, `helper` for the privileged helper, and the name of a tool or subsystem (`diskutil`, `download`, `journal`, `firmware`). Lines from the helper carry a `helper/` prefix, for example `helper/diskutil`.

- **Phases.** Each change of screen phase (inspection, plan preparation, plan review, authorization, installation, Recovery handoff, failure), with the time spent in the phase it left.
- **Steps.** Every step the helper measures for its timing journal (`InstallerPerformance`): credential validation, plan import, each native preflight stage (`apfs`, `stub_files`, `os_partitions`, `payload_images`, `esp_files`, `finishing`), each disk change, finishing and the Recovery handoff, with start, end and duration. Outermost steps are progress lines; the steps inside them are debug lines; a step that stops is an error.
- **Performance.** Debug records give monotonic elapsed nanoseconds, completion status, and process CPU consumed during each measured interval. CPU can include unrelated work in the same process and excludes subprocesses. Overlapping intervals share CPU time. Where the catalog, archive or staging inputs supply a size, the record gives expected bytes. Resume and cache hits can reduce the bytes transferred on the network, and interrupted work can stop short of the expected size.
- **Journal.** Each record the execution journal gains. Checkpoints and the completion are progress lines.
- **Downloads.** Host and file (never the query), size, progress at each tenth with rate and time left, debug lines every two seconds, retries, cache hits, bundled copies, and verification against the signed catalog. The helper's firmware range reads from Apple's servers are debug lines; their retries are progress lines.
- **Commands.** Every tool the app or helper starts (`diskutil`, `bless`, `hdiutil`, `codesign`, `newfs_msdos`, `launchctl`, the stub decoder): the redacted command line, exit status and duration. A failure adds the last three lines of the tool's standard error at error level. The footer lists commands and transfers still running.
- **Errors.** The failure the person sees, its technical cause, and the helper's own failure notice: reason, exit status, whether the disk is unchanged, and the per-stage summary.

## Levels

| Filter | Shows |
| --- | --- |
| Show Errors Only | errors |
| Show Errors and Progress (default) | errors and progress |
| Show All Logs | everything, including commands, journal detail and download detail |

The window remembers the filter. Search matches message and source, ignoring case, and highlights matches in both. The window keeps up to 12,500 lines and trims back to 10,000 a quarter at a time. **Save…** writes the lines currently shown, with full dates, to a file you choose.

## Redaction

Every line passes through `InstallerLogRedactor` before it is stored, in both processes, and again when the app receives the helper's lines.

- The helper's diagnostics redaction (`EngineStandardErrorRedactor`) applies: exact secrets, credential-named `key=value` and `key: value` pairs (withheld to the end of the line), bearer and basic tokens, bytes literals, terminal escapes and control characters.
- The macOS password is removed wherever it appears. The helper registers it for the duration of a job, and the app for the duration of authorization and execution (`InstallerLog.redacting`).
- In command lines, known secrets are removed from each argument before it is quoted. Everything after a flag whose name contains password, passwd, passphrase, secret or token, or after `-p`, is withheld, since some tools take several values there (`dscl . -passwd user old new`). The value after an account flag such as `--user` is withheld, as is a credential-named `key=value`. Native stages hand passwords to tools on stdin, so this is defense in depth.
- URLs keep their scheme, host and path. Credentials, query and fragment are removed, and an Apple FCS key name is withheld.
- The person's home folder becomes `~`, and any other home folder loses its account name.
- Each line is cut to 2,000 bytes of UTF-8, never inside a character.
- The full redacted standard-error tail stays in the helper's root-only diagnostics, as before. The log carries only the last three lines, each cut to one printable line of at most 200 characters, the treatment a failure summary already gets. Observation tokens, catalog signatures and job tickets are never logged.

## From the helper to the app

The helper keeps each job's lines in a bounded in-memory ring (4,000 lines; the last four jobs). The app reads them through the existing job status call, which it already polls while it watches a job. The status request carries an optional `logSequence` cursor and the ring it was read from, and the snapshot carries an optional `log` batch of at most 512 lines and 512 KB, and less when a transcript fills most of the 12 MB the app accepts. Older helpers never send the batch, older apps never send the cursor, and both sides ignore what they don't know, as `preparationStep` already does. The app reads the log leniently: an unknown level reads as detail, and a log it can't read is left out without failing the job. The helper never waits on the app: a full ring drops its oldest line, and the app writes a line saying how many it missed.

The app keeps one reader per job for its whole life, so watching a job again, as a Recovery retry or a watch begun at launch does, continues where the last watch stopped; a ring from a restarted helper is read from its start. While lines remain the app polls again sooner, and when the job ends it fetches the rest, the failure among them, then ends any command the helper was still running in the footer. Helper lines are redacted again in the app, with the app's secrets.

Work the helper does outside a job (removal, Recovery account updates) is not logged into any job.

## Saved log

The live app also appends every level to `~/Library/Logs/Aurora Installer/installer.log` (0600 in a 0700 folder, made 0600 if it was not), starting each launch with a header naming the app version, Mac model and macOS version. A failed install therefore leaves its whole log behind. At 4 MB the file moves to `installer.1.log`, and two older files are kept, so the log never takes more than 12 MB. Writing happens on its own queue. If the disk falls behind by 2 MB, lines are dropped and their count is written once it catches up. Neither the folder nor the file is ever a symbolic link the log writes through. The helper's root-only diagnostics are unchanged.

Simulations, previews and renders keep the log in memory only, so a rehearsal never reads as a real installation.

## Renders

`--render-flow=DIRECTORY` (debug builds) ends with the log window, frozen mid-download, while the helper runs a command, and after a failed Recovery handoff, at each filter level, with search, in light and dark appearance. See [Simulation.md](Simulation.md#flow-renders).
