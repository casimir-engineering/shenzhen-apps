# miniupnpc (vendored for Shenzhen Friends)

UPnP IGD client, used by Friends' router port mapping as the last step after PCP and NAT-PMP (ADR 0011
§ Port mapping, lead decision 7). Upstream: <http://miniupnp.free.fr/> and <https://github.com/miniupnp/miniupnp>.

## Source

- Version: 2.3.3 (`VERSION`; API version 21).
- Archive: <http://miniupnp.free.fr/files/miniupnpc-2.3.3.tar.gz>
- SHA-256: `d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a` (downloaded 2026-10-14; the pin
  ADR 0011 and the NAT spike recorded). The spike also verified the archive's detached signature (`.sig` beside it)
  with key DB511043A31ACAAF, "miniupnp <miniupnp@free.fr>".
- Licence: BSD-3-Clause (`LICENSE`). The helper links this library, so its text is in
  `portable/friends/ACKNOWLEDGEMENTS.txt` and the helper bundle's `Licenses/miniupnpc.txt` (`FRIENDS_HELPER_LICENSES`
  in `helper.mk`; `MAC_FRIENDS_LICENSES` in `portable/Makefile` checks the acknowledgements against it).

## What is here

- `include/`, `src/`: the archive's directories, unmodified apart from the one local change below. Only the library
  sources are built (below); the test, example, Python-module and test-server sources in `src/` are kept so a diff
  against upstream shows that change and nothing else.
- `testdesc/`, `testreplyparse/`: upstream's sample descriptions and SOAP answers, seeds of the fuzz corpus.
- `miniupnpcstrings.h.in`, `VERSION`, `LICENSE`, `README`, `Changelog.txt`.
- `szfriends/`: ours, not upstream's. `szfriends_test_miniwget.c` is the local change's regression test.
- `.gitattributes`: ours. The diff below indents upstream's tab-indented lines with a space, which `git diff --check`
  would otherwise report as a whitespace error.

Left out: `CMakeLists.txt`, `Makefile`, `Makefile.mingw`, `mingw32make.bat`, `msvc/`, `java/`, `man3/`, `Doxyfile`,
`DESCRIPTION`, `MANIFEST.in`, `apiversions.txt`, `miniupnpc.def`, `miniupnpc.rc`, `miniupnpc.pc.in`,
`miniupnpc-config.cmake`, `miniupnpcstrings.h.cmake`, `setup.py`, `setupmingw32.py`, `pymoduletest.py`,
`external-ip.sh`, `testminiwget.sh`, `testupnpigd.py`, `testupnpreplyparse.sh`, `updateminiupnpcstrings.sh` and
`wingenminiupnpcstrings.c`.

## Local changes

One, to `getHTTPResponse` in `src/miniwget.c`, which reads every description and SOAP answer from the router. It
fixes the two fuzz findings in `portable/friends/service/online/nat/fuzz/findings/README.md` (a heap over-read, and
an allocation as large as the peer announces) and bounds the rest of what a device on the LAN can make it read:

- Header names match exactly (`Content-Length`, `Transfer-Encoding`, any case), not by prefix, so `Cont:` is not a
  Content-Length.
- The Content-Length value is parsed within its line (`parseContentLength`), never with `atoi` on a buffer that has
  no NUL. An empty or non-numeric value counts as no Content-Length, as `atoi`'s 0 or a negative number did.
  The one `atoi` left, on the status code, starts on a digit and stops at the status line's CR or LF, inside the
  buffer.
- At most 16 KiB of headers (`MINIUPNPC_HTTP_MAX_HEADERS`) and 64 KiB of content (`MINIUPNPC_HTTP_MAX_CONTENT`),
  whether the length is announced, chunked or read until the server closes. Beyond either, the answer is refused as
  an allocation failure is: NULL, with size -1, which every caller already handles. IGD descriptions and SOAP answers
  are a few KiB; upstream's own HTTP test server sends 16 KiB.

