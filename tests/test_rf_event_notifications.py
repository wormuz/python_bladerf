from python_bladerf.pylibbladerf.pybladerf import (
    RF_INVALIDATE_BANDWIDTH,
    RF_INVALIDATE_BOOTLOADER,
    RF_INVALIDATE_FPGA_RX_FAULT,
    RF_FPGA_RX_FAULT_CAUSES_VALID,
    RF_FPGA_RX_FAULT_GPIF_TIMEOUT,
    RF_FPGA_RX_FAULT_FIFO_ABORT,
    RF_INVALIDATE_FPGA_STATUS_UNAVAILABLE,
    RF_INVALIDATE_RFIC_PLL_UNLOCKED,
    RF_INVALIDATE_RFIC_ENSM_NOT_RX,
    RF_INVALIDATE_RFIC_STATUS_UNAVAILABLE,
    RF_INVALIDATE_RFIC_BBPLL_UNLOCKED,
    RF_INVALIDATE_FPGA_RX_LOSS_STATUS_UNAVAILABLE,
    RF_REQUIRE_PLL_LOCKED,
    RF_REQUIRE_ENSM_RX,
    RF_REQUIRE_DATAPATH_ARMED,
    RF_REQUIRE_EPOCH_VALID,
    RF_REQUIRE_BBPLL_LOCKED,
    RF_STREAM_STATUS_FPGA_RX_LOSS,
    RF_STREAM_STATUS_SYNC_RX_QUEUE,
    RF_STREAM_STATUS_ASYNC_USB,
    RF_STREAM_STATUS_TIMESTAMP_DISCONTINUITY,
    RF_STREAM_STATUS_RUNTIME_STATE_FAULT,
    RF_STREAM_STATUS_SYNC_RX_RING_FULL,
    RF_STREAM_STATUS_SYNC_RX_REORDER,
    RF_STREAM_STATUS_SYNC_RX_SEQUENCE_TRACKER,
    RF_INVALIDATE_CLOCK,
    RF_INVALIDATE_CORRECTION,
    RF_INVALIDATE_DEVICE_RESET,
    RF_INVALIDATE_FPGA_RELOAD,
    RF_INVALIDATE_FREQUENCY,
    RF_INVALIDATE_GAIN,
    RF_INVALIDATE_GAIN_MODE,
    RF_INVALIDATE_LOOPBACK,
    RF_INVALIDATE_MODULE,
    RF_INVALIDATE_RF_PORT,
    RF_INVALIDATE_RFIC_REG,
    RF_INVALIDATE_RX_FIR,
    RF_INVALIDATE_TX_FIR,
    RF_INVALIDATE_CONFIG_GPIO,
    RF_INVALIDATE_WISHBONE,
    RF_INVALIDATE_FEATURE,
    RF_INVALIDATE_RX_MUX,
    RF_INVALIDATE_SAMPLE_RATE,
    RF_INVALIDATE_STREAM_CONFIG,
    RF_INVALIDATE_TUNING_MODE,
    RF_EVENT_F_FPGA_TIMESTAMP_VALID,
    RF_WITHHELD_DEVICE_LOST,
    RF_WITHHELD_SHORT_TRANSFER,
    RF_WITHHELD_SYNC_TIMEOUT,
    RF_WITHHELD_TIMESTAMP_DISCONTINUITY,
    RF_WITHHELD_USB_OVERFLOW,
    RF_WITHHELD_USB_TIMEOUT,
    RF_WITHHELD_USB_TRANSFER_ERROR,
    PyBladerfDevice,
    _rf_event_poll_loop,
    _dispatch_rf_event_batch,
    _dispatch_rx_data_withheld,
    _rf_event_name,
    _rf_event_validity_fields,
    _rf_invalidation_reason,
)
import threading
import weakref


def test_rx_transition_requirement_flags_are_named_and_composable():
    requirements = [
        RF_REQUIRE_PLL_LOCKED,
        RF_REQUIRE_ENSM_RX,
        RF_REQUIRE_DATAPATH_ARMED,
        RF_REQUIRE_EPOCH_VALID,
        RF_REQUIRE_BBPLL_LOCKED,
    ]
    assert requirements == [1 << bit for bit in range(5)]
    assert len(set(requirements)) == len(requirements)
    assert (RF_REQUIRE_PLL_LOCKED | RF_REQUIRE_ENSM_RX |
            RF_REQUIRE_BBPLL_LOCKED | RF_REQUIRE_EPOCH_VALID) == 0x1B


