# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, asyncnet, httpclient, net, options, strutils, times, uri]

type KvCache* = ref object
  endpoint, bucket, prefix: string
  enabled: bool
  timeoutMs: int
  idle: seq[AsyncHttpClient]
  lastWarning: float
  sslContext: SslContext

proc initKvCache*(endpoint, bucket: string; prefix = "nitter:v1:";
                  timeoutMs = 1000; enabled = true): KvCache =
  let address = parseUri(endpoint)
  if address.scheme notin ["http", "https"] or address.hostname.len == 0 or
      address.username.len > 0 or address.password.len > 0 or
      address.query.len > 0 or address.anchor.len > 0 or address.path notin ["", "/"]:
    raise newException(ValueError, "kvEndpoint must be an HTTP(S) origin")
  if bucket.len == 0 or bucket.contains({'/', '?', '#'}):
    raise newException(ValueError, "kvBucket must be a nonempty bucket name")
  if timeoutMs <= 0:
    raise newException(ValueError, "kvTimeoutMs must be positive")
  KvCache(endpoint: endpoint.strip(trailing=true, leading=false, chars={'/'}),
          bucket: encodeUrl(bucket, usePlus=false), prefix: prefix,
          timeoutMs: timeoutMs, enabled: enabled)

proc closeClient(client: AsyncHttpClient) =
  # Also close a socket whose connection is still being established.
  let socket = client.getSocket()
  if socket != nil and not socket.isClosed:
    socket.close()
  client.close()

proc close*(cache: KvCache) =
  if cache != nil:
    for client in cache.idle:
      closeClient(client)
    cache.idle.setLen(0)

proc warn(cache: KvCache) =
  let now = epochTime()
  if now - cache.lastWarning >= 60:
    stderr.writeLine "[cache] KV request failed; continuing without cached data"
    cache.lastWarning = now

proc exchange(client: AsyncHttpClient; url: string; verb: HttpMethod;
              body: string): Future[tuple[code: HttpCode, body: string]] {.async.} =
  let response = await client.request(url, httpMethod=verb, body=body)
  return (response.code, await response.body)

proc request(cache: KvCache; key: string; verb: HttpMethod;
             body = ""): Future[Option[string]] {.async.} =
  if not cache.enabled: return none(string)
  let
    operation = if verb == HttpGet: "get" else: "put"
    url = cache.endpoint & "/v1/" & cache.bucket & "/" & operation &
          "?key=" & encodeUrl(cache.prefix & key, usePlus=false)
  var client: AsyncHttpClient
  var reusable = false
  try:
    if cache.endpoint.startsWith("https:") and cache.sslContext == nil:
      cache.sslContext = newContext(verifyMode=CVerifyPeer)
    client = if cache.idle.len > 0: cache.idle.pop()
             else: newAsyncHttpClient(userAgent="nitter-kv", maxRedirects=0,
                       sslContext=cache.sslContext,
                       headers=newHttpHeaders({"Content-Type": "application/octet-stream"}))
    let pending = exchange(client, url, verb, body)
    if not await withTimeout(pending, cache.timeoutMs):
      cache.warn()
      return none(string)
    let response = pending.read()
    if verb == HttpGet and response.code == Http404:
      reusable = true
      return none(string)
    if response.code != (if verb == HttpGet: Http200 else: Http204):
      cache.warn()
      return none(string)
    reusable = true
    return some(response.body)
  except CatchableError:
    cache.warn()
    return none(string)
  finally:
    if reusable and cache.idle.len < 16:
      cache.idle.add client
    elif client != nil:
      closeClient(client)

proc put*(cache: KvCache; key, value: string; ttl = -1;
          now = getTime().toUnix()): Future[void] {.async.} =
  # KV stores opaque bytes. Absolute Unix expiry allows all Nitter processes
  # to share the same TTL; zero skips caching, negative means no expiry.
  if ttl == 0: return
  let expires = if ttl < 0: -1'i64 else: now + ttl.int64
  discard await cache.request(key, HttpPut, "NK1\n" & $expires & "\n" & value)

proc get*(cache: KvCache; key: string;
          now = getTime().toUnix()): Future[Option[string]] {.async.} =
  let response = await cache.request(key, HttpGet)
  if response.isNone: return none(string)
  let data = response.get
  if not data.startsWith("NK1\n"): return none(string)
  let separator = data.find('\n', 4)
  if separator < 0: return none(string)
  try:
    let expires = parseBiggestInt(data[4 ..< separator])
    if expires < -1 or (expires >= 0 and now >= expires):
      return none(string)
  except ValueError:
    return none(string)
  return some(data[separator + 1 .. ^1])
