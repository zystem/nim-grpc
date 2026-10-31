/*
 * gzip for gRPC message compression, on zlib.
 *
 * Decompression is bounded: it stops as soon as the output would exceed the
 * caller's limit, so a small compressed message cannot expand into gigabytes.
 */
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define GGZ_OK 0
#define GGZ_ERROR -1       /* corrupt or not gzip */
#define GGZ_TOO_BIG -2     /* the output would exceed the limit */
#define GGZ_NOMEM -3

/* gzip-compresses `in`. On success *out is malloc'ed (free with ggz_free). */
int ggz_compress(const unsigned char *in, size_t len, int level,
                 unsigned char **out, size_t *outlen) {
    z_stream s;
    memset(&s, 0, sizeof s);
    /* 15 + 16: a gzip wrapper, 32 KiB window */
    if (deflateInit2(&s, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        return GGZ_NOMEM;
    uLong bound = deflateBound(&s, (uLong)len);
    unsigned char *buf = malloc(bound ? bound : 1);
    if (!buf) { deflateEnd(&s); return GGZ_NOMEM; }
    s.next_in = (Bytef *)in;
    s.avail_in = (uInt)len;
    s.next_out = buf;
    s.avail_out = (uInt)bound;
    int rc = deflate(&s, Z_FINISH);
    deflateEnd(&s);
    if (rc != Z_STREAM_END) { free(buf); return GGZ_ERROR; }
    *out = buf;
    *outlen = s.total_out;
    return GGZ_OK;
}

/* Inflates gzip data `in` into at most `max` bytes. */
int ggz_decompress(const unsigned char *in, size_t len, size_t max,
                   unsigned char **out, size_t *outlen) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (inflateInit2(&s, 15 + 16) != Z_OK) return GGZ_NOMEM;
    size_t cap = len * 4 + 64;
    if (cap > max + 1) cap = max + 1;     /* one byte more detects overflow */
    unsigned char *buf = malloc(cap ? cap : 1);
    if (!buf) { inflateEnd(&s); return GGZ_NOMEM; }
    s.next_in = (Bytef *)in;
    s.avail_in = (uInt)len;
    int rc;
    for (;;) {
        s.next_out = buf + s.total_out;
        s.avail_out = (uInt)(cap - s.total_out);
        rc = inflate(&s, Z_NO_FLUSH);
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK && rc != Z_BUF_ERROR) { rc = GGZ_ERROR; goto fail; }
        if (s.total_out > max) { rc = GGZ_TOO_BIG; goto fail; }
        if (s.avail_out == 0) {
            if (cap > max) { rc = GGZ_TOO_BIG; goto fail; }
            size_t ncap = cap * 2;
            if (ncap > max + 1) ncap = max + 1;
            unsigned char *nb = realloc(buf, ncap);
            if (!nb) { rc = GGZ_NOMEM; goto fail; }
            buf = nb;
            cap = ncap;
        } else if (s.avail_in == 0) {
            rc = GGZ_ERROR;      /* input ended before the gzip stream did */
            goto fail;
        }
    }
    if (s.total_out > max) { rc = GGZ_TOO_BIG; goto fail; }
    /* Trailing bytes after the gzip member are not allowed. */
    if (s.avail_in != 0) { rc = GGZ_ERROR; goto fail; }
    inflateEnd(&s);
    *out = buf;
    *outlen = s.total_out;
    return GGZ_OK;
fail:
    inflateEnd(&s);
    free(buf);
    return rc;
}

void ggz_free(void *p) { free(p); }
