"""xA4 integration test for Python RF callbacks during a blocked sync read.

Run against libbladeRF built with
ENABLE_TEST_RX_TRANSITION_STALL_INJECTION=ON:

    PYTHONPATH=. LD_PRELOAD=/path/to/test-build/output/libbladeRF.so \
        .venv/bin/python tests/live_rx_event_poller.py

The script primes real META data, then enables a host-observed ENSM status
fault. It requires the Python invalidation callback before the long sync read
returns and verifies that the read exposes no IQ after invalidation.
"""

import os
import threading
import time

import numpy as np

from python_bladerf.pylibbladerf.pybladerf import (
    PYBLADERF_CHANNEL_RX,
    PYBLADERF_META_FLAG_RX_NOW,
    pybladerf_channel_layout,
    pybladerf_format,
    pybladerf_metadata,
    pybladerf_open,
)


def read_valid_meta(device, num_samples: int, timeout_s: float = 3.0) -> None:
    samples = np.empty(num_samples * 2, dtype=np.int16)
    deadline = time.monotonic() + timeout_s
    while True:
        metadata = pybladerf_metadata(flags=PYBLADERF_META_FLAG_RX_NOW)
        try:
            device.pybladerf_sync_rx(samples, num_samples, metadata, 1000)
            return
        except Exception as exc:
            if "WOULD_BLOCK" not in type(exc).__name__ or time.monotonic() >= deadline:
                raise
            time.sleep(0.01)


def main() -> None:
    device = pybladerf_open()
    if device is None:
        raise RuntimeError("no bladeRF found")

    invalidation = threading.Event()
    reader_started = threading.Event()
    reader_finished = threading.Event()
    callback_records = []
    reader_status = []

    def on_rf_event(event: dict) -> None:
        if event.get("event_name") == "rx_data_invalidated":
            callback_records.append((event, reader_finished.is_set()))
            invalidation.set()

    def blocked_reader() -> None:
        samples = np.empty(4 * 1024 * 1024 * 2, dtype=np.int16)
        reader_started.set()
        try:
            device.pybladerf_sync_rx(
                samples, 4 * 1024 * 1024,
                pybladerf_metadata(flags=PYBLADERF_META_FLAG_RX_NOW), 5000)
            reader_status.append("unexpected IQ returned")
        except Exception as exc:
            reader_status.append(type(exc).__name__)
        finally:
            reader_finished.set()

    reader_thread = None
    try:
        channel = PYBLADERF_CHANNEL_RX(0)
        device.pybladerf_set_sample_rate(channel, 1_000_000)
        device.pybladerf_set_bandwidth(channel, 1_500_000)
        device.pybladerf_sync_config(
            pybladerf_channel_layout.PYBLADERF_RX_X1,
            pybladerf_format.PYBLADERF_FORMAT_SC16_Q11_META,
            16, 8192, 8, 1000)
        device.pybladerf_enable_module(channel, True)
        device.pybladerf_add_rf_event_callback(on_rf_event)

        transaction_id = device.pybladerf_rx_transition_begin(
            channel, 1_835_000_000, 1, 2000)
        transition = device.pybladerf_rx_transition_wait(transaction_id, 2000)
        if transition["event_type"] != 9:  # RX_EPOCH_VALID; IQ still unproven.
            raise AssertionError(f"transition failed: {transition}")
        read_valid_meta(device, 8192)

        os.environ["BLADERF_TEST_RX_TRANSITION_STALL"] = "RUNTIME_RFIC_ENSM_NOT_RX"
        reader_thread = threading.Thread(target=blocked_reader, daemon=True)
        reader_thread.start()
        if not reader_started.wait(1):
            raise AssertionError("sync reader did not start")
        if not invalidation.wait(2):
            raise AssertionError("Python runtime invalidation callback timed out")
        if callback_records[0][1]:
            raise AssertionError("callback arrived after sync reader exited")
        reader_thread.join(6)
        if not reader_finished.is_set():
            raise AssertionError("sync reader did not exit after invalidation")
        if not reader_status or "WOULD_BLOCK" not in reader_status[0]:
            raise AssertionError(f"reader result was not fail-closed: {reader_status}")
        event = callback_records[0][0]
        if event.get("invalidation_reason") != "rfic_ensm_not_rx" or event.get("iq_valid"):
            raise AssertionError(f"unexpected invalidation payload: {event}")
        print({
            "callback_before_reader_exit": True,
            "invalidation_reason": event["invalidation_reason"],
            "iq_valid": event["iq_valid"],
            "sync_reader": reader_status[0],
        })
    finally:
        if reader_thread is not None:
            reader_thread.join(6)
        device.pybladerf_close()


if __name__ == "__main__":
    main()