def test_rf_invalidation_reason_names_cover_every_public_reason():
    # RX_DATA_INVALIDATED is event type 19 in the public libbladeRF API.
    reasons = [
        (RF_INVALIDATE_FREQUENCY, "frequency"),
        (RF_INVALIDATE_SAMPLE_RATE, "sample_rate"),
        (RF_INVALIDATE_BANDWIDTH, "bandwidth"),
        (RF_INVALIDATE_GAIN, "gain"),
        (RF_INVALIDATE_GAIN_MODE, "gain_mode"),
        (RF_INVALIDATE_RF_PORT, "rf_port"),
        (RF_INVALIDATE_CORRECTION, "correction"),
        (RF_INVALIDATE_RX_MUX, "rx_mux"),
        (RF_INVALIDATE_LOOPBACK, "loopback"),
        (RF_INVALIDATE_MODULE, "module"),
        (RF_INVALIDATE_RFIC_REG, "rfic_register"),
        (RF_INVALIDATE_RX_FIR, "rx_fir"),
        (RF_INVALIDATE_TX_FIR, "tx_fir"),
        (RF_INVALIDATE_CONFIG_GPIO, "config_gpio"),
        (RF_INVALIDATE_WISHBONE, "wishbone"),
        (RF_INVALIDATE_FEATURE, "feature"),
        (RF_INVALIDATE_CLOCK, "clock"),
        (RF_INVALIDATE_STREAM_CONFIG, "stream_config"),
        (RF_INVALIDATE_TUNING_MODE, "tuning_mode"),
        (RF_INVALIDATE_DEVICE_RESET, "device_reset"),
        (RF_INVALIDATE_FPGA_RELOAD, "fpga_reload"),
        (RF_INVALIDATE_BOOTLOADER, "bootloader"),
        (RF_INVALIDATE_FPGA_RX_FAULT, "fpga_rx_fault"),
        (RF_INVALIDATE_FPGA_STATUS_UNAVAILABLE, "fpga_status_unavailable"),
        (RF_INVALIDATE_RFIC_PLL_UNLOCKED, "rfic_pll_unlocked"),
        (RF_INVALIDATE_RFIC_ENSM_NOT_RX, "rfic_ensm_not_rx"),
        (RF_INVALIDATE_RFIC_STATUS_UNAVAILABLE, "rfic_status_unavailable"),
        (RF_INVALIDATE_RFIC_BBPLL_UNLOCKED, "rfic_bbpll_unlocked"),
        (RF_INVALIDATE_FPGA_RX_LOSS_STATUS_UNAVAILABLE,
         "fpga_rx_loss_status_unavailable"),
    ]
    assert len({flag for flag, _ in reasons}) == len(reasons)
    assert all(_rf_invalidation_reason(19, flag) == name
               for flag, name in reasons)
    assert _rf_invalidation_reason(20, RF_INVALIDATE_DEVICE_RESET) is None


def test_dispatch_synthesizes_history_loss_before_retained_events():
    retained = [{"event_name": "rx_data_invalidated", "flags": 1}]
    received = []
    errors = []
    notifications = _dispatch_rf_event_batch(
        [received.append], errors,
        {"events": retained, "history_complete": False,
         "next_sequence": 69}, previous_cursor=4)

    assert [event["event_name"] for event in notifications] == [
        "rf_event_history_lost", "rx_data_invalidated"]
    assert notifications[0]["after_sequence"] == 4
    assert notifications[0]["observed_through_sequence"] == 69
    assert notifications[0]["history_complete"] is False
    assert notifications[0]["iq_valid"] is False
    assert received == notifications
    assert errors == [{"error": "RF event history overrun",
                       "history_complete": False}]


def test_history_loss_notification_reaches_callbacks_and_records_errors():
    received = []
    errors = []

    def broken_callback(_event):
        raise RuntimeError("consumer failed")

    _dispatch_rf_event_batch(
        [received.append, broken_callback], errors,
        {"events": [], "history_complete": False, "next_sequence": 100},
        previous_cursor=0)

    event = received[0]
    assert received == [event]
    assert len(errors) == 2
    assert errors[0] == {"error": "RF event history overrun",
                         "history_complete": False}
    assert errors[1]["event"] == event
    assert "consumer failed" in errors[1]["error"]


def test_dispatch_without_subscribers_does_not_consume_native_history():
    # An unopened wrapper has no C device. Dispatch must return before asking
    # libbladeRF for events when no subscriber exists, leaving its ring
    # available to an explicit rf_events_since() query later.
    device = PyBladerfDevice()
    device.pybladerf_dispatch_rf_events()


