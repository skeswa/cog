// A call-site attributing allocation / ARC profiler for Cog.
//
// Loaded with DYLD_INSERT_LIBRARIES. It interposes malloc-family and the Swift
// runtime's retain/release entry points, and records a backtrace for every call
// made while recording is armed. Stacks are aggregated by identity so the
// report says "this call site, N times" rather than dumping N stacks.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <execinfo.h>
#include <malloc/malloc.h>
#include <mach-o/dyld.h>

#define MAX_FRAMES 24
#define MAX_STACKS 512

typedef struct {
  int kind;              // 0 malloc, 1 swift_retain, 2 swift_release
  int depth;
  void *frames[MAX_FRAMES];
  uint64_t count;
  uint64_t hash;
} stack_record;

static stack_record g_stacks[MAX_STACKS];
static int g_stack_count = 0;
static int g_mode = 0;              // bit 0: allocations, bit 1: ARC
static uint64_t g_total[3];
static __thread int g_in_hook = 0;

void cog_prof_mode(int mode) { g_mode = mode; }

void cog_prof_reset(void) {
  g_stack_count = 0;
  memset(g_stacks, 0, sizeof(g_stacks));
  memset(g_total, 0, sizeof(g_total));
}

static void record(int kind) {
  if (g_in_hook) return;
  g_in_hook = 1;
  void *frames[MAX_FRAMES + 2];
  int depth = backtrace(frames, MAX_FRAMES + 2);
  // Drop this frame and the interposed hook frame.
  int skip = 2;
  if (depth <= skip) { g_in_hook = 0; return; }
  depth -= skip;
  if (depth > MAX_FRAMES) depth = MAX_FRAMES;
  uint64_t hash = 1469598103934665603ULL ^ (uint64_t)kind;
  for (int i = 0; i < depth; i++) {
    hash ^= (uint64_t)(uintptr_t)frames[i + skip];
    hash *= 1099511628211ULL;
  }
  g_total[kind]++;
  for (int i = 0; i < g_stack_count; i++) {
    if (g_stacks[i].hash == hash) { g_stacks[i].count++; g_in_hook = 0; return; }
  }
  if (g_stack_count < MAX_STACKS) {
    stack_record *r = &g_stacks[g_stack_count++];
    r->kind = kind;
    r->depth = depth;
    r->hash = hash;
    r->count = 1;
    memcpy(r->frames, frames + skip, (size_t)depth * sizeof(void *));
  }
  g_in_hook = 0;
}

void cog_prof_report(void) {
  int saved = g_mode;
  g_mode = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const struct mach_header *h = _dyld_get_image_header(i);
    if (h && h->filetype == MH_EXECUTE) {
      fprintf(stderr, "COGPROF image %s 0x%llx\n", _dyld_get_image_name(i), (unsigned long long)(uintptr_t)h);
      break;
    }
  }
  fprintf(stderr, "COGPROF totals malloc=%llu retain=%llu release=%llu stacks=%d\n",
          g_total[0], g_total[1], g_total[2], g_stack_count);
  for (int i = 0; i < g_stack_count; i++) {
    stack_record *r = &g_stacks[i];
    fprintf(stderr, "COGPROF stack kind=%d count=%llu\n", r->kind, r->count);
    char **syms = backtrace_symbols(r->frames, r->depth);
    for (int f = 0; f < r->depth; f++) {
      fprintf(stderr, "COGPROF   %s\n", syms ? syms[f] : "?");
    }
    if (syms) free(syms);
  }
  fflush(stderr);
  g_mode = saved;
}

// MARK: - malloc family

static void *hook_malloc(size_t size) {
  if (g_mode & 1) record(0);
  return malloc(size);
}
static void *hook_calloc(size_t n, size_t size) {
  if (g_mode & 1) record(0);
  return calloc(n, size);
}
static void *hook_realloc(void *p, size_t size) {
  if (g_mode & 1) record(0);
  return realloc(p, size);
}
static void *hook_malloc_zone_malloc(malloc_zone_t *zone, size_t size) {
  if (g_mode & 1) record(0);
  return malloc_zone_malloc(zone, size);
}
static void *hook_malloc_zone_calloc(malloc_zone_t *zone, size_t n, size_t size) {
  if (g_mode & 1) record(0);
  return malloc_zone_calloc(zone, n, size);
}

