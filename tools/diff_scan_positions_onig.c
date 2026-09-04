/* Oniguruma side of tools/run_diff_scan_positions.sh.
 *
 * Emits one line per subject for a single pattern:
 *
 *     <subject hex> f=<beg>-<end> b=<beg>-<end>
 *
 * where `f` is a forward onig_search over the whole subject and `b` is a
 * backward one (start at the end, range at the start).  A no-match prints `-`.
 *
 * The subjects are every concatenation of 1..maxlen alphabet tokens, in
 * odometer order.  The alphabet is a comma-separated list of hex tokens, one
 * or more bytes each, so a sweep can be built from whole characters
 * ("0A,61,C3A9") or from raw bytes ("0A,61,C0").  Keep it small: the corpus
 * is |alphabet|^1 + ... + |alphabet|^maxlen subjects.
 *
 * Usage: diff_scan_positions_onig <maxlen> <alphabet> <pattern>
 */
#include <oniguruma.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MaxLen 8
#define MaxTokens 64
#define MaxTokenLen 8

static regex_t *rx;
static unsigned char tokens[MaxTokens][MaxTokenLen];
static int tokenLens[MaxTokens];
static int tokenCount;
static unsigned char subject[MaxLen * MaxTokenLen];

static void emit(int len)
{
  OnigRegion *region = onig_region_new();
  const UChar *s = subject;
  int i, r;

  for (i = 0; i < len; i++)
    printf("%02X", subject[i]);

  r = onig_search(rx, s, s + len, s, s + len, region, ONIG_OPTION_NONE);
  if (r >= 0)
    printf(" f=%d-%d", region->beg[0], region->end[0]);
  else
    printf(" f=-");
  onig_region_clear(region);

  r = onig_search(rx, s, s + len, s + len, s, region, ONIG_OPTION_NONE);
  if (r >= 0)
    printf(" b=%d-%d\n", region->beg[0], region->end[0]);
  else
    printf(" b=-\n");

  onig_region_free(region, 1);
}

static void sweep(int remaining, int len)
{
  int i;

  if (remaining == 0) {
    emit(len);
    return;
  }
  for (i = 0; i < tokenCount; i++) {
    memcpy(subject + len, tokens[i], (size_t)tokenLens[i]);
    sweep(remaining - 1, len + tokenLens[i]);
  }
}

/* Parse "0A,61,C3A9" into `tokens`.  Returns 0 on a malformed spec. */
static int parseAlphabet(const char *spec)
{
  const char *p = spec;

  while (*p) {
    const char *end = strchr(p, ',');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    size_t i;

    if (n == 0 || n % 2 != 0 || n / 2 > MaxTokenLen || tokenCount >= MaxTokens)
      return 0;
    for (i = 0; i < n / 2; i++) {
      unsigned int b;
      if (sscanf(p + i * 2, "%2x", &b) != 1)
        return 0;
      tokens[tokenCount][i] = (unsigned char)b;
    }
    tokenLens[tokenCount] = (int)(n / 2);
    tokenCount++;
    if (!end)
      break;
    p = end + 1;
  }
  return tokenCount > 0;
}

int main(int argc, char **argv)
{
  OnigEncoding encodings[] = {ONIG_ENCODING_UTF8};
  OnigErrorInfo einfo;
  const char *pattern;
  int maxlen, i;

  if (argc != 4) {
    fprintf(stderr, "usage: %s <maxlen> <alphabet> <pattern>\n", argv[0]);
    return 2;
  }
  maxlen = atoi(argv[1]);
  pattern = argv[3];

  if (maxlen < 1 || maxlen > MaxLen) {
    fprintf(stderr, "maxlen must be 1..%d\n", MaxLen);
    return 2;
  }
  if (!parseAlphabet(argv[2])) {
    fprintf(stderr, "alphabet must be comma-separated hex tokens, e.g. 0A,61,C3A9\n");
    return 2;
  }

  onig_initialize(encodings, 1);
  if (onig_new(&rx, (const UChar *)pattern, (const UChar *)pattern + strlen(pattern),
               ONIG_OPTION_NONE, ONIG_ENCODING_UTF8, ONIG_SYNTAX_ONIGURUMA,
               &einfo) != ONIG_NORMAL) {
    fprintf(stderr, "onig rejects the pattern\n");
    return 1;
  }
  for (i = 1; i <= maxlen; i++)
    sweep(i, 0);
  return 0;
}
