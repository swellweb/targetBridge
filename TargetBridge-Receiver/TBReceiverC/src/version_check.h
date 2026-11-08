/* version_check.h — compares TargetBridge app versions ("4.0", "3.7.0-rc1").
 * Pure C, unit tested. */

#ifndef TB_VERSION_CHECK_H
#define TB_VERSION_CHECK_H

/* Compares the numeric parts of two versions ("3.7.0-rc1" counts as 3.7.0;
 * missing parts count as 0). NULL or empty sorts before any version.
 * Returns -1 if a < b, 0 if equal, 1 if a > b. */
int tb_version_compare(const char *a, const char *b);

#endif