// MARK: - Swift ARC

extern void *swift_retain(void *);
extern void swift_release(void *);
extern void *swift_retain_n(void *, uint32_t);
extern void swift_release_n(void *, uint32_t);

static void *hook_swift_retain(void *o) {
  if (g_mode & 2) record(1);
  return swift_retain(o);
}
static void hook_swift_release(void *o) {
  if (g_mode & 2) record(2);
  swift_release(o);
}
static void *hook_swift_retain_n(void *o, uint32_t n) {
  if (g_mode & 2) record(1);
  return swift_retain_n(o, n);
}
static void hook_swift_release_n(void *o, uint32_t n) {
  if (g_mode & 2) record(2);
  swift_release_n(o, n);
}


extern void *swift_bridgeObjectRetain(void *);
extern void swift_bridgeObjectRelease(void *);
extern void *swift_bridgeObjectRetain_n(void *, uint32_t);
extern void swift_bridgeObjectRelease_n(void *, uint32_t);
extern void *swift_unknownObjectRetain(void *);
extern void swift_unknownObjectRelease(void *);
extern void *objc_retain(void *);
extern void objc_release(void *);

static void *hook_swift_bridgeObjectRetain(void *o) { if (g_mode & 2) record(1); return swift_bridgeObjectRetain(o); }
static void hook_swift_bridgeObjectRelease(void *o) { if (g_mode & 2) record(2); swift_bridgeObjectRelease(o); }
static void *hook_swift_bridgeObjectRetain_n(void *o, uint32_t n) { if (g_mode & 2) record(1); return swift_bridgeObjectRetain_n(o, n); }
static void hook_swift_bridgeObjectRelease_n(void *o, uint32_t n) { if (g_mode & 2) record(2); swift_bridgeObjectRelease_n(o, n); }
static void *hook_swift_unknownObjectRetain(void *o) { if (g_mode & 2) record(1); return swift_unknownObjectRetain(o); }
static void hook_swift_unknownObjectRelease(void *o) { if (g_mode & 2) record(2); swift_unknownObjectRelease(o); }
static void *hook_objc_retain(void *o) { if (g_mode & 2) record(1); return objc_retain(o); }
static void hook_objc_release(void *o) { if (g_mode & 2) record(2); objc_release(o); }

#define DYLD_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
  _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

DYLD_INTERPOSE(hook_malloc, malloc)
DYLD_INTERPOSE(hook_calloc, calloc)
DYLD_INTERPOSE(hook_realloc, realloc)
DYLD_INTERPOSE(hook_malloc_zone_malloc, malloc_zone_malloc)
DYLD_INTERPOSE(hook_malloc_zone_calloc, malloc_zone_calloc)
DYLD_INTERPOSE(hook_swift_retain, swift_retain)
DYLD_INTERPOSE(hook_swift_release, swift_release)
DYLD_INTERPOSE(hook_swift_retain_n, swift_retain_n)
DYLD_INTERPOSE(hook_swift_release_n, swift_release_n)

DYLD_INTERPOSE(hook_swift_bridgeObjectRetain, swift_bridgeObjectRetain)
DYLD_INTERPOSE(hook_swift_bridgeObjectRelease, swift_bridgeObjectRelease)
DYLD_INTERPOSE(hook_swift_bridgeObjectRetain_n, swift_bridgeObjectRetain_n)
DYLD_INTERPOSE(hook_swift_bridgeObjectRelease_n, swift_bridgeObjectRelease_n)
DYLD_INTERPOSE(hook_swift_unknownObjectRetain, swift_unknownObjectRetain)
DYLD_INTERPOSE(hook_swift_unknownObjectRelease, swift_unknownObjectRelease)
DYLD_INTERPOSE(hook_objc_retain, objc_retain)
DYLD_INTERPOSE(hook_objc_release, objc_release)
