/*
 * smb-notrunc.so - LD_PRELOAD module for smbd (Samba) on CoreELEC
 *
 * Problem
 *   When the Windows copy engine (Explorer, Copy-Item) copies a file to a share it first
 *   sets the destination file to its final size (SMB2 SET_INFO / FileEndOfFileInformation).
 *   Samba turns that into ftruncate(). exfat-fuse can only grow a file by writing zeros
 *   over the whole new range, so every file is written twice: first zeros, then the data.
 *
 * What this module does
 *   An ftruncate() that would only GROW a regular file on a FUSE filesystem is skipped
 *   (it returns 0 without doing anything). The file then grows with the writes that
 *   follow. Shrinking, and every other filesystem (ext4, tmpfs, ...), is untouched.
 *
 * Side effect
 *   A file that is only pre-sized over SMB and never written stays empty/shorter
 *   instead of being padded with zeros.
 *
 * Build (any machine with zig, no sysroot needed):
 *   zig cc -target arm-linux-gnueabihf.2.34 -mcpu=cortex_a53 -shared -fPIC -O2 -s \
 *          -o smb-notrunc-armhf.so smb-notrunc.c
 *   CoreELEC Amlogic-ng has a 32-bit armhf userspace; this is the only build I tested.
 *   For an aarch64 userspace (untested): -target aarch64-linux-gnu.2.34, without -mcpu.
 *   A 32-bit smbd calls ftruncate64(), a 64-bit one ftruncate(); both are hooked.
 *   After installing, verify with the pre-size test of check.sh, not just /proc/PID/maps.
 *
 * Install: see README.md / install.sh.  Remove: delete
 *   /storage/.config/system.d/smbd.service.d/notrunc.conf
 *   then: systemctl daemon-reload; systemctl restart smbd
 *
 * Public domain / CC0. No warranty.
 */
#define _GNU_SOURCE
#define _LARGEFILE64_SOURCE
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vfs.h>
#include <unistd.h>

#define FUSE_SUPER_MAGIC 0x65735546UL

/* 1 if the call would only grow a regular file on a FUSE filesystem */
static int only_grows_fuse_file(int fd, off64_t length)
{
    struct statfs64 fs;
    struct stat64 st;

    return length > 0
        && fstatfs64(fd, &fs) == 0 && (unsigned long)fs.f_type == FUSE_SUPER_MAGIC
        && fstat64(fd, &st) == 0 && S_ISREG(st.st_mode)
        && length > st.st_size;
}

int ftruncate64(int fd, off64_t length)
{
    static int (*real)(int, off64_t);

    if (only_grows_fuse_file(fd, length))
        return 0;
    if (!real)
        real = (int (*)(int, off64_t))dlsym(RTLD_NEXT, "ftruncate64");
    return real(fd, length);
}

#ifdef __LP64__
/* 64-bit: off_t is off64_t, ftruncate and ftruncate64 are the same function */
int ftruncate(int fd, off_t length) __attribute__((alias("ftruncate64")));
#else
int ftruncate(int fd, off_t length)
{
    static int (*real)(int, off_t);

    if (only_grows_fuse_file(fd, length))
        return 0;
    if (!real)
        real = (int (*)(int, off_t))dlsym(RTLD_NEXT, "ftruncate");
    return real(fd, length);
}
#endif
