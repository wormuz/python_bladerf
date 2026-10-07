from python_bladerf.pylibbladerf.pybladerf import (
    RF_INVALIDATE_BANDWIDTH,
    RF_INVALIDATE_BOOTLOADER,
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
    RF_INVALIDATE_RX_MUX,
    RF_INVALIDATE_SAMPLE_RATE,
    RF_INVALIDATE_STREAM_CONFIG,
    RF_INVALIDATE_TUNING_MODE,
    RF_WITHHELD_DEVICE_LOST,
    RF_WITHHELD_SHORT_TRANSFER,
    RF_WITHHELD_SYNC_TIMEOUT,
    RF_WITHHELD_TIMESTAMP_DISCONTINUITY,
    RF_WITHHELD_USB_OVERFLOW,
    RF_WITHHELD_USB_TIMEOUT,
    RF_WITHHELD_USB_TRANSFER_ERROR,
    PyBladerfDevice,
    _dispatch_rf_event_batch,
    _dispatch_rx_data_withheld,
    _rf_event_name,
    _rf_event_validity_fields,
    _rf_invalidation_reason,
)


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
        (RF_INVALIDATE_CLOCK, "clock"),
        (RF_INVALIDATE_STREAM_CONFIG, "stream_config"),
        (RF_INVALIDATE_TUNING_MODE, "tuning_mode"),
        (RF_INVALIDATE_DEVICE_RESET, "device_reset"),
        (RF_INVALIDATE_FPGA_RELOAD, "fpga_reload"),
        (RF_INVALIDATE_BOOTLOADER, "bootloader"),
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
    assert _rf_event_name(21) == "rx_format_unsupported"
    assert _rf_event_name(22) == "rx_data_withheld"
    assert _rf_event_name(23) == "rx_epoch_abort_failed"


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
    # Public event IDs: epoch-invalid=8, error=10, invalidation=19,
    # stream-overrun=20, unsupported-format=21, withheld=22,
    # epoch-abort-failed=23.
    assert _rf_event_validity_fields(8, 0) == {"iq_valid": False}
    assert _rf_event_validity_fields(10, 0) == {"iq_valid": False}
    assert _rf_event_validity_fields(19, RF_INVALIDATE_GAIN) == {
        "iq_valid": False,
    }
    assert _rf_event_validity_fields(20, 0) == {"iq_valid": False}
    assert _rf_event_validity_fields(21, 0) == {"iq_valid": False}
    assert _rf_event_validity_fields(23, 0) == {"iq_valid": False}
