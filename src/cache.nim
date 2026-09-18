# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, times, strutils, options
import flatty, supersnappy

import types, api, lru_cache

const baseCacheTime = 60 * 60

var
  store: LruCache
  rssCacheTime: int
  listCacheTime: int

# Keep serialized snapshots so callers can modify returned objects without
# changing the cached value. Compression also keeps large RSS feeds compact.
proc toFlatty*(s: var string, x: DateTime) =
  s.toFlatty(x.toTime().toUnix())

proc fromFlatty*(s: string, i: var int, x: var DateTime) =
  var unix: int64
  s.fromFlatty(i, unix)
  x = fromUnix(unix).utc()

proc initCache*(cfg: Config) =
  store = initLruCache(cfg.cacheMaxEntries)
  rssCacheTime = max(0, cfg.rssCacheTime) * 60
  listCacheTime = max(0, cfg.listCacheTime) * 60

proc set[T](key: string; ttl: int; data: T) =
  store.put(key, compress(toFlatty(data)), ttl)

template deserialize(data, T) =
  result = fromFlatty(uncompress(data.get), T)

proc cacheUserId(username, id: string) =
  if username.len == 0 or id.len == 0: return
  store.put("pid:" & toLower(username), id)

proc cache*(data: List) {.async.} =
  set("l:" & data.id, listCacheTime, data)

proc cache*(data: PhotoRail; name: string) {.async.} =
  set("pr2:" & toLower(name), baseCacheTime * 2, data)

proc cache*(data: User) {.async.} =
  if data.username.len == 0: return
  cacheUserId(data.username, data.id)
  set("p:" & toLower(data.username), baseCacheTime, data)

proc cacheRss*(query: string; rss: Rss) {.async.} =
  let data = Rss(cursor: rss.cursor,
                 feed: if rss.cursor == "suspended": "" else: rss.feed)
  set("rss:" & query, rssCacheTime, data)

proc getUserId*(username: string): Future[string] {.async.} =
  let id = store.get("pid:" & toLower(username))
  if id.isSome:
    return id.get
  let user = await getGraphUser(username)
  if user.suspended:
    return "suspended"
  cacheUserId(username, user.id)
  await cache(user)
  return user.id

proc getCachedUser*(username: string; fetch=true): Future[User] {.async.} =
  let prof = store.get("p:" & toLower(username))
  if prof.isSome:
    prof.deserialize(User)
  elif fetch:
    result = await getGraphUser(username)
    await cache(result)

proc getCachedUsername*(userId: string): Future[string] {.async.} =
  let
    key = "i:" & userId
    username = store.get(key)

  if username.isSome:
    result = username.get
  else:
    let user = await getGraphUserById(userId)
    result = user.username
    if result.len > 0:
      store.put(key, result, baseCacheTime)
      if user.id.len > 0:
        await cache(user)

proc cache*(data: Broadcast) {.async.} =
  if data.id.len == 0: return
  set("bc:" & data.id, baseCacheTime, data)

proc getCachedBroadcast*(id: string): Future[Broadcast] {.async.} =
  if id.len == 0: return
  let cached = store.get("bc:" & id)
  if cached.isSome:
    cached.deserialize(Broadcast)
  else:
    result = await getBroadcastInfo(id)
    await cache(result)
  result.m3u8Url = await fetchBroadcastStream(result.mediaKey)

proc cache*(data: AudioSpace) {.async.} =
  if data.id.len == 0: return
  let ttl = if data.state == "RUNNING": baseCacheTime div 6 else: baseCacheTime
  set("sp:" & data.id, ttl, data)

proc getCachedAudioSpace*(id: string): Future[AudioSpace] {.async.} =
  if id.len == 0: return
  let cached = store.get("sp:" & id)
  if cached.isSome:
    cached.deserialize(AudioSpace)
  else:
    result = await getAudioSpace(id)
    await cache(result)
  result.m3u8Url = await fetchBroadcastStream(result.mediaKey)

proc cache*(data: AccountInfo; name: string) {.async.} =
  set("ai:" & toLower(name), baseCacheTime * 24, data)

proc getCachedAccountInfo*(username: string; fetch=true): Future[AccountInfo] {.async.} =
  if username.len == 0: return
  let cached = store.get("ai:" & toLower(username))
  if cached.isSome:
    cached.deserialize(AccountInfo)
  elif fetch:
    result = await getAboutAccount(username)
    await cache(result, toLower(username))

proc getCachedPhotoRail*(id: string): Future[PhotoRail] {.async.} =
  if id.len == 0: return
  let rail = store.get("pr2:" & toLower(id))
  if rail.isSome:
    rail.deserialize(PhotoRail)
  else:
    result = await getPhotoRail(id)
    await cache(result, id)

proc cache*(data: Community) {.async.} =
  if data.id.len == 0: return
  set("cm:" & data.id, listCacheTime, data)

proc getCachedCommunity*(id: string): Future[Community] {.async.} =
  if id.len == 0: return
  let cached = store.get("cm:" & id)
  if cached.isSome:
    cached.deserialize(Community)
  else:
    result = await getGraphCommunity(id)
    await cache(result)

proc getCachedCommunityModerators*(id: string): Future[seq[User]] {.async.} =
  if id.len == 0: return
  let cached = store.get("cmm:" & id)
  if cached.isSome:
    cached.deserialize(seq[User])
  else:
    let mods = await getGraphCommunityModerators(id)
    result = mods.content
    set("cmm:" & id, listCacheTime, result)

proc getCachedList*(username=""; slug=""; id=""): Future[List] {.async.} =
  let list = if id.len == 0: none(string)
             else: store.get("l:" & id)

  if list.isSome:
    list.deserialize(List)
  else:
    if id.len > 0:
      result = await getGraphList(id)
    else:
      result = await getGraphListBySlug(username, slug)
    await cache(result)

proc getCachedRss*(key: string): Future[Rss] {.async.} =
  let rss = store.get("rss:" & key)
  if rss.isSome:
    rss.deserialize(Rss)
    if result.cursor.len <= 2:
      result = Rss()
