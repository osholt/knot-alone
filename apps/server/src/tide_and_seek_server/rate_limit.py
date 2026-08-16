from __future__ import annotations

import threading
import time
from collections import deque


class SlidingWindowRateLimiter:
    def __init__(
        self,
        *,
        maximum_requests: int,
        window_seconds: int,
        maximum_keys: int = 100_000,
    ) -> None:
        self._maximum_requests = maximum_requests
        self._window_seconds = window_seconds
        self._maximum_keys = maximum_keys
        self._requests: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str) -> int | None:
        now = time.monotonic()
        threshold = now - self._window_seconds
        with self._lock:
            timestamps = self._requests.get(key)
            if timestamps is None:
                if len(self._requests) >= self._maximum_keys:
                    self._requests = {
                        existing_key: values
                        for existing_key, values in self._requests.items()
                        if values and values[-1] > threshold
                    }
                if len(self._requests) >= self._maximum_keys:
                    return self._window_seconds
                timestamps = deque()
                self._requests[key] = timestamps
            while timestamps and timestamps[0] <= threshold:
                timestamps.popleft()
            if len(timestamps) >= self._maximum_requests:
                retry_after = max(1, int(timestamps[0] + self._window_seconds - now) + 1)
                return retry_after
            timestamps.append(now)
            return None
