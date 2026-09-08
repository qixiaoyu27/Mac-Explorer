#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <locale.h>

/* Public libarchive ABI (documented in the macOS SDK man pages).
   Apple ships libarchive.2 but does not ship its headers with the SDK. */
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern unsigned short archive_entry_filetype(struct archive_entry *);
extern unsigned short archive_entry_perm(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);

static void fail(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }
static void systemFail(void) { fail(strerror(errno)); }
static void jsonString(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    if (*p == '"' || *p == '\\') printf("\\%c", *p);
    else if (*p < 32) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}
static char *safePath(const char *raw) {
  if (!raw || raw[0] == '/' || strchr(raw, '\\') || strchr(raw, ':')) fail("压缩包包含不安全或不支持的路径。");
  char *copy = strdup(raw), *out = calloc(strlen(raw) + 1, 1), *save = NULL;
  if (!copy || !out) fail("内存不足。");
  for (char *part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
    if (!strcmp(part, "..")) fail("压缩包包含越界路径，已停止解压。");
    if (!strcmp(part, ".")) continue;
    if (strlen(part) > 255) fail("压缩包文件名过长。");
    if (*out) strcat(out, "/");
    strcat(out, part);
  }
  free(copy); return out;
}
static int parentFD(int root, char *name, char **leaf) {
  int fd = dup(root); if (fd < 0) systemFail();
  char *cursor = name, *slash;
  while ((slash = strchr(cursor, '/'))) {
    *slash = 0;
    if (mkdirat(fd, cursor, 0700) && errno != EEXIST) systemFail();
    int next = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (next < 0) systemFail();
    close(fd); fd = next; cursor = slash + 1;
  }
  *leaf = cursor; return fd;
}
int main(int argc, char **argv) {
  setlocale(LC_ALL, "en_US.UTF-8");
  if (argc == 4 && !strcmp(argv[1], "quarantine")) {
    char value[65536];
    ssize_t length = getxattr(argv[2], "com.apple.quarantine", value, sizeof value, 0, 0);
    if (length < 0) { if (errno == ENOATTR) return 0; systemFail(); }
    if (setxattr(argv[3], "com.apple.quarantine", value, (size_t)length, 0, XATTR_NOFOLLOW)) systemFail();
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "publish")) {
    /* Atomic no-replace rename, including directories and concurrent collisions. */
    if (renameatx_np(AT_FDCWD, argv[2], AT_FDCWD, argv[3], RENAME_EXCL)) systemFail();
    return 0;
  }
  int extracting = argc >= 4 && !strcmp(argv[1], "extract");
  if (!(argc == 3 && !strcmp(argv[1], "list")) && !extracting) fail("无效的归档操作。");
  int root = extracting ? open(argv[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW) : -1;
  if (extracting && root < 0) systemFail();
  struct archive *a = archive_read_new();
  if (!a) fail("无法创建归档读取器。");
  archive_read_support_filter_all(a); archive_read_support_format_all(a);
  if (archive_read_open_filename(a, argv[2], 65536) != 0) fail("无法读取压缩包，格式不支持、目录已加密或文件损坏。");
  struct archive_entry *entry;
  unsigned count = 0; int status; uint64_t declared = 0, written = 0;
  while ((status = archive_read_next_header(a, &entry)) == 0) {
    if (++count > 10000) fail("压缩包超过 10,000 项限制。");
    char *name = safePath(archive_entry_pathname_utf8(entry));
    unsigned short type = archive_entry_filetype(entry);
    if (archive_entry_hardlink(entry) || (type != S_IFREG && type != S_IFDIR)) fail("暂不支持解压包含链接或特殊文件的压缩包。");
    int64_t size = archive_entry_size(entry);
    if (size < 0 || (declared += (uint64_t)size) > 20ULL * 1024 * 1024 * 1024) fail("解压内容超过 20 GB 限制。");
    if (!*name) { free(name); continue; }
    if (!extracting) {
      printf("{\"path\":"); jsonString(name); printf(",\"directory\":%s,\"size\":%lld}\n", type == S_IFDIR ? "true" : "false", (long long)size);
      free(name); continue;
    }
    int selected = argc == 4;
    for (int i = 4; i < argc; i++) {
      size_t n = strlen(argv[i]);
      if (!strcmp(name, argv[i]) || (strncmp(name, argv[i], n) == 0 && name[n] == '/')) selected = 1;
    }
    if (!selected) { free(name); continue; }
    char *leaf; int parent = parentFD(root, name, &leaf);
    if (type == S_IFDIR) {
      if (mkdirat(parent, leaf, 0700) && errno != EEXIST) systemFail();
      int dir = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
      if (dir < 0) systemFail();
      close(dir);
    } else {
      int fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
      if (fd < 0) fail("包内存在重名文件或无法写入，已停止解压。");
      char buffer[65536]; ssize_t length;
      while ((length = archive_read_data(a, buffer, sizeof buffer)) > 0) {
        if ((written += length) > 20ULL * 1024 * 1024 * 1024) fail("实际解压内容超过 20 GB 限制。");
        ssize_t offset = 0;
        while (offset < length) { ssize_t n = write(fd, buffer + offset, length - offset); if (n < 0) { if (errno == EINTR) continue; systemFail(); } offset += n; }
      }
      if (length < 0) fail("文件解压失败，数据已损坏或需要密码。");
      if (fchmod(fd, 0600 | (archive_entry_perm(entry) & 0111))) systemFail();
      if (close(fd)) systemFail();
    }
    close(parent); free(name);
  }
  if (status != 1) fail("压缩包读取失败，可能已损坏或需要密码。");
  archive_read_free(a); if (root >= 0) close(root);
  return 0;
}
