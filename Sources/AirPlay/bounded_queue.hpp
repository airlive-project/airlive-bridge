#pragma once
//
// Bounded thread-safe queue with drop-oldest semantics.
//
// Used between the UxPlay network thread (producer) and our decoder thread
// (consumer) so a slow decoder cannot back-pressure the network thread —
// that's the root cause of "growing latency" in obs-airplay/RPiPlay #265.
//
// On push, if the queue is full, the OLDEST item is dropped to make room.
// This guarantees we always show the freshest frame and never block the
// network reader. For video at ~30 fps with maxSize=2, the worst-case
// latency added by the queue is one frame interval (~33 ms).
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

  // Push. If queue is full, drops oldest entries until room exists.
  // Returns number of items dropped (for telemetry).
  auto push(T item) -> size_t
  {
    size_t dropped = 0;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (closed_)
        return 0;
      while (q_.size() >= maxSize_)
      {
        q_.pop();
        ++dropped;
      }
      q_.push(std::move(item));
    }
    cv_.notify_one();
    return dropped;
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

  // Drop everything queued (returns how many).  Used when a compressed-domain
  // drop already broke the H.264 reference chain: every frame still queued
  // decodes to garbage, so the producer purges and waits for the next sync point.
  auto clear() -> size_t
  {
    std::lock_guard<std::mutex> lk(mu_);
    size_t n = q_.size();
    while (!q_.empty())
      q_.pop();
    return n;
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
