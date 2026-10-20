# Streaming restore members

`IPSWArchive.stream` delivers stored or deflated ZIP/ZIP64 members in bounded chunks. Callers supply independent uncompressed and compressed byte budgets. The existing small-member `read` API uses this decoder and retains its 64 MiB maximum; large restore-file callers can stream into a private destination without retaining either complete representation in memory.

Stored-member transfers are at most 4 MiB; deflate output chunks are at most 1 MiB. Cancellation and sink failures stop delivery. Completion requires the exact directory-declared compressed and uncompressed lengths, CRC32 and an optional expected SHA-256. Trailing, truncated or oversized deflate streams fail.

A sink must keep its result private until the call returns successfully. A later CRC or digest failure can invalidate previously delivered chunks. The caller remains responsible for protected destination admission, available-space checks, flushing, atomic publication and cleanup. The selected source's authentication remains a separate requirement; a ZIP checksum is not a signature.

This primitive is used by native metadata and payload admission reads. Connecting large restore files to native stub-file population is still required.
