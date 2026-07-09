#pragma once
//
// Bounded thread-safe queue between the UxPlay network thread (producer) and
// our decoder thread (consumer), so a slow decoder cannot back-pressure the
// network thread — the root cause of "growing latency" in obs-airplay/RPiPlay
// #265.
//
// Overflow policy is H.264-aware (`pushOrPurge`): compressed frames must NEVER
// be dropped from the MIDDLE of the stream (a dropped P-frame breaks the
// reference chain and the decoder paints smeared garbage until the next IDR).
// So on overflow the whole queue is purged in ONE critical section — and the
// incoming item is kept only when it is itself a sync point (SPS/IDR) that
// restarts the chain.  Single-lock matters: a separate push()-then-clear()
// pair let the consumer pop the just-pushed broken-chain frame in between.
//

#include <condition_variable>
#include <mutex>
#include <optional>
#include <queue>

template <typename T>
class BoundedQueue
{
public:
  explicit BoundedQueue(size_t maxSize) : maxSize_(maxSize) {}

  struct PushResult
  {
    size_t dropped = 0;        // items removed (telemetry)
    bool purgedNonSync = false; // purge happened and the item was NOT a sync point
                                // → caller must freeze decode until the next one
  };

  // Push with the H.264-aware overflow policy, in ONE critical section:
  //   • room available        → plain push;
  //   • overflow + sync item  → purge everything, push the sync (chain restarts
  //                             cleanly at it — zero garbage frames);
  //   • overflow + non-sync   → purge everything INCLUDING the item (its chain
  //                             is broken by the purge), report purgedNonSync.
  // A concurrent pop() can never observe a broken-chain frame: frames already
  // popped in order only reference BACKWARD (already decoded), and the queue is
  // never left holding a frame from after a gap.
  auto pushOrPurge(T item, bool itemIsSync) -> PushResult
  {
    PushResult r;
    bool pushed = false;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (closed_)
        return r;
      if (q_.size() >= maxSize_)
      {
        r.dropped = q_.size();
        while (!q_.empty())
          q_.pop();
        if (itemIsSync)
        {
          q_.push(std::move(item));
          pushed = true;
        }
        else
        {
          ++r.dropped;          // the incoming item goes too
          r.purgedNonSync = true;
        }
      }
      else
      {
        q_.push(std::move(item));
        pushed = true;
      }
    }
    if (pushed)
      cv_.notify_one();
    return r;
  }

  // Pop. Blocks until an item is available or queue is closed.
  // Returns nullopt if the queue was closed while empty.
  auto pop() -> std::optional<T>
  {
    std::unique_lock<std::mutex> lk(mu_);
    cv_.wait(lk, [this] { return !q_.empty() || closed_; });
    if (q_.empty())
      return std::nullopt;
    T item = std::move(q_.front());
    q_.pop();
    return item;
  }

  // Signal shutdown: subsequent pop() calls return nullopt once drained,
  // and pending pop()s waiting on the condvar wake up.
  auto close() -> void
  {
    {
      std::lock_guard<std::mutex> lk(mu_);
      closed_ = true;
    }
    cv_.notify_all();
  }

  auto size() const -> size_t
  {
    std::lock_guard<std::mutex> lk(mu_);
    return q_.size();
  }

private:
  size_t maxSize_;
  std::queue<T> q_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
  bool closed_ = false;
};
