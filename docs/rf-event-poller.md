# Python RF event delivery

`pybladerf_add_rf_event_callback()` polls libbladeRF's retained RF event
history so invalidation and stream-integrity notifications can arrive while a
Python thread is blocked in `pybladerf_sync_rx()`.

If one poll raises, the wrapper now sends subscribers an
`rf_event_poller_error` event with `iq_valid=False` and
`history_complete=False`, records the exception in
`pybladerf_get_rf_event_callback_errors()`, and retries with exponential
backoff capped at one second. A successful poll restores the normal poll
interval and clears the outage state. Native event history remains the source
of truth; without subscribers, API calls do not consume it.

`rx_stream_overrun` notifications always set `iq_valid=False` and now expose
`overrun_source` as `fpga_rx_loss_counter`, `sync_rx_queue`,
`async_usb_transport`, `timestamp_discontinuity`, or `runtime_state_fault`.
Events carrying more than one source return a list. Generic host-integrity
events from older libbladeRF builds retain `host_stream_integrity`.
Sync queue events also set `overrun_detail` to identify ring exhaustion
(`sync_rx_ring_full`), reorder-window overflow
(`sync_rx_reorder_window`), or a full dropped-sequence tracker
(`sync_rx_sequence_tracker_full`). Multiple details are returned as a list.

`rx_data_invalidated` notifications include `affected_rx_channels`, currently
`["RX1", "RX2"]`. Firmware and libbladeRF maintain one RX epoch certificate
for the shared AD9361 RX LO, so invalidating it revokes both channel consumers
even if the setter was called through only one RX channel handle. A
single-channel consumer may ignore its inactive channel; MIMO consumers must
treat the paired epoch as invalid.

Event types newer than the wrapper are reported with `iq_valid=False` and
`event_type_unknown=True`, so extending the native event enum remains
fail-closed for older Python consumers.

Verification:

- `tests/test_rf_event_notifications.py` covers transient poll failure,
  fail-closed notification, recovery, and callback behavior.
- `tests/live_rx_event_poller.py` injects an ENSM fault while sync RX is
  blocked and confirms the Python invalidation callback runs before the read
  exits with `WOULD_BLOCK` and `iq_valid=False`.
