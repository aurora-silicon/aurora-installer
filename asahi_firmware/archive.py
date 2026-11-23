# SPDX-License-Identifier: MIT
"""Extraction of the raw firmware archive (all_firmware.tar.gz).

The archive holds regular files, directories and the aliases macOS names
its firmware by: symbolic links to a sibling file (firmware/wifi) or to a
file elsewhere in the archive (fud_firmware/<board>/X -> ../Firmware/Y).
The collectors open whatever a name resolves to, so only members that stay
inside the destination are extracted:

 - names must be relative and free of "..";
 - nothing is written through a symbolic link;
 - a symbolic link is kept only when it resolves inside the destination
   (a dangling one that would still land inside is kept, as tar keeps it);
 - a hard link is kept only when it names a regular file already extracted;
 - devices, FIFOs and anything else are skipped.

A member that is skipped is logged; the rest of the archive is extracted.
That includes a name or link target too long for the destination. Archive
read failures and other filesystem errors stop extraction.

The archive is extracted into a temporary directory, often in RAM, so its
size is bounded: an archive with more members, a larger member or more
bytes in all than the limits below is refused with ArchiveError, and
nothing of it is used. The limits are far above a real archive: a 2024
MacBook Pro's (macOS 26, J616s) has 3567 members, 1021 regular files,
the largest 4.6 MB, 87 MB in all.
"""
import errno, logging, os, shutil, stat, tarfile

log = logging.getLogger("asahi_firmware.archive")

__all__ = ["extract_archive", "ArchiveError",
           "MAX_MEMBERS", "MAX_MEMBER_SIZE", "MAX_TOTAL_SIZE"]

MAX_MEMBERS = 65536
MAX_MEMBER_SIZE = 256 << 20
MAX_TOTAL_SIZE = 1 << 30

class ArchiveError(ValueError):
    """The archive is larger than a firmware archive can be."""

def _parts(name):
    """The path components of a member name, or None if it is not a plain
    relative path. [] is the archive root itself ("." or "./")."""
    if name.startswith("/") or "\0" in name:
        return None
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if ".." in parts:
        return None
    return parts

def _is_dir(path):
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False

def _is_file(path):
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False

def _make_dirs(dest, parts):
    """Create dest/parts as real directories. False if a component exists
    and is not a directory (a symbolic link is not one)."""
    path = dest
    for p in parts:
        path = os.path.join(path, p)
        if _is_dir(path):
            continue
        if os.path.lexists(path):
            return False
        os.mkdir(path, 0o700)
    return True

def _clear(path):
    """Remove the file or link at path (a later member of the same name
    replaces it, as tar does). False if a directory is in the way."""
    if not os.path.lexists(path):
        return True
    if _is_dir(path):
        return False
    os.unlink(path)
    return True

def _inside(dest, path):
    return path == dest or path.startswith(dest + os.sep)

def _extract_member(tar, m, dest, skip, links):
    parts = _parts(m.name)
    if parts is None:
        skip(m, "not a relative path inside the archive")
        return
    if not parts:
        return
    if not (m.isdir() or m.isreg() or m.issym() or m.islnk()):
        skip(m, "not a file, directory or link")
        return
    if m.isdir():
        if not _make_dirs(dest, parts):
            skip(m, "a non-directory is in the way")
        return
    if not _make_dirs(dest, parts[:-1]):
        skip(m, "its directory is not a directory")
        return
    path = os.path.join(dest, *parts)

    if m.issym():
        target = os.path.normpath(os.path.join(*parts[:-1], m.linkname))
        if (not m.linkname or m.linkname.startswith("/") or "\0" in m.linkname
                or target == ".." or target.startswith("../")):
            skip(m, f"link to {m.linkname!r} leaves the archive")
            return
        if not _clear(path):
            skip(m, "a directory is in the way")
            return
        os.symlink(m.linkname, path)
        links.append((path, m))
    elif m.islnk():
        tparts = _parts(m.linkname)
        target = os.path.join(dest, *tparts) if tparts else None
        # The target's directories were made by _make_dirs or are
        # absent, unless a link replaced one since: resolve to check.
        if (target is None or not _is_file(target)
                or os.path.realpath(os.path.dirname(target)) != os.path.dirname(target)):
            skip(m, f"hard link to {m.linkname!r}, which is not an extracted file")
            return
        if target == path:
            return
        if not _clear(path):
            skip(m, "a directory is in the way")
            return
        os.link(target, path)
    else:
        src = tar.extractfile(m)
        if src is None or not _clear(path):
            skip(m, "a directory is in the way")
            return
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "wb") as out:
                shutil.copyfileobj(src, out)
        except BaseException:
            # Do not leave a partial file for the collectors.
            try:
                os.unlink(path)
            except OSError:
                pass
            raise

def extract_archive(archive, dest):
    """Extract archive under the existing directory dest. Returns the names
    of the members that were skipped. Raises ArchiveError, having extracted
    part of it, for an archive over the size limits."""
    dest = os.path.realpath(dest)
    skipped = []

    def skip(m, why):
        log.warning(f"Not extracting {m.name!r}: {why}")
        skipped.append(m.name)

    links = []
    members = 0
    total = 0
    with tarfile.open(archive, mode="r:*") as tar:
        for m in tar:
            members += 1
            if members > MAX_MEMBERS:
                raise ArchiveError(f"{archive}: more than {MAX_MEMBERS} members; "
                                   "not a firmware archive")
            if m.isreg():
                if m.size > MAX_MEMBER_SIZE:
                    raise ArchiveError(f"{archive}: member {m.name!r} has {m.size} bytes, "
                                       f"more than {MAX_MEMBER_SIZE}; not a firmware archive")
                total += m.size
                if total > MAX_TOTAL_SIZE:
                    raise ArchiveError(f"{archive}: more than {MAX_TOTAL_SIZE} bytes "
                                       "in all; not a firmware archive")
            try:
                _extract_member(tar, m, dest, skip, links)
            except OSError as e:
                # For link calls, filename2 is the name being created.
                path = e.filename2 or e.filename
                if e.errno != errno.ENAMETOOLONG or path is None or not _inside(dest, path):
                    raise
                skip(m, f"{e.strerror or e}")

    # A link's name can stay inside the tree while what it resolves to does
    # not (through another link to a directory). Check where each one that
    # is still present really leads, now that the tree is complete.
    for path, m in links:
        if os.path.islink(path) and not _inside(dest, os.path.realpath(path)):
            os.unlink(path)
            skip(m, f"link to {m.linkname!r} leaves the archive")
    return skipped
