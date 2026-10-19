# Helper-owned installation jobs

The GUI records a private lookup capability before it sends a job to the authenticated helper. A request includes a random observation token, UUID, approved binding, selected profile and strict install.conf document. Credentials are sent only with the initial submission and remain in the worker’s memory; neither persistent store contains them.

The helper derives the initiating UID from each accepted XPC connection and retains the existing code-signing requirement. The registry binds the UID, token digest, operation and options to one job. An exact duplicate observes that job; another UID, token, binding or set of options is rejected. New execution still passes the existing credential, immutable handoff, supported-host, plan and engine admission checks.

The helper’s detached worker owns the replacement gate until execution, transcript validation and the encryption/lane handoff finish. Connection loss cannot cancel the worker. Read-only status uses independent synchronization and bounded journal chunks, so it remains responsive while the executor blocks the helper actor. The GUI does not infer completion from progress.

Records are atomically replaced, fsynced, private to their owner, bounded to 12 MiB each and limited to 32 jobs. Unsafe ownership, permissions, symlinks, hard links and malformed state fail closed. Helper restart marks unfinished records interrupted and never repeats a disk operation. Completed records retain the exact transcript and handoff outcome for authenticated replay.

Interrupted or unreadable root state holds the existing work/replacement gate: a child of the previous helper may still be alive. The installer requires inspection before allowing another privileged operation. It retains up to eight definitively non-mutating failures, so rejected passwords cannot exhaust the history. Rejected starts return an explicit not-admitted disposition; a missing lookup after a lost reply receives bounded observation retries and remains unknown if it cannot be resolved.

On reopening, the app restores the selected profile from its lookup hint and observes the job before fresh-install inspection. Terminal data passes the transcript validator and admitted plan/device identity checks. The existing live Recovery-target check still runs before the shutdown handoff. The app clears its hint only after validated completion or a confirmed credential rejection; an unknown outcome remains blocked.

This change reconnects helper jobs. Firmware preparation and plan construction now have native implementations; disk inspection and installation still use the existing engine adapter. See [native prepared inputs](native-prepared-inputs.md) for the current boundary.

Recovery-authorization retry is a separate credentialed action on the original job. It accepts only the ticket and a fresh attempt UUID, retains the original installation options, and revalidates the canonical root-owned package in place. The request cannot choose another operation, package or target. The helper checks the exact eight-record checkpoint and both evidence digests again before invoking only `retryRecoveryAuthorization`; the pinned backend additionally rereads the installed checkpoint.

Retry attempt IDs are recorded before a worker starts and remain in bounded history, preventing an older duplicate from executing again after another attempt. A lost reply observes its exact attempt without resending credentials. Bad retry credentials retain the original installation context. The GUI exposes this capability separately from fresh-install approval. Unknown retry integrity or terminal-persistence failures keep the work/replacement gate held for inspection.
