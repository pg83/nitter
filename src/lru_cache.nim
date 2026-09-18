# SPDX-License-Identifier: AGPL-3.0-only
import std/[lists, monotimes, options, tables, times]

type
  CacheEntry = object
    key, value: string
    expires: bool
    expiresAt: MonoTime

  LruCache* = object
    ## A bounded cache for use within a single event loop.
    capacity: int
    entries: Table[string, DoublyLinkedNode[CacheEntry]]
    order: DoublyLinkedList[CacheEntry] # least recently used first

proc initLruCache*(maxEntries: int): LruCache =
  LruCache(capacity: max(0, maxEntries))

proc len*(cache: LruCache): int =
  cache.entries.len

proc remove(cache: var LruCache; node: DoublyLinkedNode[CacheEntry]) =
  cache.entries.del(node.value.key)
  cache.order.remove(node)
  node.next = nil
  node.prev = nil

proc touch(cache: var LruCache; node: DoublyLinkedNode[CacheEntry]) =
  cache.order.remove(node)
  cache.order.add(node)

proc get*(cache: var LruCache; key: string;
          now = getMonoTime()): Option[string] =
  let node = cache.entries.getOrDefault(key)
  if node.isNil:
    return none(string)
  if node.value.expires and now >= node.value.expiresAt:
    cache.remove(node)
    return none(string)
  cache.touch(node)
  some(node.value.value)

proc put*(cache: var LruCache; key, value: string; ttl = -1;
          now = getMonoTime()) =
  ## TTL is in seconds: negative means no expiry, zero removes the entry.
  ## Reads update recency without extending the TTL. Expiry is checked on read;
  ## all entries, including expired ones, count towards the capacity bound.
  let node = cache.entries.getOrDefault(key)
  if ttl == 0 or cache.capacity == 0:
    if not node.isNil:
      cache.remove(node)
    return

  let entry = CacheEntry(key: key, value: value, expires: ttl > 0,
                        expiresAt: now + initDuration(seconds = max(0, ttl)))
  if not node.isNil:
    node.value = entry
    cache.touch(node)
  else:
    if cache.entries.len >= cache.capacity:
      cache.remove(cache.order.head)
    let added = newDoublyLinkedNode(entry)
    cache.order.add(added)
    cache.entries[key] = added
