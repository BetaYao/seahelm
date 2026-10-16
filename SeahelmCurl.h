// Typed shims over libcurl's variadic entry points, which Swift cannot call.
// One per argument type the client actually passes; see `CurlClient`.
#ifndef SeahelmCurl_h
#define SeahelmCurl_h

#include <curl/curl.h>

static inline CURLcode seahelm_curl_setopt_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode seahelm_curl_setopt_string(CURL *handle, CURLoption option, const char *value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode seahelm_curl_setopt_pointer(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode seahelm_curl_setopt_offset(CURL *handle, CURLoption option, curl_off_t value) {
    return curl_easy_setopt(handle, option, value);
}

static inline CURLcode seahelm_curl_setopt_headers(CURL *handle, struct curl_slist *headers) {
    return curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);
}

static inline CURLcode seahelm_curl_set_write(CURL *handle, curl_write_callback callback, void *context) {
    CURLcode code = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, callback);
    if (code != CURLE_OK) return code;
    return curl_easy_setopt(handle, CURLOPT_WRITEDATA, context);
}

static inline CURLcode seahelm_curl_set_progress(CURL *handle, curl_xferinfo_callback callback, void *context) {
    CURLcode code = curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, callback);
    if (code != CURLE_OK) return code;
    code = curl_easy_setopt(handle, CURLOPT_XFERINFODATA, context);
    if (code != CURLE_OK) return code;
    return curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L);
}

static inline long seahelm_curl_response_code(CURL *handle) {
    long status = 0;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
    return status;
}

/// How many new connections the last transfer on this handle opened: 0 means
/// it rode a connection kept from an earlier one.
static inline long seahelm_curl_connects(CURL *handle) {
    long count = 0;
    curl_easy_getinfo(handle, CURLINFO_NUM_CONNECTS, &count);
    return count;
}

#endif
