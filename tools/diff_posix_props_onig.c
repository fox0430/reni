/* List every code point matched by an Oniguruma pattern (UTF-8).
 *
 * Usage: diff_posix_props_onig '<pattern>'
 * Prints one uppercase hex code point per line (6 digits), skips surrogates.
 * Build: cc -O2 tools/diff_posix_props_onig.c $(onig-config --cflags --libs) \
 *          -o tools/diff_posix_props_onig
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <oniguruma.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <pattern>\n", argv[0]);
    return 2;
  }
  const char *pat = argv[1];
  regex_t *reg;
  OnigErrorInfo einfo;
  int rc = onig_new(
      &reg, (const UChar *)pat, (const UChar *)pat + strlen(pat), ONIG_OPTION_NONE,
      ONIG_ENCODING_UTF8, ONIG_SYNTAX_ONIGURUMA, &einfo);
  if (rc != ONIG_NORMAL) {
    char buf[ONIG_MAX_ERROR_MESSAGE_LEN];
    onig_error_code_to_str((UChar *)buf, rc, &einfo);
    fprintf(stderr, "onig compile failed: %s\n", buf);
    return 1;
  }

  OnigRegion *region = onig_region_new();
  for (unsigned cp = 0; cp <= 0x10FFFFu; cp++) {
    if (cp >= 0xD800u && cp <= 0xDFFFu)
      continue;
    UChar buf[6];
    int n = ONIGENC_CODE_TO_MBC(ONIG_ENCODING_UTF8, (OnigCodePoint)cp, buf);
    if (n <= 0)
      continue;
    rc = onig_search(reg, buf, buf + n, buf, buf + n, region, ONIG_OPTION_NONE);
    if (rc >= 0)
      printf("%06X\n", cp);
  }
  onig_region_free(region, 1);
  onig_free(reg);
  onig_end();
  return 0;
}
