from python_bladerf.pylibbladerf.pybladerf import (
    PyBladerfDevice,
    _dispatch_rf_event_batch,
    _dispatch_rx_data_withheld,
    _rf_event_name,
)


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