`friends-miniupnpc-check` (`portable/friends/friends.mk`) runs `szfriends/szfriends_test_miniwget.c` under
AddressSanitizer and UndefinedBehaviorSanitizer; it crashes or fails on an unpatched copy. Upstream's `testminiwget`
against `minihttptestserver` (plain, chunked, trailing junk, malformed) gives the same results with and without the
patch. To report upstream (not yet done): <https://github.com/miniupnp/miniupnp/issues>. Drop the change once an
upstream release fixes both findings and the regression test passes on it unmodified.

```diff
--- a/src/miniwget.c
+++ b/src/miniwget.c
@@ -49,7 +49,17 @@
 #define MIN(x,y) (((x)<(y))?(x):(y))
 #endif /* MIN */

+/* Shenzhen Friends local change (ext/miniupnpc/VENDORED.md): bounds on what
+ * getHTTPResponse reads. Device descriptions and SOAP answers are a few KiB,
+ * so an answer beyond these is refused rather than read into memory. */
+#ifndef MINIUPNPC_HTTP_MAX_HEADERS
+#define MINIUPNPC_HTTP_MAX_HEADERS 16384
+#endif
+#ifndef MINIUPNPC_HTTP_MAX_CONTENT
+#define MINIUPNPC_HTTP_MAX_CONTENT 65536
+#endif

+
 #include "miniupnpcstrings.h"
 #include "miniwget.h"
 #include "connecthostport.h"
@@ -59,6 +69,24 @@
 #define MAXHOSTNAMELEN 64
 #endif

+/* Content-Length value between p and end (not NUL-terminated, so no atoi):
+ * -1 when empty or not a number (no Content-Length),
+ * -2 when above MINIUPNPC_HTTP_MAX_CONTENT. */
+static int
+parseContentLength(const char * p, const char * end)
+{
+	int n = 0;
+	if(p >= end || *p < '0' || *p > '9')
+		return -1;
+	while(p < end && *p >= '0' && *p <= '9') {
+		n = n * 10 + (*p - '0');
+		if(n > MINIUPNPC_HTTP_MAX_CONTENT)
+			return -2;
+		p++;
+	}
+	return n;
+}
+
 /*
  * Read a HTTP response from a socket.
  * Process Content-Length and Transfer-encoding headers.
@@ -157,8 +185,13 @@
 				}
 				i++;
 			}
-			if(endofheaders == 0)
+			if(endofheaders == 0) {
+				if(header_buf_used > MINIUPNPC_HTTP_MAX_HEADERS)
+					goto refused;
 				continue;
+			}
+			if(endofheaders > MINIUPNPC_HTTP_MAX_HEADERS)
+				goto refused;
 			/* parse header lines */
 			for(i = 0; i < endofheaders - 1; i++) {
 				if(linestart > 0 && colon <= linestart && header_buf[i]==':')
@@ -206,14 +239,18 @@
 						       colon-linestart, header_buf+linestart,
 						       i-valuestart, header_buf+valuestart);
 #endif
-						if(0==strncasecmp(header_buf+linestart, "content-length", colon-linestart))
+						if(colon-linestart == 14
+						   && 0==strncasecmp(header_buf+linestart, "content-length", 14))
 						{
-							content_length = atoi(header_buf+valuestart);
+							content_length = parseContentLength(header_buf+valuestart, header_buf+i);
+							if(content_length == -2)
+								goto refused;
 #ifdef DEBUG
 							printf("Content-Length: %d\n", content_length);
 #endif
 						}
-						else if(0==strncasecmp(header_buf+linestart, "transfer-encoding", colon-linestart)
+						else if(colon-linestart == 17
+						   && 0==strncasecmp(header_buf+linestart, "transfer-encoding", 17)
 						   && 0==strncasecmp(header_buf+valuestart, "chunked", 7))
 						{
 #ifdef DEBUG
@@ -290,6 +327,8 @@
 				}
 				/* it is guaranteed that (n >= i) */
 				bytestocopy = (chunksize < (unsigned int)(n - i))?chunksize:(unsigned int)(n - i);
+				if(content_buf_used + bytestocopy > MINIUPNPC_HTTP_MAX_CONTENT)
+					goto refused;
 				if((content_buf_used + bytestocopy) > content_buf_len)
 				{
 					char * tmp;
@@ -322,6 +361,8 @@
 				/* skipping additional bytes */
 				n = content_length - content_buf_used;
 			}
+			if(content_buf_used + n > MINIUPNPC_HTTP_MAX_CONTENT)
+				goto refused;
 			if(content_buf_used + n > content_buf_len)
 			{
 				char * tmp;
@@ -362,6 +403,11 @@
 		content_buf = NULL;
 	}
 	return content_buf;
+refused:
+	free(header_buf);
+	free(content_buf);
+	*size = -1;
+	return NULL;
 }

 /* miniwget3() :
```

