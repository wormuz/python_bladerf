from python_bladerf.pylibbladerf.pybladerf import (
    _deliver_rf_event,
    _rf_event_notifications,
)


def test_dispatch_synthesizes_history_loss_before_retained_events():
    retained = [{"event_name": "rx_data_invalidated", "flags": 1}]
    notifications = _rf_event_notifications(
        retained, False, after_sequence=4, observed_sequence=69)

    assert [event["event_name"] for event in notifications] == [
        "rf_event_history_lost", "rx_data_invalidated"]
    assert notifications[0]["after_sequence"] == 4
    assert notifications[0]["observed_through_sequence"] == 69
    assert notifications[0]["history_complete"] is False


def test_history_loss_notification_reaches_callbacks_and_records_errors():
    event = _rf_event_notifications([], False, 0, 100)[0]
    received = []
    errors = []

    def broken_callback(_event):
        raise RuntimeError("consumer failed")

    _deliver_rf_event([received.append, broken_callback], errors, event)

    assert received == [event]
    assert len(errors) == 1
    assert errors[0]["event"] == event
    assert "consumer failed" in errors[0]["error"]
