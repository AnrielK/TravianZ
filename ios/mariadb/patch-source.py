#!/usr/bin/env python3
"""Source patches applied to the MariaDB tree before building for iOS (and for a Linux test build).

1. libmariadb (Connector/C) is configured with CONC_WITH_SSL=NONE – the server binary does not use it,
   and there is no GnuTLS/OpenSSL on iOS.
2. No readline/curses detection on iOS (only the command line client needs it; it is not built).
3. macOS-only APIs missing from the iOS SDK (libproc, net/route.h): the __APPLE__ branches of these files
   are disabled when MY_IOS is defined (the build passes -DMY_IOS), falling back to the generic code.
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1])

p = root / "libmariadb" / "CMakeLists.txt"
s = p.read_text()
marker = 'ELSE()\n  MESSAGE(FATAL_ERROR "Invalid TLS/SSL option \'${WITH_SSL}\'")'
if 'WITH_SSL STREQUAL "NONE"' not in s:
    assert marker in s, "libmariadb TLS selection changed"
    s = s.replace(marker, 'ELSEIF(WITH_SSL STREQUAL "NONE")\n  MESSAGE1(TLS_LIBRARY_VERSION "TLS disabled")\n' + marker, 1)
    p.write_text(s)
p = root / "CMakeLists.txt"
s = p.read_text()
if 'NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")\n  MYSQL_CHECK_READLINE()' not in s:
    assert "\nMYSQL_CHECK_READLINE()\n" in s, "readline check moved"
    s = s.replace("\nMYSQL_CHECK_READLINE()\n", '\nIF(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")\n  MYSQL_CHECK_READLINE()\nENDIF()\n', 1)
    p.write_text(s)

for rel in ("mysys/my_getexe.c", "mysys/my_gethwaddr.c"):
    p = root / rel
    s = p.read_text()
    if "MY_IOS" not in s:
        assert "defined(__APPLE__)" in s, rel
        s = s.replace("defined(__APPLE__)", "(defined(__APPLE__) && !defined(MY_IOS))")
        p.write_text(s)

print("patched", root)