## How it is built

`portable/friends/service/online/nat/nat.mk` compiles upstream's library sources (its Makefile's `LIBOBJS`:
`addr_is_reserved connecthostport igd_desc_parse minisoap minissdpc miniupnpc miniwget minixml portlistingparse
receivedata upnpcommands upnpdev upnperrors upnpreplyparse`) with upstream's macros for a BSD-like system
(`MINIUPNPC_SET_SOCKET_TIMEOUT`, `MINIUPNPC_GET_SRC_ADDR`, `_BSD_SOURCE`, `_DEFAULT_SOURCE`, `_XOPEN_SOURCE=600`,
`_DARWIN_C_SOURCE`) into `$(BUILD)/friends/online/nat/libminiupnpc.a`, made with `libtool -static -D`.
`miniupnpcstrings.h`, which upstream's Makefile generates, is written into the build tree from
`miniupnpcstrings.h.in` with the OS string "Darwin" (no version, so the User-Agent sent to the router says no more)
and the version from `VERSION`.

## Fuzzing

miniupnpc parses SSDP answers, device descriptions, SOAP answers and HTTP from any device on the LAN before anyone
is authenticated, and has had memory-safety bugs (CVE-2017-8798 among them). `friends-nat-check` replays the fuzz
corpus (`portable/friends/service/online/nat/fuzz/corpus/`) through the `ssdp`, `desc`, `soap` and `http` targets under
AddressSanitizer and UndefinedBehaviorSanitizer; `friends-nat-fuzz` runs them with libFuzzer (`fuzz/fuzz.mk`). Run it
again after every upgrade.

Open findings: none. The two that 2.3.3 had, both in `getHTTPResponse`, are fixed by the local change above; their
inputs are in the replayed `http` corpus (`finding-content-length-*.bin`).

## Verifying this copy

```sh
d=$(mktemp -d) && cd "$d"
curl -fsSL -o miniupnpc.tar.gz http://miniupnp.free.fr/files/miniupnpc-2.3.3.tar.gz
echo "d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a  miniupnpc.tar.gz" | shasum -a 256 -c
mkdir x && tar -xzf miniupnpc.tar.gz -C x --strip-components 1
E=<repository>/ext/miniupnpc
sed -n '/^```diff$/,/^```$/p' "$E/VENDORED.md" | sed '1d;$d' | patch -d x -p1 --no-backup-if-mismatch || exit 1
for p in include src testdesc testreplyparse; do diff -r "x/$p" "$E/$p" || exit 1; done
for f in LICENSE README Changelog.txt VERSION miniupnpcstrings.h.in; do cmp "x/$f" "$E/$f" || exit 1; done
echo identical
```

## Upgrading

Update promptly when upstream fixes a parsing bug. Replace the directories and files above from the new archive
(keep `szfriends/`), pin its SHA-256 here and in ADR 0011, and reapply the local change unless the new release fixes
both findings (then delete § Local changes and its diff). Check that `LIBOBJS` in upstream's Makefile still matches
`nat.mk`, then run `friends-miniupnpc-check`, `friends-nat-check` and at least ten minutes of `friends-nat-fuzz`.