def test_event_poller_delivers_while_caller_is_blocked():
    delivered = threading.Event()

    class PollTarget:
        def dispatch(self):
            delivered.set()

    target = PollTarget()

    class Dispatcher:
        def pybladerf_dispatch_rf_events(self):
            target.dispatch()

    dispatcher = Dispatcher()
    stop = threading.Event()
    poller = threading.Thread(
        target=_rf_event_poll_loop,
        args=(stop, weakref.ref(dispatcher), 0.005),
        daemon=True,
    )
    poller.start()
    try:
        # The calling thread does no wrapper API work while the poller runs.
        assert delivered.wait(0.5)
    finally:
        stop.set()
        poller.join(timeout=1)
    assert not poller.is_alive()


def test_event_poller_reports_transient_failure_and_recovers():
    delivered = threading.Event()
    notifications = []
    failures = []

    class Dispatcher:
        calls = 0

        def pybladerf_dispatch_rf_events(self):
            self.calls += 1
            if self.calls == 1:
                raise OSError("temporary native event read failure")
            delivered.set()

        def _record_rf_event_poller_error(self, exc):
            failures.append(repr(exc))
            notifications.append({
                "event_name": "rf_event_poller_error",
                "iq_valid": False,
                "history_complete": False,
            })

    dispatcher = Dispatcher()
    stop = threading.Event()
    poller = threading.Thread(
        target=_rf_event_poll_loop,
        args=(stop, weakref.ref(dispatcher), 0.005),
        daemon=True,
    )
    poller.start()
    try:
        assert delivered.wait(0.5)
    finally:
        stop.set()
        poller.join(timeout=1)
    assert not poller.is_alive()
    assert dispatcher.calls >= 2
    assert failures == ["OSError('temporary native event read failure')"]
    assert notifications == [{
        "event_name": "rf_event_poller_error",
        "iq_valid": False,
        "history_complete": False,
    }]


def test_device_supports_weak_reference_for_poller_lifetime():
    device = PyBladerfDevice()
    assert weakref.ref(device)() is device


def test_async_rx_withheld_notification_is_explicit_and_invalid():
    received = []
    errors = []
    withheld = _dispatch_rx_data_withheld([received.append], errors, False)
    withheld = _dispatch_rx_data_withheld([received.append], errors, withheld)
    assert len(received) == 1
    event = received[0]
    assert event["event_name"] == "rx_data_withheld"
    assert event["iq_valid"] is False
    assert event["transaction_id"] == 0
    assert errors == []
    assert _dispatch_rx_data_withheld([received.append], errors, False)
    assert len(received) == 2


def test_unsupported_format_has_public_event_name():
    assert _rf_event_name(9) == "rx_epoch_valid"
    assert _rf_event_name(13) == "rx_first_valid_host_data"
    assert _rf_event_name(21) == "rx_format_unsupported"
    assert _rf_event_name(22) == "rx_data_withheld"
    assert _rf_event_name(23) == "rx_epoch_abort_failed"
    assert _rf_event_name(24) == "rx_data_resumed"
    assert _rf_event_name(25) == "rx_bbpll_locked"


def test_timestamp_discontinuity_reason_is_public():
    assert RF_WITHHELD_TIMESTAMP_DISCONTINUITY == 1 << 2
    assert _rf_event_validity_fields(22, RF_WITHHELD_TIMESTAMP_DISCONTINUITY) == {
        "iq_valid": False,
        "withheld_reason": "timestamp_discontinuity",
    }
    assert _rf_event_validity_fields(22, RF_WITHHELD_SHORT_TRANSFER) == {
        "iq_valid": False,
        "withheld_reason": "short_transfer",
    }
    timestamped_withheld = _rf_event_validity_fields(
        22, RF_WITHHELD_SHORT_TRANSFER | RF_EVENT_F_FPGA_TIMESTAMP_VALID)
    assert timestamped_withheld == {
        "iq_valid": False,
        "withheld_reason": "short_transfer",
        "fpga_timestamp_valid": True,
    }
    assert _rf_event_validity_fields(
        24, RF_EVENT_F_FPGA_TIMESTAMP_VALID) == {
            "iq_valid": True, "fpga_timestamp_valid": True,
        }
    assert _rf_event_validity_fields(22, RF_WITHHELD_USB_OVERFLOW) == {
        "iq_valid": False,
        "withheld_reason": "usb_overflow",
    }
    for reason, name in [
        (RF_WITHHELD_USB_TRANSFER_ERROR, "usb_transfer_error"),
        (RF_WITHHELD_USB_TIMEOUT, "usb_timeout"),
        (RF_WITHHELD_SYNC_TIMEOUT, "sync_timeout"),
        (RF_WITHHELD_DEVICE_LOST, "device_lost"),
    ]:
        assert _rf_event_validity_fields(22, reason) == {
            "iq_valid": False,
            "withheld_reason": name,
        }


def test_native_rx_integrity_events_explicitly_mark_iq_invalid():
    # Public RF event IDs 0..25 cover transition, data-validity, and
    # transport-integrity events. Every known event is explicit: only the
    # first or resumed host-validated META packet can set iq_valid=True.
    for event_type in set(range(26)) - {9, 13, 19, 20, 22, 24}:
        assert _rf_event_validity_fields(event_type, 0) == {
            "iq_valid": False,
        }
    assert _rf_event_validity_fields(19, RF_INVALIDATE_BANDWIDTH) == {
        "iq_valid": False,
        "affected_rx_channels": ["RX1", "RX2"],
    }
    assert _rf_event_validity_fields(9, 0) == {
        "iq_valid": False, "rx_epoch_valid": True,
    }
    assert _rf_event_validity_fields(13, 0) == {"iq_valid": True}
    assert _rf_event_validity_fields(24, 0) == {"iq_valid": True}
    assert _rf_event_validity_fields(25, 0) == {"iq_valid": False}
    assert _rf_event_validity_fields(20, 0) == {
        "iq_valid": False, "overrun_source": "host_stream_integrity",
    }
    assert _rf_event_validity_fields(20, RF_STREAM_STATUS_FPGA_RX_LOSS) == {
        "iq_valid": False, "overrun_source": "fpga_rx_loss_counter",
    }
    assert _rf_event_validity_fields(20, RF_STREAM_STATUS_SYNC_RX_QUEUE) == {
        "iq_valid": False, "overrun_source": "sync_rx_queue",
    }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_SYNC_RX_QUEUE |
        RF_STREAM_STATUS_SYNC_RX_RING_FULL) == {
            "iq_valid": False,
            "overrun_source": "sync_rx_queue",
            "overrun_detail": "sync_rx_ring_full",
        }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_SYNC_RX_QUEUE |
        RF_STREAM_STATUS_SYNC_RX_REORDER) == {
            "iq_valid": False,
            "overrun_source": "sync_rx_queue",
            "overrun_detail": "sync_rx_reorder_window",
        }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_SYNC_RX_QUEUE |
        RF_STREAM_STATUS_SYNC_RX_SEQUENCE_TRACKER) == {
            "iq_valid": False,
            "overrun_source": "sync_rx_queue",
            "overrun_detail": "sync_rx_sequence_tracker_full",
        }
    assert _rf_event_validity_fields(20, RF_STREAM_STATUS_ASYNC_USB) == {
        "iq_valid": False, "overrun_source": "async_usb_transport",
    }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_TIMESTAMP_DISCONTINUITY) == {
            "iq_valid": False,
            "overrun_source": "timestamp_discontinuity",
        }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_RUNTIME_STATE_FAULT) == {
            "iq_valid": False, "overrun_source": "runtime_state_fault",
        }
    assert _rf_event_validity_fields(
        20, RF_STREAM_STATUS_SYNC_RX_QUEUE | RF_STREAM_STATUS_ASYNC_USB) == {
            "iq_valid": False,
            "overrun_source": ["sync_rx_queue", "async_usb_transport"],
        }
    assert _rf_event_validity_fields(22, RF_WITHHELD_USB_TIMEOUT) == {
        "iq_valid": False,
        "withheld_reason": "usb_timeout",
    }
    assert _rf_event_validity_fields(26, 0) == {
        "iq_valid": False,
        "event_type_unknown": True,
    }
    assert _rf_event_validity_fields(
        0x7fffffff, RF_EVENT_F_FPGA_TIMESTAMP_VALID) == {
            "iq_valid": False,
            "event_type_unknown": True,
            "fpga_timestamp_valid": True,
        }


def test_fpga_fault_event_exposes_coherent_cause_snapshot():
    causes = (RF_FPGA_RX_FAULT_CAUSES_VALID |
              RF_FPGA_RX_FAULT_GPIF_TIMEOUT |
              RF_FPGA_RX_FAULT_FIFO_ABORT)
    assert _rf_event_validity_fields(
        19, RF_INVALIDATE_FPGA_RX_FAULT, causes
    ) == {
        "iq_valid": False,
        "affected_rx_channels": ["RX1", "RX2"],
        "fpga_rx_fault_causes": ["gpif_timeout", "fifo_abort"],
    }


def test_lo_pll_calibration_and_nios_intermediate_events_are_invalid():
    # These are all observed before FPGA epoch admission or host META
    # validation and must not leave validity implicit in Python callbacks.
    for event_type in (0, 1, 2, 3, 4, 5, 6, 11, 12, 14, 16, 17, 18):
        assert _rf_event_validity_fields(event_type, 0) == {
            "iq_valid": False,
        }
