# MIT License

# Copyright (c) 2024-2025 GvozdevLeonid

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# distutils: language = c++
# cython: language_level = 3str
# cython: freethreading_compatible = True
from python_bladerf import __version__
from libc.stdint cimport uint8_t, int16_t, uint16_t, int32_t, uint32_t, uint64_t, uintptr_t
from libc.string cimport memcpy, memset, strncpy
from cpython cimport Py_INCREF, Py_DECREF
from typing import Any, Callable, Self
from libc.stdlib cimport malloc, free
from libcpp cimport bool as c_bool
from enum import IntEnum
from ctypes import c_int
from . cimport cbladerf
import numpy as np
import threading
import weakref
cimport cython

IF ANDROID:
    from .__android import get_bladerf_device_list


cdef dict global_callbacks = {}


def _rf_event_poll_loop(stop_event, device_ref, interval_s: float) -> None:
    """Deliver native RF events while another wrapper call is blocked."""
    retry_interval = interval_s
    outage_reported = False
    while not stop_event.wait(retry_interval):
        device = device_ref()
        if device is None:
            return
        try:
            device.pybladerf_dispatch_rf_events()
        except Exception as exc:
            if not outage_reported:
                device._record_rf_event_poller_error(exc)
                outage_reported = True
            retry_interval = min(max(interval_s, retry_interval * 2), 1.0)
            del device
            continue
        retry_interval = interval_s
        outage_reported = False
        del device

# `flags` on an `rx_data_withheld` native event is a bitmask. Export the
# timestamp-continuity reason so Python consumers can distinguish it from an
# epoch boundary or missing certificate.
RF_INVALIDATE_FREQUENCY = cbladerf.BLADERF_RF_INVALIDATE_FREQUENCY
RF_INVALIDATE_SAMPLE_RATE = cbladerf.BLADERF_RF_INVALIDATE_SAMPLE_RATE
RF_INVALIDATE_BANDWIDTH = cbladerf.BLADERF_RF_INVALIDATE_BANDWIDTH
RF_REQUIRE_PLL_LOCKED = cbladerf.BLADERF_RF_REQUIRE_PLL_LOCKED
RF_REQUIRE_ENSM_RX = cbladerf.BLADERF_RF_REQUIRE_ENSM_RX
RF_REQUIRE_DATAPATH_ARMED = cbladerf.BLADERF_RF_REQUIRE_DATAPATH_ARMED
RF_REQUIRE_EPOCH_VALID = cbladerf.BLADERF_RF_REQUIRE_EPOCH_VALID
RF_REQUIRE_BBPLL_LOCKED = cbladerf.BLADERF_RF_REQUIRE_BBPLL_LOCKED
RF_REQUIRE_FIRST_HOST_DATA = cbladerf.BLADERF_RF_REQUIRE_FIRST_HOST_DATA
RF_REQUIRE_RX_X2_HOST_DATA = cbladerf.BLADERF_RF_REQUIRE_RX_X2_HOST_DATA
RF_INVALIDATE_GAIN = cbladerf.BLADERF_RF_INVALIDATE_GAIN
RF_INVALIDATE_GAIN_MODE = cbladerf.BLADERF_RF_INVALIDATE_GAIN_MODE
RF_INVALIDATE_RF_PORT = cbladerf.BLADERF_RF_INVALIDATE_RF_PORT
RF_INVALIDATE_CORRECTION = cbladerf.BLADERF_RF_INVALIDATE_CORRECTION
RF_INVALIDATE_RX_MUX = cbladerf.BLADERF_RF_INVALIDATE_RX_MUX
RF_INVALIDATE_LOOPBACK = cbladerf.BLADERF_RF_INVALIDATE_LOOPBACK
RF_INVALIDATE_MODULE = cbladerf.BLADERF_RF_INVALIDATE_MODULE
RF_INVALIDATE_RFIC_REG = cbladerf.BLADERF_RF_INVALIDATE_RFIC_REG
RF_INVALIDATE_RX_FIR = cbladerf.BLADERF_RF_INVALIDATE_RX_FIR
RF_INVALIDATE_TX_FIR = cbladerf.BLADERF_RF_INVALIDATE_TX_FIR
RF_INVALIDATE_CONFIG_GPIO = cbladerf.BLADERF_RF_INVALIDATE_CONFIG_GPIO
RF_INVALIDATE_WISHBONE = cbladerf.BLADERF_RF_INVALIDATE_WISHBONE
RF_INVALIDATE_TRIGGER = cbladerf.BLADERF_RF_INVALIDATE_TRIGGER
RF_INVALIDATE_FEATURE = cbladerf.BLADERF_RF_INVALIDATE_FEATURE
RF_INVALIDATE_RX_CHANNEL_STATE_CHANGED = (
    cbladerf.BLADERF_RF_INVALIDATE_RX_CHANNEL_STATE_CHANGED)
RF_INVALIDATE_RX_CHANNEL_STATUS_UNAVAILABLE = (
    cbladerf.BLADERF_RF_INVALIDATE_RX_CHANNEL_STATUS_UNAVAILABLE)
RF_INVALIDATE_CLOCK = cbladerf.BLADERF_RF_INVALIDATE_CLOCK
RF_INVALIDATE_STREAM_CONFIG = cbladerf.BLADERF_RF_INVALIDATE_STREAM_CONFIG
RF_WITHHELD_EPOCH_UNCERTIFIED = cbladerf.BLADERF_RF_WITHHELD_EPOCH_UNCERTIFIED
RF_WITHHELD_EPOCH_OR_TIMESTAMP_MISMATCH = (
    cbladerf.BLADERF_RF_WITHHELD_EPOCH_OR_TIMESTAMP_MISMATCH)
RF_WITHHELD_TIMESTAMP_DISCONTINUITY = (
    cbladerf.BLADERF_RF_WITHHELD_TIMESTAMP_DISCONTINUITY)
RF_WITHHELD_SHORT_TRANSFER = cbladerf.BLADERF_RF_WITHHELD_SHORT_TRANSFER
RF_WITHHELD_USB_OVERFLOW = cbladerf.BLADERF_RF_WITHHELD_USB_OVERFLOW
RF_WITHHELD_USB_TRANSFER_ERROR = (
    cbladerf.BLADERF_RF_WITHHELD_USB_TRANSFER_ERROR)
RF_WITHHELD_USB_TIMEOUT = cbladerf.BLADERF_RF_WITHHELD_USB_TIMEOUT
RF_WITHHELD_DEVICE_LOST = cbladerf.BLADERF_RF_WITHHELD_DEVICE_LOST
RF_WITHHELD_SYNC_TIMEOUT = cbladerf.BLADERF_RF_WITHHELD_SYNC_TIMEOUT
RF_WITHHELD_RX_CHANNEL_SELECTION = (
    cbladerf.BLADERF_RF_WITHHELD_RX_CHANNEL_SELECTION)
RF_EVENT_F_FPGA_TIMESTAMP_VALID = (
    cbladerf.BLADERF_RF_EVENT_F_FPGA_TIMESTAMP_VALID)
RF_EVENT_F_RX_X2_LAYOUT = cbladerf.BLADERF_RF_EVENT_F_RX_X2_LAYOUT
RF_EVENT_F_TRANSITION_RX2 = cbladerf.BLADERF_RF_EVENT_F_TRANSITION_RX2
RF_EVENT_F_TRANSITION_CHANNEL_VALID = (
    cbladerf.BLADERF_RF_EVENT_F_TRANSITION_CHANNEL_VALID)
RF_INVALIDATE_TUNING_MODE = cbladerf.BLADERF_RF_INVALIDATE_TUNING_MODE
RF_INVALIDATE_DEVICE_RESET = cbladerf.BLADERF_RF_INVALIDATE_DEVICE_RESET
RF_INVALIDATE_FPGA_RELOAD = cbladerf.BLADERF_RF_INVALIDATE_FPGA_RELOAD
RF_INVALIDATE_BOOTLOADER = cbladerf.BLADERF_RF_INVALIDATE_BOOTLOADER
RF_INVALIDATE_FPGA_RX_FAULT = cbladerf.BLADERF_RF_INVALIDATE_FPGA_RX_FAULT
RF_FPGA_RX_FAULT_CAUSES_VALID = cbladerf.BLADERF_RF_FPGA_RX_FAULT_CAUSES_VALID
RF_FPGA_RX_FAULT_SPEED_MISMATCH = cbladerf.BLADERF_RF_FPGA_RX_FAULT_SPEED_MISMATCH
RF_FPGA_RX_FAULT_START_NO_PROGRESS = cbladerf.BLADERF_RF_FPGA_RX_FAULT_START_NO_PROGRESS
RF_FPGA_RX_FAULT_GPIF_TIMEOUT = cbladerf.BLADERF_RF_FPGA_RX_FAULT_GPIF_TIMEOUT
RF_FPGA_RX_FAULT_PROTOCOL_ERROR = cbladerf.BLADERF_RF_FPGA_RX_FAULT_PROTOCOL_ERROR
RF_FPGA_RX_FAULT_FIFO_ABORT = cbladerf.BLADERF_RF_FPGA_RX_FAULT_FIFO_ABORT
RF_INVALIDATE_FPGA_STATUS_UNAVAILABLE = (
    cbladerf.BLADERF_RF_INVALIDATE_FPGA_STATUS_UNAVAILABLE)
RF_INVALIDATE_RFIC_PLL_UNLOCKED = cbladerf.BLADERF_RF_INVALIDATE_RFIC_PLL_UNLOCKED
RF_INVALIDATE_RFIC_ENSM_NOT_RX = cbladerf.BLADERF_RF_INVALIDATE_RFIC_ENSM_NOT_RX
RF_INVALIDATE_RFIC_STATUS_UNAVAILABLE = (
    cbladerf.BLADERF_RF_INVALIDATE_RFIC_STATUS_UNAVAILABLE)
RF_INVALIDATE_RFIC_BBPLL_UNLOCKED = (
    cbladerf.BLADERF_RF_INVALIDATE_RFIC_BBPLL_UNLOCKED)
RF_INVALIDATE_FPGA_RX_LOSS_STATUS_UNAVAILABLE = (
    cbladerf.BLADERF_RF_INVALIDATE_FPGA_RX_LOSS_STATUS_UNAVAILABLE)
RF_STREAM_STATUS_OVERRUN = cbladerf.BLADERF_RF_STREAM_STATUS_OVERRUN
RF_STREAM_STATUS_FPGA_RX_LOSS = (
    cbladerf.BLADERF_RF_STREAM_STATUS_FPGA_RX_LOSS)
RF_STREAM_STATUS_SYNC_RX_QUEUE = (
    cbladerf.BLADERF_RF_STREAM_STATUS_SYNC_RX_QUEUE)
RF_STREAM_STATUS_ASYNC_USB = (
    cbladerf.BLADERF_RF_STREAM_STATUS_ASYNC_USB)
RF_STREAM_STATUS_TIMESTAMP_DISCONTINUITY = (
    cbladerf.BLADERF_RF_STREAM_STATUS_TIMESTAMP_DISCONTINUITY)
RF_STREAM_STATUS_RUNTIME_STATE_FAULT = (
    cbladerf.BLADERF_RF_STREAM_STATUS_RUNTIME_STATE_FAULT)
RF_STREAM_STATUS_SYNC_RX_RING_FULL = (
    cbladerf.BLADERF_RF_STREAM_STATUS_SYNC_RX_RING_FULL)
RF_STREAM_STATUS_SYNC_RX_REORDER = (
    cbladerf.BLADERF_RF_STREAM_STATUS_SYNC_RX_REORDER)
RF_STREAM_STATUS_SYNC_RX_SEQUENCE_TRACKER = (
    cbladerf.BLADERF_RF_STREAM_STATUS_SYNC_RX_SEQUENCE_TRACKER)


def _rf_invalidation_reason(event_type: int, flags: int):
    if event_type != cbladerf.BLADERF_RF_EVT_RX_DATA_INVALIDATED:
        return None
    reasons = {
        RF_INVALIDATE_FREQUENCY: 'frequency',
        RF_INVALIDATE_SAMPLE_RATE: 'sample_rate',
        RF_INVALIDATE_BANDWIDTH: 'bandwidth',
        RF_INVALIDATE_GAIN: 'gain',
        RF_INVALIDATE_GAIN_MODE: 'gain_mode',
        RF_INVALIDATE_RF_PORT: 'rf_port',
        RF_INVALIDATE_CORRECTION: 'correction',
        RF_INVALIDATE_RX_MUX: 'rx_mux',
        RF_INVALIDATE_LOOPBACK: 'loopback',
        RF_INVALIDATE_MODULE: 'module',
        RF_INVALIDATE_RFIC_REG: 'rfic_register',
        RF_INVALIDATE_RX_FIR: 'rx_fir',
        RF_INVALIDATE_TX_FIR: 'tx_fir',
        RF_INVALIDATE_CONFIG_GPIO: 'config_gpio',
        RF_INVALIDATE_WISHBONE: 'wishbone',
        RF_INVALIDATE_TRIGGER: 'trigger',
        RF_INVALIDATE_FEATURE: 'feature',
        RF_INVALIDATE_RX_CHANNEL_STATE_CHANGED: 'rx_channel_state_changed',
        RF_INVALIDATE_RX_CHANNEL_STATUS_UNAVAILABLE:
            'rx_channel_status_unavailable',
        RF_INVALIDATE_CLOCK: 'clock',
        RF_INVALIDATE_STREAM_CONFIG: 'stream_config',
        RF_INVALIDATE_TUNING_MODE: 'tuning_mode',
        RF_INVALIDATE_DEVICE_RESET: 'device_reset',
        RF_INVALIDATE_FPGA_RELOAD: 'fpga_reload',
        RF_INVALIDATE_BOOTLOADER: 'bootloader',
        RF_INVALIDATE_FPGA_RX_FAULT: 'fpga_rx_fault',
        RF_INVALIDATE_FPGA_STATUS_UNAVAILABLE: 'fpga_status_unavailable',
        RF_INVALIDATE_RFIC_PLL_UNLOCKED: 'rfic_pll_unlocked',
        RF_INVALIDATE_RFIC_ENSM_NOT_RX: 'rfic_ensm_not_rx',
        RF_INVALIDATE_RFIC_STATUS_UNAVAILABLE: 'rfic_status_unavailable',
        RF_INVALIDATE_RFIC_BBPLL_UNLOCKED: 'rfic_bbpll_unlocked',
        RF_INVALIDATE_FPGA_RX_LOSS_STATUS_UNAVAILABLE:
            'fpga_rx_loss_status_unavailable',
    }
    return reasons.get(flags, 'unknown')


def _rf_event_validity_fields(event_type: int, flags: int,
                              rfic_status: int = 0) -> dict:
    timestamp_fields = (
        {'fpga_timestamp_valid': True}
        if flags & cbladerf.BLADERF_RF_EVENT_F_FPGA_TIMESTAMP_VALID
        else {}
    )
    invalid_rx_fields = {
        'iq_valid': False,
        'affected_rx_channels': ['RX1', 'RX2'],
    }
    channel_fields = (
        {'transition_channel': 'RX2'
         if flags & cbladerf.BLADERF_RF_EVENT_F_TRANSITION_RX2 else 'RX1'}
        if flags & cbladerf.BLADERF_RF_EVENT_F_TRANSITION_CHANNEL_VALID
        else {})
    if event_type in (
            cbladerf.BLADERF_RF_EVT_RX_FIRST_VALID_HOST_DATA,
            cbladerf.BLADERF_RF_EVT_RX_DATA_RESUMED):
        layout_fields = (
            {'rx_layout': 'RX_X2'}
            if flags & cbladerf.BLADERF_RF_EVENT_F_RX_X2_LAYOUT else {})
        if flags & PYBLADERF_META_STATUS_OVERRUN:
            # These lifecycle events carry bladerf_metadata.status in flags.
            # A block marked overrun is not a complete valid-IQ boundary even
            # if its epoch tag and timestamp passed the structural checks.
            return {**timestamp_fields, **layout_fields, **channel_fields,
                    **invalid_rx_fields,
                    'overrun_source': 'metadata_status'}
        return {**timestamp_fields, **layout_fields, **channel_fields,
                'iq_valid': True}
    if event_type == cbladerf.BLADERF_RF_EVT_RX_DATA_INVALIDATED:
        # The native RX epoch is shared by RX1 and RX2. Invalidating its
        # certificate revokes both lanes, including when the configuration
        # operation was initiated through only one channel handle.
        result = {**timestamp_fields, **invalid_rx_fields}
        if (flags != cbladerf.BLADERF_RF_INVALIDATE_FPGA_RX_FAULT or
                not (rfic_status &
                     cbladerf.BLADERF_RF_FPGA_RX_FAULT_CAUSES_VALID)):
            return result
        cause_bits = (
            (cbladerf.BLADERF_RF_FPGA_RX_FAULT_SPEED_MISMATCH,
             'speed_mismatch'),
            (cbladerf.BLADERF_RF_FPGA_RX_FAULT_START_NO_PROGRESS,
             'start_no_progress'),
            (cbladerf.BLADERF_RF_FPGA_RX_FAULT_GPIF_TIMEOUT,
             'gpif_timeout'),
            (cbladerf.BLADERF_RF_FPGA_RX_FAULT_PROTOCOL_ERROR,
             'protocol_error'),
            (cbladerf.BLADERF_RF_FPGA_RX_FAULT_FIFO_ABORT,
             'fifo_abort'),
        )
        causes = [name for bit, name in cause_bits if rfic_status & bit]
        result['fpga_rx_fault_causes'] = causes
        return result
    if event_type == cbladerf.BLADERF_RF_EVT_RX_EPOCH_VALID:
        # FPGA admission has opened, but no host META packet has yet crossed
        # the epoch/timestamp validator.
        return {**timestamp_fields, **channel_fields, **invalid_rx_fields,
                'rx_epoch_valid': True}
    if event_type == cbladerf.BLADERF_RF_EVT_RX_CAPTURE_CLOSED:
        return {**channel_fields, **invalid_rx_fields,
                'rx_capture_closed': True}
    if event_type == cbladerf.BLADERF_RF_EVT_RX_INVALIDATION_CHANNEL:
        return {**channel_fields, **invalid_rx_fields,
                'invalidation_context': True}
    if event_type == cbladerf.BLADERF_RF_EVT_RX_STREAM_OVERRUN:
        source_flags = (
            (RF_STREAM_STATUS_FPGA_RX_LOSS, 'fpga_rx_loss_counter'),
            (RF_STREAM_STATUS_SYNC_RX_QUEUE, 'sync_rx_queue'),
            (RF_STREAM_STATUS_ASYNC_USB, 'async_usb_transport'),
            (RF_STREAM_STATUS_TIMESTAMP_DISCONTINUITY,
             'timestamp_discontinuity'),
            (RF_STREAM_STATUS_RUNTIME_STATE_FAULT, 'runtime_state_fault'),
        )
        sources = [name for bit, name in source_flags if flags & bit]
        if not sources:
            sources = ['host_stream_integrity']
        detail_flags = (
            (RF_STREAM_STATUS_SYNC_RX_RING_FULL, 'sync_rx_ring_full'),
            (RF_STREAM_STATUS_SYNC_RX_REORDER, 'sync_rx_reorder_window'),
            (RF_STREAM_STATUS_SYNC_RX_SEQUENCE_TRACKER,
             'sync_rx_sequence_tracker_full'),
        )
        details = [name for bit, name in detail_flags if flags & bit]
        result = {**timestamp_fields, **channel_fields, **invalid_rx_fields,
                  'overrun_source': sources[0] if len(sources) == 1 else sources}
        if details:
            result['overrun_detail'] = (
                details[0] if len(details) == 1 else details)
        return result
    if event_type in (
            cbladerf.BLADERF_RF_EVT_CONFIG_ACCEPTED,
            cbladerf.BLADERF_RF_EVT_SPI_DONE,
            cbladerf.BLADERF_RF_EVT_RX_PLL_LOCKED,
            cbladerf.BLADERF_RF_EVT_ENSM_RX,
            cbladerf.BLADERF_RF_EVT_RX_BBDC_CAL_DONE,
            cbladerf.BLADERF_RF_EVT_RX_RFDC_CAL_DONE,
            cbladerf.BLADERF_RF_EVT_RX_QUAD_CAL_DONE,
            cbladerf.BLADERF_RF_EVT_RX_EPOCH_INVALID,
            cbladerf.BLADERF_RF_EVT_ERROR,
            cbladerf.BLADERF_RF_EVT_LO_SET_RETURNED,
            cbladerf.BLADERF_RF_EVT_LO_READBACK_MATCH,
            cbladerf.BLADERF_RF_EVT_SPI_WRITE_BEGIN,
            cbladerf.BLADERF_RF_EVT_NIOS_RETUNE_BEGIN,
            cbladerf.BLADERF_RF_EVT_NIOS_RETUNE_USB_OUT_DONE,
            cbladerf.BLADERF_RF_EVT_NIOS_RETUNE_RESPONSE,
            cbladerf.BLADERF_RF_EVT_RX_DATAPATH_ARMED,
            cbladerf.BLADERF_RF_EVT_CONTROL_PLANE_CONFIRMED,
            cbladerf.BLADERF_RF_EVT_RX_STREAM_OVERRUN,
            cbladerf.BLADERF_RF_EVT_RX_FORMAT_UNSUPPORTED,
            cbladerf.BLADERF_RF_EVT_RX_EPOCH_ABORT_FAILED,
            cbladerf.BLADERF_RF_EVT_RX_BBPLL_LOCKED,
            cbladerf.BLADERF_RF_EVT_RX_LAYOUT_UNSUPPORTED):
        return {**timestamp_fields, **channel_fields, **invalid_rx_fields}
    if event_type != cbladerf.BLADERF_RF_EVT_RX_DATA_WITHHELD:
        # RF event enums can grow independently of this wrapper. An unknown
        # event must never leave sample validity implicit for an older
        # consumer.
        return {**timestamp_fields, **channel_fields, **invalid_rx_fields,
                'event_type_unknown': True}
    reasons = {
        RF_WITHHELD_EPOCH_UNCERTIFIED: 'epoch_uncertified',
        RF_WITHHELD_EPOCH_OR_TIMESTAMP_MISMATCH: 'epoch_or_timestamp_mismatch',
        RF_WITHHELD_TIMESTAMP_DISCONTINUITY: 'timestamp_discontinuity',
        RF_WITHHELD_SHORT_TRANSFER: 'short_transfer',
        RF_WITHHELD_USB_OVERFLOW: 'usb_overflow',
        RF_WITHHELD_USB_TRANSFER_ERROR: 'usb_transfer_error',
        RF_WITHHELD_USB_TIMEOUT: 'usb_timeout',
        RF_WITHHELD_DEVICE_LOST: 'device_lost',
        RF_WITHHELD_SYNC_TIMEOUT: 'sync_timeout',
        RF_WITHHELD_RX_CHANNEL_SELECTION: 'rx_channel_selection',
    }
    reason = flags & ~(RF_EVENT_F_FPGA_TIMESTAMP_VALID |
                       cbladerf.BLADERF_RF_EVENT_F_RX_X2_LAYOUT |
                       cbladerf.BLADERF_RF_EVENT_F_TRANSITION_RX2 |
                       cbladerf.BLADERF_RF_EVENT_F_TRANSITION_CHANNEL_VALID)
    return {**timestamp_fields, **channel_fields, **invalid_rx_fields,
            'withheld_reason': reasons.get(reason, 'unknown')}

def _rf_event_notifications(events, history_complete: bool,
                            after_sequence: int, observed_sequence: int) -> list:
    """Add an explicit notification when the bounded native event ring lost
    entries. Callbacks must learn that their RF state history is incomplete;
    a side-channel error list alone is too easy for consumers to miss."""
    notifications = []
    if not history_complete:
        notifications.append({
            'host_monotonic_ns': None,
            'fpga_timestamp': None,
            'transaction_id': 0,
            'epoch_id': 0,
            'requested_rx_lo_hz': None,
            'readback_rx_lo_hz': None,
            'rfic_status': 0,
            'fpga_state': None,
            'event_type': None,
            'event_name': 'rf_event_history_lost',
            'flags': 0,
            'error_code': None,
            # A missing event may have revoked the last certificate. The
            # wrapper cannot infer validity from an incomplete history.
            'iq_valid': False,
            'affected_rx_channels': ['RX1', 'RX2'],
            'history_complete': False,
            'after_sequence': int(after_sequence),
            'observed_through_sequence': int(observed_sequence),
        })
    notifications.extend(events)
    return notifications


def _correlate_rx_invalidation_channel(events: list) -> list:
    """Attach an adjacent channel-context event to its invalidation record.

    C appends the reason event and this companion under one event-ring lock.
    If a cursor starts between them, the context event still carries its own
    epoch and channel; no inference is made for the missing reason.
    """
    for previous, current in zip(events, events[1:]):
        if (previous['event_name'] == 'rx_data_invalidated' and
                current['event_name'] == 'rx_invalidation_channel' and
                previous['epoch_id'] == current['epoch_id'] and
                previous['host_monotonic_ns'] == current['host_monotonic_ns'] and
                'transition_channel' in current):
            previous['transition_channel'] = current['transition_channel']
    return events


def _deliver_rf_event(callbacks, callback_errors, event) -> None:
    for callback in list(callbacks):
        try:
            callback(event)
        except Exception as exc:
            callback_errors.append({'event': event, 'error': repr(exc)})


def _dispatch_rf_event_batch(callbacks, callback_errors, result,
                             previous_cursor: int) -> list:
    if not result['history_complete']:
        callback_errors.append(
            {'error': 'RF event history overrun', 'history_complete': False})
    notifications = _rf_event_notifications(
        result['events'], result['history_complete'], previous_cursor,
        result['next_sequence'])
    for event in notifications:
        _deliver_rf_event(callbacks, callback_errors, event)
    return notifications


def _rx_data_withheld_notification() -> dict:
    """Describe an async RX callback where libbladeRF withheld all IQ."""
    return {
        'host_monotonic_ns': None,
        'fpga_timestamp': None,
        'transaction_id': 0,
        'epoch_id': 0,
        'requested_rx_lo_hz': None,
        'readback_rx_lo_hz': None,
        'rfic_status': 0,
        'fpga_state': None,
        'event_type': None,
        'event_name': 'rx_data_withheld',
        'flags': 0,
        'error_code': None,
        'iq_valid': False,
        'affected_rx_channels': ['RX1', 'RX2'],
    }


def _dispatch_rx_data_withheld(callbacks, callback_errors,
                               already_withheld: bool) -> bool:
    if not callbacks or already_withheld:
        return already_withheld
    _deliver_rf_event(callbacks, callback_errors,
                      _rx_data_withheld_notification())
    return True


def _rf_event_name(event_type: int) -> str:
    if event_type == cbladerf.BLADERF_RF_EVT_RX_FIRST_VALID_HOST_DATA:
        return 'rx_first_valid_host_data'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_DATA_RESUMED:
        return 'rx_data_resumed'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_BBPLL_LOCKED:
        return 'rx_bbpll_locked'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_EPOCH_VALID:
        return 'rx_epoch_valid'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_DATA_INVALIDATED:
        return 'rx_data_invalidated'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_STREAM_OVERRUN:
        return 'rx_stream_overrun'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_FORMAT_UNSUPPORTED:
        return 'rx_format_unsupported'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_LAYOUT_UNSUPPORTED:
        return 'rx_layout_unsupported'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_INVALIDATION_CHANNEL:
        return 'rx_invalidation_channel'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_CAPTURE_CLOSED:
        return 'rx_capture_closed'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_DATA_WITHHELD:
        return 'rx_data_withheld'
    if event_type == cbladerf.BLADERF_RF_EVT_RX_EPOCH_ABORT_FAILED:
        return 'rx_epoch_abort_failed'
    return 'rf_transition'


def PYBLADERF_CHANNEL_RX(channel: int) -> int:
    return (((channel) << 1) | 0x0)

def PYBLADERF_CHANNEL_TX(channel: int) -> int:
    return (((channel) << 1) | 0x1)

def PYBLADERF_CHANNEL_IS_TX(channel: int) -> bool:
    return bool(channel & 1)

def PYBLADERF_CHANNEL_IS_RX(channel: int) -> bool:
    return not (channel & 1)

PYBLADERF_CHANNEL_INVALID = -1
PYBLADERF_DIRECTION_MASK = 0x1

PYBLADERF_RETUNE_NOW = <uint64_t> 0

PYBLADERF_META_STATUS_OVERRUN = (1 << 0)
PYBLADERF_META_STATUS_UNDERRUN = (1 << 1)
PYBLADERF_META_FLAG_TX_BURST_START = (1 << 0)
PYBLADERF_META_FLAG_TX_BURST_END = (1 << 1)
PYBLADERF_META_FLAG_TX_NOW = (1 << 2)
PYBLADERF_META_FLAG_TX_UPDATE_TIMESTAMP = (1 << 3)
PYBLADERF_META_FLAG_RX_NOW = (1 << 31)
PYBLADERF_META_FLAG_RX_HW_UNDERFLOW = (1 << 0)
PYBLADERF_META_FLAG_RX_HW_MINIEXP1 = (1 << 16)
PYBLADERF_META_FLAG_RX_HW_MINIEXP2 = (1 << 17)

cdef void *PYBLADERF_STREAM_SHUTDOWN = <void*> NULL
cdef void *PYBLADERF_STREAM_NO_DATA = <void*> cbladerf.BLADERF_STREAM_NO_DATA
cdef void *PYBLADERF_STREAM_REUSE_BUFFER = <void*> cbladerf.BLADERF_STREAM_REUSE_BUFFER

PYBLADERF_TRIGGER_REG_ARM = <uint8_t> (1 << 0)
PYBLADERF_TRIGGER_REG_FIRE = <uint8_t> (1 << 1)
PYBLADERF_TRIGGER_REG_MASTER = <uint8_t> (1 << 2)
PYBLADERF_TRIGGER_REG_LINE = <uint8_t> (1 << 3)

cdef int PYMETADATA_TIMESTAMP_SIZE = sizeof(uint64_t)
cdef int PYMETADATA_FLAGS_SIZE = sizeof(uint32_t)
cdef int PYMETADATA_TIMESTAMP_OFFSET = sizeof(uint32_t)
cdef int PYMETADATA_FLAGS_OFFSET = PYMETADATA_TIMESTAMP_OFFSET + PYMETADATA_TIMESTAMP_SIZE
cdef int PYMETADATA_HEADER_SIZE = PYMETADATA_FLAGS_OFFSET + PYMETADATA_FLAGS_SIZE
cdef int USB_PACKAGE_SIZE_SS = 2048
cdef int USB_PACKAGE_SIZE_HS = 1024

# ---- ERROR ---- #
class PYBLADERF_ERR(Exception):
    def __init__(self, message, code):
        super().__init__(message + f' failed: {cbladerf.bladerf_strerror(code).decode("utf-8")} ({code})')
        self.code = code

class PYBLADERF_ERR_UNEXPECTED(PYBLADERF_ERR):
    '''An unexpected failure occurred'''

class PYBLADERF_ERR_RANGE(PYBLADERF_ERR):
    '''Provided parameter is out of range'''

class PYBLADERF_ERR_INVAL(PYBLADERF_ERR):
    '''Invalid operation/parameter'''

class PYBLADERF_ERR_MEM(PYBLADERF_ERR):
    '''Memory allocation error'''

class PYBLADERF_ERR_IO(PYBLADERF_ERR):
    '''File/Device I/O error'''

class PYBLADERF_ERR_TIMEOUT(PYBLADERF_ERR):
    '''Operation timed out'''

class PYBLADERF_ERR_NODEV(PYBLADERF_ERR):
    '''No device(s) available'''

class PYBLADERF_ERR_UNSUPPORTED(PYBLADERF_ERR):
    '''Operation not supported'''

class PYBLADERF_ERR_MISALIGNED(PYBLADERF_ERR):
    '''Misaligned flash access'''

class PYBLADERF_ERR_CHECKSUM(PYBLADERF_ERR):
    '''Invalid checksum'''

class PYBLADERF_ERR_NO_FILE(PYBLADERF_ERR):
    '''File not found'''

class PYBLADERF_ERR_UPDATE_FPGA(PYBLADERF_ERR):
    '''An FPGA update is required'''

class PYBLADERF_ERR_UPDATE_FW(PYBLADERF_ERR):
    '''A firmware update is requied'''

class PYBLADERF_ERR_TIME_PAST(PYBLADERF_ERR):
    '''Requested timestamp is in the past'''

class PYBLADERF_ERR_QUEUE_FULL(PYBLADERF_ERR):
    '''Could not enqueue data into full queue'''

class PYBLADERF_ERR_FPGA_OP(PYBLADERF_ERR):
    '''An FPGA operation reported failure'''

class PYBLADERF_ERR_PERMISSION(PYBLADERF_ERR):
    '''Insufficient permissions for the requested operation'''

class PYBLADERF_ERR_WOULD_BLOCK(PYBLADERF_ERR):
    '''Operation would block, but has been requested to be non-blocking. This indicates to a caller that it may need to retry the operation later'''

class PYBLADERF_ERR_NOT_INIT(PYBLADERF_ERR):
    '''Device insufficiently initialized for operation'''

cdef dict PYBLADERF_ERROR_MAP = {
    -1: PYBLADERF_ERR_UNEXPECTED,
    -2: PYBLADERF_ERR_RANGE,
    -3: PYBLADERF_ERR_INVAL,
    -4: PYBLADERF_ERR_MEM,
    -5: PYBLADERF_ERR_IO,
    -6: PYBLADERF_ERR_TIMEOUT,
    -7: PYBLADERF_ERR_NODEV,
    -8: PYBLADERF_ERR_UNSUPPORTED,
    -9: PYBLADERF_ERR_MISALIGNED,
    -10: PYBLADERF_ERR_CHECKSUM,
    -11: PYBLADERF_ERR_NO_FILE,
    -12: PYBLADERF_ERR_UPDATE_FPGA,
    -13: PYBLADERF_ERR_UPDATE_FW,
    -14: PYBLADERF_ERR_TIME_PAST,
    -15: PYBLADERF_ERR_QUEUE_FULL,
    -16: PYBLADERF_ERR_FPGA_OP,
    -17: PYBLADERF_ERR_PERMISSION,
    -18: PYBLADERF_ERR_WOULD_BLOCK,
    -19: PYBLADERF_ERR_NOT_INIT,
}

def raise_error(message: str, err: int) -> None:
    if err < 0:
        error_class = PYBLADERF_ERROR_MAP.get(err, PYBLADERF_ERR)
        raise error_class(message, err)

def _dispatch_rf_events_then_raise(device, message: str, err: int) -> None:
    """Deliver invalidation events before exposing a native setter failure."""
    device.pybladerf_dispatch_rf_events()
    raise_error(message, err)

# ---- ENUM ---- #
class pybladerf_backend(IntEnum):
    PYBLADERF_BACKEND_ANY = cbladerf.BLADERF_BACKEND_ANY
    PYBLADERF_BACKEND_LINUX = cbladerf.BLADERF_BACKEND_LINUX
    PYBLADERF_BACKEND_LIBUSB = cbladerf.BLADERF_BACKEND_LIBUSB
    PYBLADERF_BACKEND_CYPRESS = cbladerf.BLADERF_BACKEND_CYPRESS
    PYBLADERF_BACKEND_DUMMY = cbladerf.BLADERF_BACKEND_DUMMY

    def __str__(self) -> str:
        return self.name

class pybladerf_fpga_size(IntEnum):
    PYBLADERF_FPGA_UNKNOWN = cbladerf.BLADERF_FPGA_UNKNOWN
    PYBLADERF_FPGA_40KLE = cbladerf.BLADERF_FPGA_40KLE
    PYBLADERF_FPGA_115KLE = cbladerf.BLADERF_FPGA_115KLE
    PYBLADERF_FPGA_A4 = cbladerf.BLADERF_FPGA_A4
    PYBLADERF_FPGA_A5 = cbladerf.BLADERF_FPGA_A5
    PYBLADERF_FPGA_A9 = cbladerf.BLADERF_FPGA_A9

    def __str__(self) -> str:
        return self.name

class pybladerf_dev_speed(IntEnum):
    PYBLADERF_DEVICE_SPEED_UNKNOWN = cbladerf.BLADERF_DEVICE_SPEED_UNKNOWN
    PYBLADERF_DEVICE_SPEED_HIGH = cbladerf.BLADERF_DEVICE_SPEED_HIGH
    PYBLADERF_DEVICE_SPEED_SUPER = cbladerf.BLADERF_DEVICE_SPEED_SUPER

    def __str__(self) -> str:
        if self.value == pybladerf_dev_speed.PYBLADERF_DEVICE_SPEED_HIGH:
            return 'HighSpeed'
        elif self.value == pybladerf_dev_speed.PYBLADERF_DEVICE_SPEED_SUPER:
            return 'SuperSpeed'
        else:
            return 'Unknown'

class pybladerf_fpga_source(IntEnum):
    PYBLADERF_FPGA_SOURCE_UNKNOWN = cbladerf.BLADERF_FPGA_SOURCE_UNKNOWN
    PYBLADERF_FPGA_SOURCE_FLASH = cbladerf.BLADERF_FPGA_SOURCE_FLASH
    PYBLADERF_FPGA_SOURCE_HOST = cbladerf.BLADERF_FPGA_SOURCE_HOST

    def __str__(self) -> str:
        return self.name

class pybladerf_direction(IntEnum):
    PYBLADERF_RX = cbladerf.BLADERF_RX
    PYBLADERF_TX = cbladerf.BLADERF_TX

    def __str__(self) -> str:
        return self.name

class pybladerf_channel_layout(IntEnum):
    PYBLADERF_RX_X1 = cbladerf.BLADERF_RX_X1
    PYBLADERF_TX_X1 = cbladerf.BLADERF_TX_X1
    PYBLADERF_RX_X2 = cbladerf.BLADERF_RX_X2
    PYBLADERF_TX_X2 = cbladerf.BLADERF_TX_X2

    def __str__(self) -> str:
        return self.name

class pybladerf_gain_mode(IntEnum):
    PYBLADERF_GAIN_DEFAULT = cbladerf.BLADERF_GAIN_DEFAULT
    PYBLADERF_GAIN_MGC = cbladerf.BLADERF_GAIN_MGC
    PYBLADERF_GAIN_FASTATTACK_AGC = cbladerf.BLADERF_GAIN_FASTATTACK_AGC
    PYBLADERF_GAIN_SLOWATTACK_AGC = cbladerf.BLADERF_GAIN_SLOWATTACK_AGC
    PYBLADERF_GAIN_HYBRID_AGC = cbladerf.BLADERF_GAIN_HYBRID_AGC

    def __str__(self) -> str:
        return self.name

class pybladerf_loopback(IntEnum):
    PYBLADERF_LB_NONE = cbladerf.BLADERF_LB_NONE
    PYBLADERF_LB_FIRMWARE = cbladerf.BLADERF_LB_FIRMWARE
    PYBLADERF_LB_BB_TXLPF_RXVGA2 = cbladerf.BLADERF_LB_BB_TXLPF_RXVGA2
    PYBLADERF_LB_BB_TXVGA1_RXVGA2 = cbladerf.BLADERF_LB_BB_TXVGA1_RXVGA2
    PYBLADERF_LB_BB_TXLPF_RXLPF = cbladerf.BLADERF_LB_BB_TXLPF_RXLPF
    PYBLADERF_LB_BB_TXVGA1_RXLPF = cbladerf.BLADERF_LB_BB_TXVGA1_RXLPF
    PYBLADERF_LB_RF_LNA1 = cbladerf.BLADERF_LB_RF_LNA1
    PYBLADERF_LB_RF_LNA2 = cbladerf.BLADERF_LB_RF_LNA2
    PYBLADERF_LB_RF_LNA3 = cbladerf.BLADERF_LB_RF_LNA3
    PYBLADERF_LB_RFIC_BIST = cbladerf.BLADERF_LB_RFIC_BIST

    def __str__(self) -> str:
        return self.name

class pybladerf_trigger_role(IntEnum):
    PYBLADERF_TRIGGER_ROLE_INVALID = cbladerf.BLADERF_TRIGGER_ROLE_INVALID
    PYBLADERF_TRIGGER_ROLE_DISABLED = cbladerf.BLADERF_TRIGGER_ROLE_DISABLED
    PYBLADERF_TRIGGER_ROLE_MASTER = cbladerf.BLADERF_TRIGGER_ROLE_MASTER
    PYBLADERF_TRIGGER_ROLE_SLAVE = cbladerf.BLADERF_TRIGGER_ROLE_SLAVE

    def __str__(self) -> str:
        return self.name

class pybladerf_trigger_signal(IntEnum):
    PYBLADERF_TRIGGER_INVALID = cbladerf.BLADERF_TRIGGER_INVALID
    PYBLADERF_TRIGGER_J71_4 = cbladerf.BLADERF_TRIGGER_J71_4
    PYBLADERF_TRIGGER_J51_1 = cbladerf.BLADERF_TRIGGER_J51_1
    PYBLADERF_TRIGGER_MINI_EXP_1 = cbladerf.BLADERF_TRIGGER_MINI_EXP_1
    PYBLADERF_TRIGGER_USER_0 = cbladerf.BLADERF_TRIGGER_USER_0
    PYBLADERF_TRIGGER_USER_1 = cbladerf.BLADERF_TRIGGER_USER_1
    PYBLADERF_TRIGGER_USER_2 = cbladerf.BLADERF_TRIGGER_USER_2
    PYBLADERF_TRIGGER_USER_3 = cbladerf.BLADERF_TRIGGER_USER_3
    PYBLADERF_TRIGGER_USER_4 = cbladerf.BLADERF_TRIGGER_USER_4
    PYBLADERF_TRIGGER_USER_5 = cbladerf.BLADERF_TRIGGER_USER_5
    PYBLADERF_TRIGGER_USER_6 = cbladerf.BLADERF_TRIGGER_USER_6
    PYBLADERF_TRIGGER_USER_7 = cbladerf.BLADERF_TRIGGER_USER_7

    def __str__(self) -> str:
        return self.name

class pybladerf_rx_mux(IntEnum):
    PYBLADERF_RX_MUX_INVALID = cbladerf.BLADERF_RX_MUX_INVALID
    PYBLADERF_RX_MUX_BASEBAND = cbladerf.BLADERF_RX_MUX_BASEBAND
    PYBLADERF_RX_MUX_12BIT_COUNTER = cbladerf.BLADERF_RX_MUX_12BIT_COUNTER
    PYBLADERF_RX_MUX_32BIT_COUNTER = cbladerf.BLADERF_RX_MUX_32BIT_COUNTER
    PYBLADERF_RX_MUX_DIGITAL_LOOPBACK = cbladerf.BLADERF_RX_MUX_DIGITAL_LOOPBACK

    def __str__(self) -> str:
        return self.name

class pybladerf_stream_state(IntEnum):
    STREAM_IDLE = cbladerf.STREAM_IDLE
    STREAM_RUNNING = cbladerf.STREAM_RUNNING
    STREAM_SHUTTING_DOWN = cbladerf.STREAM_SHUTTING_DOWN
    STREAM_DONE = cbladerf.STREAM_DONE

    def __str__(self) -> str:
        return self.name

class pybladerf_correction(IntEnum):
    PYBLADERF_CORR_DCOFF_I = cbladerf.BLADERF_CORR_DCOFF_I
    PYBLADERF_CORR_DCOFF_Q = cbladerf.BLADERF_CORR_DCOFF_Q
    PYBLADERF_CORR_PHASE = cbladerf.BLADERF_CORR_PHASE
    PYBLADERF_CORR_GAIN = cbladerf.BLADERF_CORR_GAIN

    def __str__(self) -> str:
        return self.name

class pybladerf_format(IntEnum):
    PYBLADERF_FORMAT_SC16_Q11 = cbladerf.BLADERF_FORMAT_SC16_Q11
    PYBLADERF_FORMAT_SC16_Q11_META = cbladerf.BLADERF_FORMAT_SC16_Q11_META
    PYBLADERF_FORMAT_SC8_Q7 = cbladerf.BLADERF_FORMAT_SC8_Q7
    PYBLADERF_FORMAT_SC8_Q7_META = cbladerf.BLADERF_FORMAT_SC8_Q7_META

    def __str__(self) -> str:
        return self.name

class pybladerf_vctcxo_tamer_mode(IntEnum):
    PYBLADERF_VCTCXO_TAMER_INVALID = cbladerf.BLADERF_VCTCXO_TAMER_INVALID
    PYBLADERF_VCTCXO_TAMER_DISABLED = cbladerf.BLADERF_VCTCXO_TAMER_DISABLED
    PYBLADERF_VCTCXO_TAMER_1_PPS = cbladerf.BLADERF_VCTCXO_TAMER_1_PPS
    PYBLADERF_VCTCXO_TAMER_10_MHZ = cbladerf.BLADERF_VCTCXO_TAMER_10_MHZ

    def __str__(self) -> str:
        return self.name

class pybladerf_tuning_mode(IntEnum):
    PYBLADERF_TUNING_MODE_INVALID = cbladerf.BLADERF_TUNING_MODE_INVALID
    PYBLADERF_TUNING_MODE_HOST = cbladerf.BLADERF_TUNING_MODE_HOST
    PYBLADERF_TUNING_MODE_FPGA = cbladerf.BLADERF_TUNING_MODE_FPGA

    def __str__(self) -> str:
        return self.name

class pybladerf_feature(IntEnum):
    PYBLADERF_FEATURE_DEFAULT = cbladerf.BLADERF_FEATURE_DEFAULT
    PYBLADERF_FEATURE_OVERSAMPLE = cbladerf.BLADERF_FEATURE_OVERSAMPLE

    def __str__(self) -> str:
        return self.name

class pybladerf_log_level(IntEnum):
    PYBLADERF_LOG_LEVEL_VERBOSE = cbladerf.BLADERF_LOG_LEVEL_VERBOSE
    PYBLADERF_LOG_LEVEL_DEBUG = cbladerf.BLADERF_LOG_LEVEL_DEBUG
    PYBLADERF_LOG_LEVEL_INFO = cbladerf.BLADERF_LOG_LEVEL_INFO
    PYBLADERF_LOG_LEVEL_WARNING = cbladerf.BLADERF_LOG_LEVEL_WARNING
    PYBLADERF_LOG_LEVEL_ERROR = cbladerf.BLADERF_LOG_LEVEL_ERROR
    PYBLADERF_LOG_LEVEL_CRITICAL = cbladerf.BLADERF_LOG_LEVEL_CRITICAL
    PYBLADERF_LOG_LEVEL_SILENT = cbladerf.BLADERF_LOG_LEVEL_SILENT

    def __str__(self) -> str:
        return self.name

class pybladerf_rfic_rxfir(IntEnum):
    PYBLADERF_RFIC_RXFIR_BYPASS = cbladerf.BLADERF_RFIC_RXFIR_BYPASS
    PYBLADERF_RFIC_RXFIR_CUSTOM = cbladerf.BLADERF_RFIC_RXFIR_CUSTOM
    PYBLADERF_RFIC_RXFIR_DEC1 = cbladerf.BLADERF_RFIC_RXFIR_DEC1
    PYBLADERF_RFIC_RXFIR_DEC2 = cbladerf.BLADERF_RFIC_RXFIR_DEC2
    PYBLADERF_RFIC_RXFIR_DEC4 = cbladerf.BLADERF_RFIC_RXFIR_DEC4

    def __str__(self) -> str:
        return self.name

class pybladerf_rfic_txfir(IntEnum):
    PYBLADERF_RFIC_TXFIR_BYPASS = cbladerf.BLADERF_RFIC_TXFIR_BYPASS
    PYBLADERF_RFIC_TXFIR_CUSTOM = cbladerf.BLADERF_RFIC_TXFIR_CUSTOM
    PYBLADERF_RFIC_TXFIR_INT1 = cbladerf.BLADERF_RFIC_TXFIR_INT1
    PYBLADERF_RFIC_TXFIR_INT2 = cbladerf.BLADERF_RFIC_TXFIR_INT2
    PYBLADERF_RFIC_TXFIR_INT4 = cbladerf.BLADERF_RFIC_TXFIR_INT4

    def __str__(self) -> str:
        return self.name

class pybladerf_power_sources(IntEnum):
    PYBLADERF_UNKNOWN = cbladerf.BLADERF_UNKNOWN
    PYBLADERF_PS_DC = cbladerf.BLADERF_PS_DC
    PYBLADERF_PS_USB_VBUS = cbladerf.BLADERF_PS_USB_VBUS

    def __str__(self) -> str:
        return self.name

class pybladerf_clock_select(IntEnum):
    PYCLOCK_SELECT_ONBOARD = cbladerf.CLOCK_SELECT_ONBOARD
    PYCLOCK_SELECT_EXTERNAL = cbladerf.CLOCK_SELECT_EXTERNAL

    def __str__(self) -> str:
        return self.name

class pybladerf_pmic_register(IntEnum):
    PYBLADERF_PMIC_CONFIGURATION = cbladerf.BLADERF_PMIC_CONFIGURATION
    PYBLADERF_PMIC_VOLTAGE_SHUNT = cbladerf.BLADERF_PMIC_VOLTAGE_SHUNT
    PYBLADERF_PMIC_VOLTAGE_BUS = cbladerf.BLADERF_PMIC_VOLTAGE_BUS
    PYBLADERF_PMIC_POWER = cbladerf.BLADERF_PMIC_POWER
    PYBLADERF_PMIC_CURRENT = cbladerf.BLADERF_PMIC_CURRENT
    PYBLADERF_PMIC_CALIBRATION = cbladerf.BLADERF_PMIC_CALIBRATION

    def __str__(self) -> str:
        return self.name

class pybladerf_sweep_style(IntEnum):
    PYBLADERF_SWEEP_STYLE_LINEAR = 0
    PYBLADERF_SWEEP_STYLE_INTERLEAVED = 1

    def __str__(self) -> str:
        return self.name

# ---- STRUCT ---- #
cdef class pybladerf_devinfo:

    def __init__(self,
                 backend: pybladerf_backend = pybladerf_backend.PYBLADERF_BACKEND_ANY,
                 serial: str = 'ANY',
                 usb_bus: int = 255,
                 usb_addr: int = 255,
                 instance: int = 4294967295,
                 manufacturer: str = 'unknown',
                 product: str = 'unknown') -> None:

        self.__bladerf_devinfo = <cbladerf.bladerf_devinfo*> malloc(sizeof(cbladerf.bladerf_devinfo))
        memset(self.__bladerf_devinfo.serial, 0, cbladerf.BLADERF_SERIAL_LENGTH)
        memset(self.__bladerf_devinfo.product, 0, cbladerf.BLADERF_DESCRIPTION_LENGTH)
        memset(self.__bladerf_devinfo.manufacturer, 0, cbladerf.BLADERF_DESCRIPTION_LENGTH)

        self.backend = backend
        self.serial = serial
        self.usb_bus = usb_bus
        self.usb_addr = usb_addr
        self.instance = instance
        self.manufacturer = manufacturer
        self.product = product

    def __dealloc__(self):
        if self.__bladerf_devinfo != NULL:
            free(self.__bladerf_devinfo)

    def __str__(self) -> str:
        if self.__bladerf_devinfo != NULL:
            return f'{cbladerf.bladerf_backend_str(self.backend).decode("utf-8")}:device={self.usb_bus}:{self.usb_addr} instance={self.instance} serial={self.serial}'
        return ''

    property backend:
        def __get__(self) -> pybladerf_backend:
            if self.__bladerf_devinfo != NULL:
                return pybladerf_backend(self.__bladerf_devinfo[0].backend)

        def __set__(self, value: pybladerf_backend | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                self.__bladerf_devinfo[0].backend = value

    property serial:
        def __get__(self) -> str:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].serial.decode('utf-8')

        def __set__(self, value: str | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                strncpy(self.__bladerf_devinfo[0].serial, value.encode('utf-8'), cbladerf.BLADERF_SERIAL_LENGTH - 1)

    property usb_bus:
        def __get__(self) -> int:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].usb_bus

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                self.__bladerf_devinfo[0].usb_bus = <uint8_t> value

    property usb_addr:
        def __get__(self) -> int:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].usb_addr

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                self.__bladerf_devinfo[0].usb_addr = <uint8_t> value

    property instance:
        def __get__(self) -> int:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].instance

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                self.__bladerf_devinfo[0].instance = <unsigned int> value

    property manufacturer:
        def __get__(self) -> str:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].manufacturer.decode('utf-8')

        def __set__(self, value: str | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                strncpy(self.__bladerf_devinfo[0].manufacturer, value.encode('utf-8'), cbladerf.BLADERF_DESCRIPTION_LENGTH - 1)

    property product:
        def __get__(self) -> str:
            if self.__bladerf_devinfo != NULL:
                return self.__bladerf_devinfo[0].product.decode('utf-8')

        def __set__(self, value: str | None) -> None:
            if value is not None and self.__bladerf_devinfo != NULL:
                strncpy(self.__bladerf_devinfo[0].product, value.encode('utf-8'), cbladerf.BLADERF_DESCRIPTION_LENGTH - 1)

    cdef cbladerf.bladerf_devinfo *get_ptr(self):
        return self.__bladerf_devinfo

    cdef cbladerf.bladerf_devinfo **get_double_ptr(self):
        return &self.__bladerf_devinfo

cdef class pybladerf_version:

    def __init__(self,
                 major: int | None = None,
                 minor: int | None = None,
                 patch: int | None = None,
                 describe: str | None = None) -> None:

        self.__bladerf_version = <cbladerf.bladerf_version*> malloc(sizeof(cbladerf.bladerf_version))

        self.major = major
        self.minor = minor
        self.patch = patch
        self.describe = describe

    def __dealloc__(self):
        if self.__bladerf_version != NULL:
            free(self.__bladerf_version)

    def __str__(self) -> str:
        if self.__bladerf_version != NULL:
            return f'{self.major}.{self.minor}.{self.patch} \"{self.describe}\"'
        return ''

    property major:
        def __get__(self) -> int:
            if self.__bladerf_version != NULL:
                return self.__bladerf_version[0].major

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_version != NULL:
                self.__bladerf_version[0].major = <uint16_t> value

    property minor:
        def __get__(self) -> int:
            if self.__bladerf_version != NULL:
                return self.__bladerf_version[0].minor

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_version != NULL:
                self.__bladerf_version[0].minor = <uint16_t> value

    property patch:
        def __get__(self) -> int:
            if self.__bladerf_version != NULL:
                return self.__bladerf_version[0].patch

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_version != NULL:
                self.__bladerf_version[0].patch = <uint16_t> value

    property describe:
        def __get__(self) -> str:
            if self.__bladerf_version != NULL:
                return self.__bladerf_version[0].describe.decode('utf-8')

        def __set__(self, value: str | None) -> None:
            if value is not None and self.__bladerf_version != NULL:
                encoded_value = value.encode('utf-8')
                self.__bladerf_version[0].describe = encoded_value

    cdef cbladerf.bladerf_version *get_ptr(self):
        return self.__bladerf_version

    cdef cbladerf.bladerf_version **get_double_ptr(self):
        return &self.__bladerf_version

cdef class pybladerf_trigger:

    def __init__(self,
                   channel: int | None = None,
                   role: pybladerf_trigger_role | None = None,
                   signal: pybladerf_trigger_signal | None = None,
                   options: int | None = None) -> None:

        self.__bladerf_trigger = <cbladerf.bladerf_trigger*> malloc(sizeof(cbladerf.bladerf_trigger))

        self.channel = channel
        self.role = role
        self.signal = signal
        self.options = options

    def __dealloc__(self):
        if self.__bladerf_trigger != NULL:
            free(self.__bladerf_trigger)

    def __str__(self) -> str:
        if self.__bladerf_trigger != NULL:
            return f'channel:{self.channel} role:{self.role} signal:{self.signal} options:{self.options}'
        return ''

    property channel:
        def __get__(self) -> int:
            if self.__bladerf_trigger != NULL:
                return self.__bladerf_trigger[0].channel

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_trigger != NULL:
                self.__bladerf_trigger[0].channel = value

    property role:
        def __get__(self) -> pybladerf_trigger_role:
            if self.__bladerf_trigger != NULL:
                return pybladerf_trigger_role(self.__bladerf_trigger[0].role)

        def __set__(self, value: pybladerf_trigger_role | None) -> None:
            if value is not None and self.__bladerf_trigger != NULL:
                self.__bladerf_trigger[0].role = value

    property signal:
        def __get__(self) -> pybladerf_trigger_signal:
            if self.__bladerf_trigger != NULL:
                return pybladerf_trigger_signal(self.__bladerf_trigger[0].signal)

        def __set__(self, value: pybladerf_trigger_signal | None) -> None:
            if value is not None and self.__bladerf_trigger != NULL:
                self.__bladerf_trigger[0].signal = value

    property options:
        def __get__(self) -> int:
            if self.__bladerf_trigger != NULL:
                return self.__bladerf_trigger[0].options

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_trigger != NULL:
                self.__bladerf_trigger[0].options = <uint64_t> value

    cdef cbladerf.bladerf_trigger *get_ptr(self):
        return self.__bladerf_trigger

    cdef cbladerf.bladerf_trigger **get_double_ptr(self):
        return &self.__bladerf_trigger

cdef class pybladerf_quick_tune:

    def __init__(self,
                 freqsel: int | None = None,
                 vcocap: int | None = None,
                 nint: int | None = None,
                 nfrac: int | None = None,
                 flags: int | None = None,
                 xb_gpio: int | None = None,
                 nios_profile: int | None = None,
                 rffe_profile: int | None = None,
                 port: int | None = None,
                 spdt: int | None = None) -> None:

        self.__bladerf_quick_tune = <cbladerf.bladerf_quick_tune*> malloc(sizeof(cbladerf.bladerf_quick_tune))

        self.freqsel = freqsel
        self.vcocap = vcocap
        self.nint = nint
        self.nfrac = nfrac
        self.flags = flags
        self.xb_gpio = xb_gpio
        self.nios_profile = nios_profile
        self.rffe_profile = rffe_profile
        self.port = port
        self.spdt = spdt

    def __dealloc__(self):
        if self.__bladerf_quick_tune != NULL:
            free(self.__bladerf_quick_tune)

    property freqsel:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].freqsel

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].freqsel = <uint8_t> value

    property vcocap:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].vcocap

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].vcocap = <uint8_t> value

    property nint:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].nint

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].nint = <uint16_t> value

    property nfrac:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].nfrac

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].nfrac = <uint32_t> value

    property flags:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].flags

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].flags = <uint8_t> value

    property xb_gpio:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].xb_gpio

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].xb_gpio = <uint8_t> value

    property nios_profile:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].nios_profile

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].nios_profile = <uint16_t> value

    property rffe_profile:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].rffe_profile

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].rffe_profile = <uint8_t> value

    property port:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].port = <uint8_t> value

    property spdt:
        def __get__(self) -> int:
            if self.__bladerf_quick_tune != NULL:
                return self.__bladerf_quick_tune[0].spdt

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_quick_tune != NULL:
                self.__bladerf_quick_tune[0].spdt = <uint8_t> value

    cdef cbladerf.bladerf_quick_tune *get_ptr(self):
        return self.__bladerf_quick_tune

    cdef cbladerf.bladerf_quick_tune **get_double_ptr(self):
        return &self.__bladerf_quick_tune

cdef class pybladerf_metadata:

    def __init__(self,
                 timestamp: int | None = None,
                 flags: int | None = None,
                 status: int | None = None,
                 actual_count: int | None = None) -> None:

        self.__bladerf_metadata = <cbladerf.bladerf_metadata*> malloc(sizeof(cbladerf.bladerf_metadata))
        if self.__bladerf_metadata != NULL:
            memset(self.__bladerf_metadata, 0, sizeof(cbladerf.bladerf_metadata))

        self.timestamp = timestamp
        self.flags = flags
        self.status = status
        self.actual_count = actual_count

    def __dealloc__(self):
        if self.__bladerf_metadata != NULL:
            free(self.__bladerf_metadata)

    def __str__(self) -> str:
        if self.__bladerf_metadata != NULL:
            return f'timestamp:{self.timestamp} flags:{self.flags} status:{self.status} actual_count:{self.actual_count}'
        return ''

    property timestamp:
        def __get__(self) -> int:
            if self.__bladerf_metadata != NULL:
                return self.__bladerf_metadata[0].timestamp

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_metadata != NULL:
                self.__bladerf_metadata[0].timestamp = <uint64_t> value

    property flags:
        def __get__(self) -> int:
            if self.__bladerf_metadata != NULL:
                return self.__bladerf_metadata[0].flags

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_metadata != NULL:
                    self.__bladerf_metadata[0].flags = <uint32_t> value

    property status:
        def __get__(self) -> int:
            if self.__bladerf_metadata != NULL:
                return self.__bladerf_metadata[0].status

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_metadata != NULL:
                self.__bladerf_metadata[0].status = <uint32_t> value

    property actual_count:
        def __get__(self) -> int:
            if self.__bladerf_metadata != NULL:
                return self.__bladerf_metadata[0].actual_count

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_metadata != NULL:
                self.__bladerf_metadata[0].actual_count = <unsigned int> value

    property rx_epoch_id:
        """FPGA RX epoch ID for epoch-tagged sample-META streams, or None."""
        def __get__(self) -> int | None:
            if (self.__bladerf_metadata != NULL and
                    self.__bladerf_metadata[0].rx_epoch_id_valid != 0):
                return self.__bladerf_metadata[0].rx_epoch_id
            return None

    cdef cbladerf.bladerf_metadata *get_ptr(self):
        return self.__bladerf_metadata

    cdef cbladerf.bladerf_metadata **get_double_ptr(self):
        return &self.__bladerf_metadata

cdef class pybladerf_rf_switch_config:

    def __init__(self,
                 tx1_rfic_port: int | None = None,
                 tx1_spdt_port: int | None = None,
                 tx2_rfic_port: int | None = None,
                 tx2_spdt_port: int | None = None,
                 rx1_rfic_port: int | None = None,
                 rx1_spdt_port: int | None = None,
                 rx2_rfic_port: int | None = None,
                 rx2_spdt_port: int | None = None) -> None:

        self.__bladerf_rf_switch_config = <cbladerf.bladerf_rf_switch_config*> malloc(sizeof(cbladerf.bladerf_rf_switch_config))

        self.tx1_rfic_port = tx1_rfic_port
        self.tx1_spdt_port = tx1_spdt_port
        self.tx2_rfic_port = tx2_rfic_port
        self.tx2_spdt_port = tx2_spdt_port
        self.rx1_rfic_port = rx1_rfic_port
        self.rx1_spdt_port = rx1_spdt_port
        self.rx2_rfic_port = rx2_rfic_port
        self.rx2_spdt_port = rx2_spdt_port

    def __dealloc__(self):
        if self.__bladerf_rf_switch_config != NULL:
            free(self.__bladerf_rf_switch_config)

    property tx1_rfic_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].tx1_rfic_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].tx1_rfic_port = <uint32_t> value

    property tx1_spdt_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].tx1_spdt_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].tx1_spdt_port = <uint32_t> value

    property tx2_rfic_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].tx2_rfic_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].tx2_rfic_port = <uint32_t> value

    property tx2_spdt_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].tx2_spdt_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].tx2_spdt_port = <uint32_t> value

    property rx1_rfic_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].rx1_rfic_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].rx1_rfic_port = <uint32_t> value

    property rx1_spdt_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].rx1_spdt_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].rx1_spdt_port = <uint32_t> value

    property rx2_rfic_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].rx2_rfic_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].rx2_rfic_port = <uint32_t> value

    property rx2_spdt_port:
        def __get__(self) -> int:
            if self.__bladerf_rf_switch_config != NULL:
                return self.__bladerf_rf_switch_config[0].rx2_spdt_port

        def __set__(self, value: int | None) -> None:
            if value is not None and self.__bladerf_rf_switch_config != NULL:
                self.__bladerf_rf_switch_config[0].rx2_spdt_port = <uint32_t> value

    cdef cbladerf.bladerf_rf_switch_config *get_ptr(self):
        return self.__bladerf_rf_switch_config

    cdef cbladerf.bladerf_rf_switch_config **get_double_ptr(self):
        return &self.__bladerf_rf_switch_config

# ---- READONLY STRUCT ---- #
cdef class pybladerf_range:

    def __str__(self) -> str:
        if self.__bladerf_range != NULL:
            return f'min:{self.min} max:{self.max} step:{self.step} scale:{round(self.scale, 10)}'
        return ''

    property min:
        def __get__(self) -> int:
            if self.__bladerf_range != NULL:
                return self.__bladerf_range[0].min

    property max:
        def __get__(self) -> int:
            if self.__bladerf_range != NULL:
                return self.__bladerf_range[0].max

    property step:
        def __get__(self) -> int:
            if self.__bladerf_range != NULL:
                return self.__bladerf_range[0].step

    property scale:
        def __get__(self) -> float:
            if self.__bladerf_range != NULL:
                return self.__bladerf_range[0].scale

    cdef const cbladerf.bladerf_range *get_ptr(self):
        return self.__bladerf_range

    cdef const cbladerf.bladerf_range **get_double_ptr(self):
        return &self.__bladerf_range

cdef class pybladerf_stream:

    def __init__(self) -> None:
        self.idx = 0

    property layout:
        def __get__(self) -> pybladerf_channel_layout:
            if self.__bladerf_stream != NULL:
                return pybladerf_channel_layout(<cbladerf.bladerf_channel_layout> self.__bladerf_stream.layout)

    property data_format:
        def __get__(self) -> pybladerf_format:
            if self.__bladerf_stream != NULL:
                return pybladerf_format(<cbladerf.bladerf_format> self.__bladerf_stream.format)

    property transfer_timeout:
        def __get__(self) -> int:
            if self.__bladerf_stream != NULL:
                return <unsigned int> self.__bladerf_stream.transfer_timeout

    property samples_per_buffer:
        def __get__(self) -> int:
            if self.__bladerf_stream != NULL:
                return <size_t> self.__bladerf_stream.samples_per_buffer

    property num_buffers:
        def __get__(self) -> int:
            if self.__bladerf_stream != NULL:
                return <size_t> self.__bladerf_stream.num_buffers

    property state:
        def __get__(self) -> pybladerf_stream_state:
            if self.__bladerf_stream != NULL:
                return pybladerf_stream_state(<size_t> self.__bladerf_stream.state)

    property error_code:
        def __get__(self) -> str:
            if self.__bladerf_stream != NULL:
                return cbladerf.bladerf_strerror(<size_t> self.__bladerf_stream.error_code).decode('utf-8')

    cdef pybladerf_async_data get_async_data(self):
        if self.__bladerf_stream != NULL:
            return (<pybladerf_async_data*> self.__bladerf_stream.user_data)[0]

    cdef void *get_next_buffer_ptr(self):
        self.idx = (self.idx + 1) % self.num_buffers
        return self.__bladerf_stream.buffers[self.idx]

    cdef cbladerf.bladerf_stream *get_ptr(self):
        return self.__bladerf_stream

    cdef cbladerf.bladerf_stream **get_double_ptr(self):
        return &self.__bladerf_stream

# ---- WRAPPER ---- #
IF ANDROID:
    cdef class PyBladeRFDeviceList:
        cdef list __bladerf_device_list

        def __cinit__(self):
            self.__bladerf_device_list = get_bladerf_device_list()

        property device_count:
            def __get__(self):
                return len(self.__bladerf_device_list)

        property devstrs:
            def __get__(self) -> list[str]:
                return [f'libusb:instance={self.__bladerf_device_list[i][0]} serial={self.__bladerf_device_list[i][1]}' for i in range(self.device_count)]

        property backends:
            def __get__(self) -> list[pybladerf_backend]:
                return ['libusb' for i in range(self.device_count)]

        property serial_numbers:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i][1] for i in range(self.device_count)]

        property usb_buses:
            def __get__(self) -> list[int]:
                return [255 for i in range(self.device_count)]

        property usb_addresses:
            def __get__(self) -> list[int]:
                return [255 for i in range(self.device_count)]

        property instances:
            def __get__(self) -> list[int]:
                return [self.__bladerf_device_list[i][0] for i in range(self.device_count)]

        property manufacturers:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i][2] for i in range(self.device_count)]

        property products:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i][3] for i in range(self.device_count)]
ELSE:
    cdef class PyBladeRFDeviceList:
        cdef cbladerf.bladerf_devinfo *__bladerf_device_list
        cdef int _device_count

        def __cinit__(self):
            self._device_count = cbladerf.bladerf_get_device_list(&self.__bladerf_device_list)

        def __dealloc__(self):
            if self.__bladerf_device_list != NULL:
                cbladerf.bladerf_free_device_list(self.__bladerf_device_list)

        property device_count:
            def __get__(self) -> int:
                if self.__bladerf_device_list != NULL:
                    return self._device_count
                return 0

        property devstrs:
            def __get__(self) -> list[str]:
                return [f'{cbladerf.bladerf_backend_str(self.__bladerf_device_list[i].backend).decode("utf-8")}:device={self.__bladerf_device_list[i].usb_bus}:{self.__bladerf_device_list[i].usb_addr} instance={self.__bladerf_device_list[i].instance} serial={self.__bladerf_device_list[i].serial.decode("utf-8")}' for i in range(self.device_count)]

        property backends:
            def __get__(self) -> list[pybladerf_backend]:
                return [pybladerf_backend(self.__bladerf_device_list[i].backend) for i in range(self.device_count)]

        property serial_numbers:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i].serial.decode('utf-8') for i in range(self.device_count)]

        property usb_buses:
            def __get__(self) -> list[int]:
                return [self.__bladerf_device_list[i].usb_bus for i in range(self.device_count)]

        property usb_addresses:
            def __get__(self) -> list[int]:
                return [self.__bladerf_device_list[i].usb_addr for i in range(self.device_count)]

        property instances:
            def __get__(self) -> list[int]:
                return [self.__bladerf_device_list[i].instance for i in range(self.device_count)]

        property manufacturers:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i].manufacturer.decode('utf-8') for i in range(self.device_count)]

        property products:
            def __get__(self) -> list[str]:
                return [self.__bladerf_device_list[i].product.decode('utf-8') for i in range(self.device_count)]

@cython.boundscheck(False)
@cython.wraparound(False)
def _make_rx_callback_metadata(timestamp, flags, status, actual_count,
                               rx_epoch_id_valid, rx_epoch_id, layout,
                               num_samples):
    """Copy native RX metadata into a Python-owned callback snapshot."""
    return {
        'timestamp': int(timestamp),
        'flags': int(flags),
        'status': int(status),
        'actual_count': int(actual_count),
        'rx_epoch_id': int(rx_epoch_id) if rx_epoch_id_valid else None,
        'rx_epoch_id_valid': bool(rx_epoch_id_valid),
        'layout': int(layout),
        'num_samples': int(num_samples),
    }


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void *__rx_callback_SC16_Q11(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *buffer_ptr = <uint8_t*> samples
    cdef uint8_t *np_buffer_ptr

    with gil:
        pystream = <pybladerf_stream> async_data.pystream
        device = global_callbacks[<size_t> dev]['device']
        # RX validity/overrun events are produced on the native async path.
        # Dispatch before any valid IQ reaches the Python consumer; a
        # zero-sample callback is an event-only wakeup for a rejected buffer.
        device.pybladerf_dispatch_rf_events()
        if num_samples == 0:
            device.pybladerf_dispatch_rx_data_withheld()
            return PYBLADERF_STREAM_REUSE_BUFFER
        device.pybladerf_mark_rx_data_delivered()

        np_buffer = np.empty(num_samples * 2, dtype=np.int16)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data

        memcpy(
            np_buffer_ptr,
            buffer_ptr,
            num_samples * async_data.bytes_per_sample,
        )

        # Keep streaming when no callback is installed. Without this default
        # `result` is never assigned, the read below raises UnboundLocalError
        # inside the callback, and the stream stops on its very first buffer
        # with state STREAM_DONE and no error reported to the caller.
        result = 0

        if global_callbacks[<size_t> dev]['__rx_callback_with_metadata'] is not None:
            result = global_callbacks[<size_t> dev]['__rx_callback_with_metadata'](
                global_callbacks[<size_t> dev]['device'], pystream, np_buffer,
                num_samples, _make_rx_callback_metadata(
                    meta[0].timestamp, meta[0].flags, meta[0].status,
                    meta[0].actual_count, meta[0].rx_epoch_id_valid,
                    meta[0].rx_epoch_id, int(pystream.layout), num_samples))
        elif global_callbacks[<size_t> dev]['__rx_callback'] is not None:
            result = global_callbacks[<size_t> dev]['__rx_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples)

        if result == 0:
            return pystream.get_next_buffer_ptr()

        return PYBLADERF_STREAM_SHUTDOWN


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void *__rx_callback_SC8_Q7(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *buffer_ptr = <uint8_t*> samples
    cdef uint8_t *np_buffer_ptr

    with gil:
        pystream = <pybladerf_stream> async_data.pystream
        device = global_callbacks[<size_t> dev]['device']
        device.pybladerf_dispatch_rf_events()
        if num_samples == 0:
            device.pybladerf_dispatch_rx_data_withheld()
            return PYBLADERF_STREAM_REUSE_BUFFER
        device.pybladerf_mark_rx_data_delivered()

        np_buffer = np.empty(num_samples * 2, dtype=np.int8)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data

        memcpy(
            np_buffer_ptr,
            buffer_ptr,
            num_samples * async_data.bytes_per_sample,
        )

        # Keep streaming when no callback is installed. Without this default
        # `result` is never assigned, the read below raises UnboundLocalError
        # inside the callback, and the stream stops on its very first buffer
        # with state STREAM_DONE and no error reported to the caller.
        result = 0

        if global_callbacks[<size_t> dev]['__rx_callback_with_metadata'] is not None:
            result = global_callbacks[<size_t> dev]['__rx_callback_with_metadata'](
                global_callbacks[<size_t> dev]['device'], pystream, np_buffer,
                num_samples, _make_rx_callback_metadata(
                    meta[0].timestamp, meta[0].flags, meta[0].status,
                    meta[0].actual_count, meta[0].rx_epoch_id_valid,
                    meta[0].rx_epoch_id, int(pystream.layout), num_samples))
        elif global_callbacks[<size_t> dev]['__rx_callback'] is not None:
            result = global_callbacks[<size_t> dev]['__rx_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples)

        if result == 0:
            return pystream.get_next_buffer_ptr()

        return PYBLADERF_STREAM_SHUTDOWN


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void *__tx_callback_SC16_Q11(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *np_buffer_ptr
    cdef uint8_t *buffer_ptr
    cdef int valid_length
    cdef int result

    if samples != NULL:
        __tx_complete_callback_SC16_Q11(dev, stream, meta, samples, num_samples, user_data)

    with gil:
        pystream = <pybladerf_stream> async_data.pystream
        buffer_ptr = <uint8_t*> pystream.get_next_buffer_ptr()

        np_buffer = np.zeros(num_samples * 2, dtype=np.int16)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data
        valid_num_samples = c_int(num_samples)

        if global_callbacks[<size_t> dev]['__tx_callback'] is not None:
            result = global_callbacks[<size_t> dev]['__tx_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples, valid_num_samples)

        valid_length = valid_num_samples.value

    if result == 0:
        memcpy(
            buffer_ptr,
            np_buffer_ptr,
            valid_length * async_data.bytes_per_sample,
        )
        return <void*> buffer_ptr

    elif result == 1:
        return PYBLADERF_STREAM_NO_DATA

    return PYBLADERF_STREAM_SHUTDOWN


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void *__tx_callback_SC8_Q7(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *np_buffer_ptr
    cdef uint8_t *buffer_ptr
    cdef int valid_length
    cdef int result

    if samples != NULL:
        __tx_complete_callback_SC8_Q7(dev, stream, meta, samples, num_samples, user_data)

    with gil:
        pystream = <pybladerf_stream> async_data.pystream
        buffer_ptr = <uint8_t*> pystream.get_next_buffer_ptr()

        buffer_size = num_samples * 2
        np_buffer = np.zeros(buffer_size, dtype=np.int8)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data
        valid_num_samples = c_int(num_samples)

        if global_callbacks[<size_t> dev]['__tx_callback'] is not None:
            result = global_callbacks[<size_t> dev]['__tx_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples, valid_num_samples)

        valid_length = valid_num_samples.value

    if result == 0:
        memcpy(
            buffer_ptr,
            np_buffer_ptr,
            valid_length * async_data.bytes_per_sample,
        )
        return <void*> buffer_ptr

    elif result == 1:
        return PYBLADERF_STREAM_NO_DATA

    return PYBLADERF_STREAM_SHUTDOWN


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void __tx_complete_callback_SC16_Q11(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *buffer_ptr = <uint8_t*> samples
    cdef uint8_t *np_buffer_ptr

    with gil:
        pystream = <pybladerf_stream> async_data.pystream

        np_buffer = np.empty(num_samples * 2, dtype=np.int16)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data

        memcpy(
            np_buffer_ptr,
            buffer_ptr,
            num_samples * async_data.bytes_per_sample,
        )

        if global_callbacks[<size_t> dev]['__tx_complete_callback'] is not None and global_callbacks[<size_t> dev]['tx_complete_enabled']:
            global_callbacks[<size_t> dev]['__tx_complete_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void __tx_complete_callback_SC8_Q7(cbladerf.bladerf *dev, cbladerf.bladerf_stream *stream, cbladerf.bladerf_metadata *meta, void *samples, size_t num_samples, void *user_data) noexcept nogil:
    global global_callbacks
    cdef pybladerf_async_data *async_data = <pybladerf_async_data*> user_data
    cdef uint8_t *buffer_ptr = <uint8_t*> samples
    cdef uint8_t *np_buffer_ptr

    with gil:
        pystream = <pybladerf_stream> async_data.pystream

        np_buffer = np.empty(num_samples * 2, dtype=np.int8)
        np_buffer_ptr = <uint8_t*> <uintptr_t> np_buffer.ctypes.data

        memcpy(
            np_buffer_ptr,
            buffer_ptr,
            num_samples * async_data.bytes_per_sample,
        )

        if global_callbacks[<size_t> dev]['__tx_complete_callback'] is not None and global_callbacks[<size_t> dev]['tx_complete_enabled']:
            global_callbacks[<size_t> dev]['__tx_complete_callback'](global_callbacks[<size_t> dev]['device'], pystream, np_buffer, num_samples)


cdef class PyBladerfDevice:

    def __cinit__(self):
        self.__bladerf_device = NULL
        # Last sync_config() per direction (0 = RX, 1 = TX) and which
        # directions libbladeRF has torn down via enable_module(False).
        self.__sync_config = {}
        self.__sync_torn_down = set()
        self.__auto_reconfig = True
        self.__rf_event_callbacks = []
        self.__rf_event_callback_errors = []
        self.__rf_event_cursor = 0
        self.__rf_event_dispatching = False
        self.__rx_data_withheld = False
        self.__rf_event_dispatch_lock = threading.RLock()
        self.__rf_event_poll_stop = None
        self.__rf_event_poll_thread = None

    def __dealloc__(self):
        global global_callbacks

        if self.__bladerf_device != NULL:
            if <size_t> self.__bladerf_device in global_callbacks.keys():
                global_callbacks.pop(<size_t> self.__bladerf_device)

            cbladerf.bladerf_close(self.__bladerf_device)
            self.__bladerf_device = NULL

    # ---- inner functions ---- #
    cdef cbladerf.bladerf *get_ptr(self):
        return self.__bladerf_device

    cdef cbladerf.bladerf **get_double_ptr(self):
        return &self.__bladerf_device

    cdef void _setup_device(self):
        global global_callbacks

        if self.__bladerf_device is not NULL:
            self.serialno = self.pybladerf_get_serial()

            global_callbacks[<size_t> self.__bladerf_device] = {
                '__rx_callback': None,
                '__rx_callback_with_metadata': None,
                '__tx_callback': None,
                '__tx_complete_callback': None,
                'tx_complete_enabled': False,
                'device': self,
            }
            return

        raise RuntimeError(f'_setup_device() failed: Device not initialized!')

    # ---- device ---- #
    def pybladerf_close(self) -> None:
        global global_callbacks

        self.__stop_rf_event_poller()

        if self.__bladerf_device is not NULL:
            if <size_t> self.__bladerf_device in global_callbacks.keys():
                global_callbacks.pop(<size_t> self.__bladerf_device)

            cbladerf.bladerf_close(self.__bladerf_device)
            self.__bladerf_device = NULL

    def pybladerf_get_devinfo(self) -> pybladerf_devinfo:
        cdef pybladerf_devinfo info = pybladerf_devinfo()
        result = cbladerf.bladerf_get_devinfo(self.__bladerf_device, info.get_ptr())
        raise_error('pybladerf_get_devinfo()', result)
        return info

    cdef cbladerf.bladerf_backendinfo pybladerf_get_backendinfo(self):
        cdef cbladerf.bladerf_backendinfo info
        result = cbladerf.bladerf_get_backendinfo(self.__bladerf_device, &info)
        raise_error('pybladerf_get_backendinfo()', result)
        return info

    def pybladerf_get_serial(self) -> str:
        cdef cbladerf.bladerf_serial serial
        result = cbladerf.bladerf_get_serial_struct(self.__bladerf_device, &serial)
        raise_error('pybladerf_get_serial_struct()', result)
        return serial.serial.decode('utf-8')

    def pybladerf_get_fpga_size(self) -> pybladerf_fpga_size:
        cdef cbladerf.bladerf_fpga_size size
        result = cbladerf.bladerf_get_fpga_size(self.__bladerf_device, &size)
        raise_error('pybladerf_get_fpga_size()', result)
        return pybladerf_fpga_size(size)

    def pybladerf_get_fpga_bytes(self) -> int:
        cdef size_t size
        result = cbladerf.bladerf_get_fpga_bytes(self.__bladerf_device, &size)
        raise_error('pybladerf_get_fpga_bytes()', result)
        return size

    def pybladerf_get_flash_size(self) -> tuple[int, bool]:
        cdef uint32_t size
        cdef c_bool is_guess
        result = cbladerf.bladerf_get_flash_size(self.__bladerf_device, &size, &is_guess)
        raise_error('pybladerf_get_flash_size()', result)
        return size, is_guess

    def pybladerf_fw_version(self) -> pybladerf_version:
        cdef pybladerf_version version = pybladerf_version()
        result = cbladerf.bladerf_fw_version(self.__bladerf_device, version.get_ptr())
        raise_error('pybladerf_fw_version()', result)
        return version

    def pybladerf_is_fpga_configured(self) -> bool:
        result = cbladerf.bladerf_is_fpga_configured(self.__bladerf_device)
        raise_error('pybladerf_is_fpga_configured()', result)
        return result

    def pybladerf_fpga_version(self) -> pybladerf_version:
        cdef pybladerf_version version = pybladerf_version()
        result = cbladerf.bladerf_fpga_version(self.__bladerf_device, version.get_ptr())
        raise_error('pybladerf_fpga_version()', result)
        return version

    def pybladerf_get_fpga_source(self) -> pybladerf_fpga_source:
        cdef cbladerf.bladerf_fpga_source source
        result = cbladerf.bladerf_get_fpga_source(self.__bladerf_device, &source)
        raise_error('pybladerf_get_fpga_source()', result)
        return pybladerf_fpga_source(source)

    def pybladerf_device_speed(self) -> pybladerf_dev_speed:
        return pybladerf_dev_speed(cbladerf.bladerf_device_speed(self.__bladerf_device))

    def pybladerf_get_board_name(self) -> str:
        return cbladerf.bladerf_get_board_name(self.__bladerf_device).decode('utf-8')

    def pybladerf_get_channel_count(self, direction: pybladerf_direction) -> int:
        return cbladerf.bladerf_get_channel_count(self.__bladerf_device, direction)

    def pybladerf_set_gain(self, channel: int, gain: int) -> None:
        result = cbladerf.bladerf_set_gain(self.__bladerf_device, channel, gain)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_gain()', result)

    def pybladerf_add_rf_event_callback(self, callback) -> None:
        """Register an observer for all RF events, including IQ invalidation.

        Native history is polled on a daemon thread, so runtime events are
        delivered while another call such as ``sync_rx`` is blocked. Callback
        code can therefore run on this poller thread as well as on the thread
        that completes a wrapper API call or the async RX backend thread. RX
        callbacks run without libbladeRF's stream mutex, but still execute on
        the streaming thread: keep observers short, and do not deinitialize
        the active stream or close its device from the callback. Request
        stream shutdown via its callback return value and tear it down after
        the callback has returned.
        """
        if not callable(callback):
            raise TypeError('callback must be callable')
        with self.__rf_event_dispatch_lock:
            # Start at the current tail so registration never replays old events.
            tail = self.pybladerf_rf_events_since(self.__rf_event_cursor)
            self.__rf_event_cursor = tail['next_sequence']
            self.__rf_event_callbacks.append(callback)
            if self.__rf_event_poll_thread is None:
                stop_event = threading.Event()
                poller = threading.Thread(
                    target=_rf_event_poll_loop,
                    args=(stop_event, weakref.ref(self), 0.02),
                    name='bladeRF-rf-events',
                    daemon=True,
                )
                self.__rf_event_poll_stop = stop_event
                self.__rf_event_poll_thread = poller
                poller.start()

    def pybladerf_remove_rf_event_callback(self, callback) -> None:
        with self.__rf_event_dispatch_lock:
            self.__rf_event_callbacks.remove(callback)

    def __stop_rf_event_poller(self) -> None:
        stop_event = self.__rf_event_poll_stop
        poller = self.__rf_event_poll_thread
        if stop_event is not None:
            stop_event.set()
        if poller is not None and poller is not threading.current_thread():
            poller.join()
        self.__rf_event_poll_stop = None
        self.__rf_event_poll_thread = None

    def pybladerf_get_rf_event_callback_errors(self, clear: bool = False) -> list:
        errors = list(self.__rf_event_callback_errors)
        if clear:
            self.__rf_event_callback_errors.clear()
        return errors

    def _record_rf_event_poller_error(self, exc) -> None:
        notification = {
            'host_monotonic_ns': None,
            'fpga_timestamp': None,
            'transaction_id': 0,
            'epoch_id': 0,
            'requested_rx_lo_hz': None,
            'readback_rx_lo_hz': None,
            'rfic_status': 0,
            'fpga_state': None,
            'event_type': None,
            'event_name': 'rf_event_poller_error',
            'flags': 0,
            'error_code': None,
            'iq_valid': False,
            # A poll failure can hide a device-wide epoch invalidation.
            'affected_rx_channels': ['RX1', 'RX2'],
            'history_complete': False,
            'detail': repr(exc),
        }
        self.__rf_event_callback_errors.append({
            'error': 'RF event poller failed', 'detail': repr(exc)})
        with self.__rf_event_dispatch_lock:
            callbacks = tuple(self.__rf_event_callbacks)
        _deliver_rf_event(callbacks, self.__rf_event_callback_errors,
                          notification)

    def pybladerf_rf_events_since(self, after_sequence=None) -> dict:
        cdef cbladerf.bladerf_rf_event events[64]
        cdef uint32_t count = 0
        cdef uint64_t next_sequence = 0
        cdef cbladerf.c_bool complete = False
        cdef int result
        cdef list items = []
        cdef uint64_t cursor = self.__rf_event_cursor if after_sequence is None else after_sequence
        cdef cbladerf.bladerf_rf_event *event
        result = cbladerf.bladerf_rf_events_get_since(
            self.__bladerf_device, cursor, events, 64, &count,
            &next_sequence, &complete)
        if result != 0 and complete:
            raise_error('pybladerf_rf_events_since()', result)
        for i in range(count):
            event = &events[i]
            items.append({
                'host_monotonic_ns': event.host_monotonic_ns,
                'fpga_timestamp': event.fpga_timestamp,
                'transaction_id': event.transaction_id,
                'epoch_id': event.epoch_id,
                'requested_rx_lo_hz': event.requested_rx_lo_hz,
                'readback_rx_lo_hz': event.readback_rx_lo_hz,
                'rfic_status': event.rfic_status,
                'fpga_state': int(event.fpga_state),
                'event_type': int(event.event_type),
                'event_name': _rf_event_name(event.event_type),
                'flags': event.flags,
                'invalidation_reason': _rf_invalidation_reason(
                    event.event_type, event.flags),
                'error_code': event.error_code,
                **_rf_event_validity_fields(event.event_type, event.flags,
                                            event.rfic_status),
            })
        _correlate_rx_invalidation_channel(items)
        return {'events': items, 'next_sequence': next_sequence,
                'history_complete': bool(complete)}

    def pybladerf_dispatch_rf_events(self) -> None:
        # Do not consume the library's event history merely because an API
        # call completed. Without a subscriber, callers must still be able to
        # retrieve those events later with pybladerf_rf_events_since(); the
        # bounded C ring is the unconditional notification channel.
        if not self.__rf_event_callbacks:
            return
        # The RLock permits callbacks to use wrapper methods that may drain
        # events. Suppress that recursive drain so a newly appended event
        # cannot overtake the remainder of the current batch.
        if self.__rf_event_dispatching:
            return
        # If another thread is running user callback code, an API-completion
        # dispatch must not wait behind it. In particular, a blocked callback
        # may be waiting for a lock held by the thread returning from sync_rx.
        # The poller will drain any events left behind on its next pass.
        if not self.__rf_event_dispatch_lock.acquire(False):
            return
        self.__rf_event_dispatching = True
        try:
            previous_cursor = self.__rf_event_cursor
            result = self.pybladerf_rf_events_since()
            self.__rf_event_cursor = result['next_sequence']
            if any(event['event_name'] == 'rx_data_withheld'
                   for event in result['events']):
                # The native event is richer and durable; do not also synthesize
                # the generic event-only callback notice for the same withheld run.
                self.__rx_data_withheld = True
            _dispatch_rf_event_batch(self.__rf_event_callbacks,
                                     self.__rf_event_callback_errors, result,
                                     previous_cursor)
        finally:
            self.__rf_event_dispatching = False
            self.__rf_event_dispatch_lock.release()

    def pybladerf_dispatch_rx_data_withheld(self) -> None:
        self.__rx_data_withheld = _dispatch_rx_data_withheld(
            self.__rf_event_callbacks, self.__rf_event_callback_errors,
            self.__rx_data_withheld)

    def pybladerf_mark_rx_data_delivered(self) -> None:
        self.__rx_data_withheld = False

    def pybladerf_get_gain(self, channel: int) -> int:
        cdef int gain
        result = cbladerf.bladerf_get_gain(self.__bladerf_device, channel, &gain)
        raise_error('pybladerf_get_gain()', result)
        return gain

    def pybladerf_get_rfic_register(self, address: int) -> int:
        """Read-only читання RFIC-регістра (`bladerf_get_rfic_register`).

        RFIC-HEALTH-001B: BBPLL lock (0x05E), RX/TX RF PLL lock
        (0x247/0x287), RX/TX RF PLL cal done (0x244/0x284). Це САМЕ
        read-only виклик — не змінює стан RFIC (на відміну від
        `pybladerf_set_rfic_register`, який тут навмисно НЕ обгорнутий:
        write-шлях лишається окремим рішенням, не випадковим побічним
        ефектом наявності read-обгортки).
        """
        cdef uint8_t val
        result = cbladerf.bladerf_get_rfic_register(
            self.__bladerf_device, address, &val)
        raise_error('pybladerf_get_rfic_register()', result)
        return val

    def pybladerf_rx_transition_begin(self, channel: int, frequency_hz: int,
                                      required_events_mask: int,
                                      timeout_ms: int,
                                      require_rx_data_valid: bool = True,
                                      quick_tune=None) -> int:
        """ADR-0207: event-driven RX retune. Без quick_tune виконує
        host-mode `bladerf_set_frequency`; з quick_tune використовує
        NIOS fastlock recall. В обох випадках FPGA epoch fence
        встановлюється до перебудови. Повертає `transaction_id` для
        `pybladerf_rx_transition_wait()` -- НЕ блокує сам по собі.
        `required_events_mask` складається з OR публічних RF_REQUIRE_* бітів;
        для валідного FPGA epoch використовуйте RF_REQUIRE_EPOCH_VALID.
        RF_REQUIRE_FIRST_HOST_DATA додатково чекає перший META transfer,
        перевірений за epoch і timestamp; якщо він не встигає до timeout,
        пізній перший transfer буде withheld. RF_REQUIRE_RX_X2_HOST_DATA
        вимагає RX_X2 stream і не дозволяє RX_X1 sync/async конфігурацію;
        waiter завершується тільки після першого валідованого RX_X2 META."""
        cdef cbladerf.bladerf_rx_transition_request request
        cdef uint32_t transaction_id
        cdef cbladerf.bladerf_quick_tune *quick_tune_ptr = NULL

        request.target_frequency_hz = frequency_hz
        request.required_events_mask = required_events_mask
        request.timeout_ms = timeout_ms
        request.require_rx_data_valid = require_rx_data_valid
        request.epoch_settle_samples = 0

        if quick_tune is not None:
            if not isinstance(quick_tune, pybladerf_quick_tune):
                raise TypeError("quick_tune must be pybladerf_quick_tune or None")
            quick_tune_ptr = (<pybladerf_quick_tune>quick_tune).get_ptr()
            result = cbladerf.bladerf_rx_transition_begin_quick_tune(
                self.__bladerf_device, channel, &request, quick_tune_ptr,
                &transaction_id)
        else:
            result = cbladerf.bladerf_rx_transition_begin(
                self.__bladerf_device, channel, &request, &transaction_id)

        # begin can append CONFIG_ACCEPTED and terminal failure events before
        # returning an error (for example, an FPGA epoch ARM failure). Drain
        # them before raise_error so Python subscribers see the failure on
        # the same call that caused it.
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_rx_transition_begin()', result)
        return transaction_id

    def pybladerf_rx_capture_close(self, channel: int) -> None:
        """Revoke the certified finite-capture epoch and close the FPGA RX gate."""
        result = cbladerf.bladerf_rx_capture_close(
            self.__bladerf_device, channel)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_rx_capture_close()', result)

    def pybladerf_rx_transition_wait(self, transaction_id: int,
                                     timeout_ms: int) -> dict:
        """Блокує до підтвердження required-подій, timeout чи помилки.
        `BLADERF_ERR_TIMEOUT` -- явний провал (`RF_STATE_TIMEOUT`),
        НІКОЛИ не трактувати як "ймовірно валідні дані" (ADR §Заборонений
        wait). Повертає останню подію як dict (host_monotonic_ns,
        fpga_state, event_type, error_code, etc)."""
        cdef cbladerf.bladerf_rf_event final_event

        result = cbladerf.bladerf_rx_transition_wait(
            self.__bladerf_device, transaction_id, &final_event, timeout_ms)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_rx_transition_wait()', result)

        return {
            'host_monotonic_ns': final_event.host_monotonic_ns,
            'fpga_timestamp': final_event.fpga_timestamp,
            'transaction_id': final_event.transaction_id,
            'epoch_id': final_event.epoch_id,
            'requested_rx_lo_hz': final_event.requested_rx_lo_hz,
            'readback_rx_lo_hz': final_event.readback_rx_lo_hz,
            'rfic_status': final_event.rfic_status,
            'fpga_state': int(final_event.fpga_state),
            'event_type': int(final_event.event_type),
            'event_name': _rf_event_name(final_event.event_type),
            'flags': final_event.flags,
            'invalidation_reason': _rf_invalidation_reason(
                final_event.event_type, final_event.flags),
            'error_code': final_event.error_code,
            **_rf_event_validity_fields(final_event.event_type,
                                        final_event.flags,
                                        final_event.rfic_status),
        }

    def pybladerf_rx_transition_get_events(self, transaction_id: int) -> dict:
        """Повертає збережені події переходу у часовому порядку.

        Результат містить список `events` та `history_complete`. Останній
        буде False, якщо транзакція ще не завершена або її початок/кінець
        витіснено з обмеженого C-кольца.
        """
        cdef cbladerf.bladerf_rf_event events[64]
        cdef uint32_t event_count = 0
        cdef cbladerf.c_bool history_complete = False
        cdef int result
        cdef list event_list = []
        cdef cbladerf.bladerf_rf_event *event

        result = cbladerf.bladerf_rx_transition_get_events(
            self.__bladerf_device, transaction_id, events, 64,
            &event_count, &history_complete)
        raise_error('pybladerf_rx_transition_get_events()', result)

        for i in range(event_count):
            event = &events[i]
            event_list.append({
                'host_monotonic_ns': event.host_monotonic_ns,
                'fpga_timestamp': event.fpga_timestamp,
                'transaction_id': event.transaction_id,
                'epoch_id': event.epoch_id,
                'requested_rx_lo_hz': event.requested_rx_lo_hz,
                'readback_rx_lo_hz': event.readback_rx_lo_hz,
                'rfic_status': event.rfic_status,
                'fpga_state': int(event.fpga_state),
                'event_type': int(event.event_type),
                'event_name': _rf_event_name(event.event_type),
                'flags': event.flags,
                'invalidation_reason': _rf_invalidation_reason(
                    event.event_type, event.flags),
                'error_code': event.error_code,
                **_rf_event_validity_fields(event.event_type, event.flags,
                                            event.rfic_status),
            })
        _correlate_rx_invalidation_channel(event_list)
        return {'events': event_list,
                'history_complete': bool(history_complete)}

    def pybladerf_rx_transition_get_nios_timing(self, transaction_id: int) -> dict:
        """Return the NIOS RX fastlock duration retained for a transaction.

        `device_duration_ticks` is a raw module time-tamer delta and is
        separate from host-monotonic USB OUT/IN event timestamps.
        """
        cdef cbladerf.bladerf_rx_transition_nios_timing timing
        result = cbladerf.bladerf_rx_transition_get_nios_timing(
            self.__bladerf_device, transaction_id, &timing)
        raise_error('pybladerf_rx_transition_get_nios_timing()', result)
        return {
            'transaction_retained': bool(timing.transaction_retained),
            'nios_retune_observed': bool(timing.nios_retune_observed),
            'device_duration_valid': bool(timing.device_duration_valid),
            'device_duration_ticks': timing.device_duration_ticks,
        }

    def pybladerf_get_rfic_temperature(self) -> float:
        cdef float val
        result = cbladerf.bladerf_get_rfic_temperature(
            self.__bladerf_device, &val)
        raise_error('pybladerf_get_rfic_temperature()', result)
        return val

    def pybladerf_set_gain_mode(self, channel: int, mode: pybladerf_gain_mode) -> None:
        result = cbladerf.bladerf_set_gain_mode(self.__bladerf_device, channel, mode)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_gain_mode()', result)

    def pybladerf_get_gain_mode(self, channel: int) -> pybladerf_gain_mode:
        cdef cbladerf.bladerf_gain_mode mode
        result = cbladerf.bladerf_get_gain_mode(self.__bladerf_device, channel, &mode)
        raise_error('pybladerf_get_gain_mode()', result)
        return pybladerf_gain_mode(mode)

    def pybladerf_get_gain_modes(self, channel: int) -> list[pybladerf_gain_mode]:
        cdef const cbladerf.bladerf_gain_modes *modes_ptr
        result = cbladerf.bladerf_get_gain_modes(self.__bladerf_device, channel, &modes_ptr)
        raise_error('pybladerf_get_gain_modes()', result)
        return [pybladerf_gain_mode(modes_ptr[i].mode) for i in range(result)]

    def pybladerf_get_gain_range(self, channel: int) -> pybladerf_range:
        gain_range = pybladerf_range()
        result = cbladerf.bladerf_get_gain_range(self.__bladerf_device, channel, gain_range.get_double_ptr())
        raise_error('pybladerf_get_gain_range()', result)
        return gain_range

    def pybladerf_set_gain_stage(self, channel: int, stage: str, gain: int) -> None:
        result = cbladerf.bladerf_set_gain_stage(self.__bladerf_device, channel, stage.encode('utf-8'), gain)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_gain_stage()', result)

    def pybladerf_get_gain_stage(self, channel: int, stage: str) -> int:
        cdef int gain
        result = cbladerf.bladerf_get_gain_stage(self.__bladerf_device, channel, stage.encode('utf-8'), &gain)
        raise_error('pybladerf_get_gain_stage()', result)
        return gain

    def pybladerf_get_gain_stage_range(self, channel: int, stage: str) -> pybladerf_range:
        gain_stage_range = pybladerf_range()
        result = cbladerf.bladerf_get_gain_stage_range(self.__bladerf_device, channel, stage.encode('utf-8'), gain_stage_range.get_double_ptr())
        raise_error('pybladerf_get_gain_stage_range()', result)
        return gain_stage_range

    def pybladerf_get_gain_stages(self, channel: int) -> list[str]:
        cdef const char *stages_ptr[16]
        result = cbladerf.bladerf_get_gain_stages(self.__bladerf_device, channel, stages_ptr, 16)
        raise_error('pybladerf_get_gain_stages()', result)
        return [stages_ptr[i].decode('utf-8') for i in range(result)]

    def pybladerf_set_sample_rate(self, channel: int, sample_rate: int) -> int:
        cdef unsigned int actual_sample_rate
        result = cbladerf.bladerf_set_sample_rate(self.__bladerf_device, channel, <unsigned int> sample_rate, &actual_sample_rate)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_sample_rate()', result)
        return actual_sample_rate

    def pybladerf_set_rational_sample_rate(self, channel: int, integer: int, num: int, den: int) -> tuple[int, int, int]:
        cdef cbladerf.bladerf_rational_rate rate
        cdef cbladerf.bladerf_rational_rate actual_sample_rate

        rate.integer = <uint64_t> integer
        rate.num = <uint64_t> num
        rate.den = <uint64_t> den

        result = cbladerf.bladerf_set_rational_sample_rate(self.__bladerf_device, channel, &rate, &actual_sample_rate)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rational_sample_rate()', result)
        return actual_sample_rate.integer, actual_sample_rate.num, actual_sample_rate.den

    def pybladerf_get_sample_rate(self, channel: int) -> int:
        cdef unsigned int sample_rate
        result = cbladerf.bladerf_get_sample_rate(self.__bladerf_device, channel, &sample_rate)
        raise_error('pybladerf_get_sample_rate()', result)
        return sample_rate

    def pybladerf_get_sample_rate_range(self, channel: int) -> pybladerf_range:
        sample_rate_range = pybladerf_range()
        result = cbladerf.bladerf_get_sample_rate_range(self.__bladerf_device, channel, sample_rate_range.get_double_ptr())
        raise_error('pybladerf_get_sample_rate_range()', result)
        return sample_rate_range

    def pybladerf_get_rational_sample_rate(self, channel: int) -> tuple[int, int, int]:
        cdef cbladerf.bladerf_rational_rate rate
        result = cbladerf.bladerf_get_rational_sample_rate(self.__bladerf_device, channel, &rate)
        raise_error('pybladerf_get_rational_sample_rate()', result)
        return (rate.integer, rate.num, rate.den)

    def pybladerf_set_bandwidth(self, channel: int, bandwidth: int) -> int:
        cdef unsigned int actual_bandwidth
        result = cbladerf.bladerf_set_bandwidth(self.__bladerf_device, channel, <unsigned int> bandwidth, &actual_bandwidth)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_bandwidth()', result)
        return actual_bandwidth

    def pybladerf_get_bandwidth(self, channel: int) -> int:
        cdef unsigned int bandwidth
        result = cbladerf.bladerf_get_bandwidth(self.__bladerf_device, channel, &bandwidth)
        raise_error('pybladerf_get_bandwidth()', result)
        return bandwidth

    def pybladerf_get_bandwidth_range(self, channel: int) -> pybladerf_range:
        bandwidth_range = pybladerf_range()
        result = cbladerf.bladerf_get_bandwidth_range(self.__bladerf_device, channel, bandwidth_range.get_double_ptr())
        raise_error('pybladerf_get_bandwidth_range()', result)
        return bandwidth_range

    def pybladerf_select_band(self, channel: int, frequency: int) -> None:
        result = cbladerf.bladerf_select_band(self.__bladerf_device, channel, <uint64_t> frequency)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_select_band()', result)

    def pybladerf_set_frequency(self, channel: int, frequency: int) -> None:
        result = cbladerf.bladerf_set_frequency(self.__bladerf_device, channel, <uint64_t> frequency)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_frequency()', result)

    def pybladerf_get_frequency(self, channel: int) -> int:
        cdef uint64_t frequency
        result = cbladerf.bladerf_get_frequency(self.__bladerf_device, channel, &frequency)
        raise_error('pybladerf_get_frequency()', result)
        return frequency

    def pybladerf_get_frequency_range(self, channel: int) -> pybladerf_range:
        frequency_range = pybladerf_range()
        result = cbladerf.bladerf_get_frequency_range(self.__bladerf_device, channel, frequency_range.get_double_ptr())
        raise_error('pybladerf_get_frequency_range()', result)
        return frequency_range

    def pybladerf_get_loopback_modes(self) -> list[pybladerf_loopback]:
        cdef const cbladerf.bladerf_loopback_modes *modes_ptr
        result = cbladerf.bladerf_get_loopback_modes(self.__bladerf_device, &modes_ptr)
        raise_error('pybladerf_get_loopback_modes()', result)
        return [pybladerf_loopback(modes_ptr[i].mode) for i in range(result)]

    def pybladerf_is_loopback_mode_supported(self, mode: pybladerf_loopback) -> bool:
        return cbladerf.bladerf_is_loopback_mode_supported(self.__bladerf_device, mode)

    def pybladerf_set_loopback(self, lb: pybladerf_loopback) -> None:
        result = cbladerf.bladerf_set_loopback(self.__bladerf_device, lb)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_loopback()', result)

    def pybladerf_get_loopback(self) -> pybladerf_loopback:
        cdef cbladerf.bladerf_loopback lb
        result = cbladerf.bladerf_get_loopback(self.__bladerf_device, &lb)
        raise_error('pybladerf_get_loopback()', result)
        return pybladerf_loopback(lb)

    def pybladerf_trigger_init(self, channel: int, trigger_signal: pybladerf_trigger_signal) -> pybladerf_trigger:
        cdef pybladerf_trigger trigger = pybladerf_trigger()
        result = cbladerf.bladerf_trigger_init(self.__bladerf_device, channel, trigger_signal, trigger.get_ptr())
        raise_error('pybladerf_trigger_init()', result)
        return trigger

    def pybladerf_trigger_arm(self, trigger: pybladerf_trigger, arm: bool) -> None:
        result = cbladerf.bladerf_trigger_arm(self.__bladerf_device, trigger.get_ptr(), arm, <uint64_t> 0, <uint64_t> 0)
        _dispatch_rf_events_then_raise(self, 'pybladerf_trigger_arm()', result)

    def pybladerf_trigger_fire(self, trigger: pybladerf_trigger) -> None:
        result = cbladerf.bladerf_trigger_fire(self.__bladerf_device, trigger.get_ptr())
        raise_error('pybladerf_trigger_fire()', result)

    def pybladerf_trigger_state(self, trigger: pybladerf_trigger) -> tuple[bool, bool, bool]:
        cdef c_bool is_armed, has_fired, fire_requested
        cdef uint64_t resv1, resv2
        result = cbladerf.bladerf_trigger_state(self.__bladerf_device, trigger.get_ptr(), &is_armed, &has_fired, &fire_requested, &resv1, &resv2)
        raise_error('pybladerf_trigger_state()', result)
        return (is_armed, has_fired, fire_requested)

    def pybladerf_set_rx_mux(self, mux: pybladerf_rx_mux) -> None:
        result = cbladerf.bladerf_set_rx_mux(self.__bladerf_device, mux)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rx_mux()', result)

    def pybladerf_get_rx_mux(self) -> pybladerf_rx_mux:
        cdef cbladerf.bladerf_rx_mux mux
        result = cbladerf.bladerf_get_rx_mux(self.__bladerf_device, &mux)
        raise_error('pybladerf_get_rx_mux()', result)
        return pybladerf_rx_mux(mux)

    def pybladerf_schedule_retune(self, channel: int, timestamp: int, frequency: int, quick_tune: pybladerf_quick_tune | None = None) -> None:
        cdef cbladerf.bladerf_quick_tune *c_quick_tune_ptr = NULL
        cdef pybladerf_quick_tune quick_tune_link
        if isinstance(quick_tune, pybladerf_quick_tune):
            quick_tune_link = quick_tune
            c_quick_tune_ptr = <cbladerf.bladerf_quick_tune*> quick_tune_link.get_ptr()

        cdef uint64_t c_timestamp = <uint64_t> timestamp
        cdef uint64_t c_frequency = <uint64_t> frequency
        cdef int c_channel = <int> channel
        cdef int result

        with nogil:
            result = cbladerf.bladerf_schedule_retune(self.__bladerf_device, c_channel, c_timestamp, c_frequency, c_quick_tune_ptr)
        raise_error('pybladerf_schedule_retune()', result)

    def pybladerf_cancel_scheduled_retunes(self, channel: int) -> None:
        result = cbladerf.bladerf_cancel_scheduled_retunes(self.__bladerf_device, channel)
        raise_error('pybladerf_cancel_scheduled_retunes()', result)

    def pybladerf_get_quick_tune(self, channel: int) -> pybladerf_quick_tune:
        cdef pybladerf_quick_tune quick_tune = pybladerf_quick_tune()
        result = cbladerf.bladerf_get_quick_tune(self.__bladerf_device, channel, quick_tune.get_ptr())
        raise_error('pybladerf_get_quick_tune()', result)
        return quick_tune

    def pybladerf_set_correction(self, channel: int, correction: pybladerf_correction, value: int) -> None:
        result = cbladerf.bladerf_set_correction(self.__bladerf_device, channel, correction, <int16_t> value)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_correction()', result)

    def pybladerf_get_correction(self, channel: int, correction: pybladerf_correction) -> int:
        cdef int16_t value
        result = cbladerf.bladerf_get_correction(self.__bladerf_device, channel, correction, &value)
        raise_error('pybladerf_get_correction()', result)
        return value

    def pybladerf_interleave_stream_buffer(self, layout: pybladerf_channel_layout, data_format: pybladerf_format, buffer_size: int, samples: np.ndarray[Any, Any]) -> None:
        result = cbladerf.bladerf_interleave_stream_buffer(layout, data_format, <unsigned int> buffer_size, <void*> <uintptr_t> samples.ctypes.data)
        raise_error('pybladerf_interleave_stream_buffer()', result)

    def pybladerf_deinterleave_stream_buffer(self, layout: pybladerf_channel_layout, data_format: pybladerf_format, buffer_size: int, samples: np.ndarray[Any, Any]) -> None:
        result = cbladerf.bladerf_deinterleave_stream_buffer(layout, data_format, <unsigned int> buffer_size, <void*> <uintptr_t> samples.ctypes.data)
        raise_error('pybladerf_deinterleave_stream_buffer()', result)

    def pybladerf_enable_module(self, channel: int, enable: bool) -> None:
        # libbladeRF tears the synchronous stream down when a direction is
        # disabled (rfic_host.c calls sync_deinit() on !dir_enable, and
        # bladerf1.c does the same).  This is documented behaviour, but
        # re-enabling the module does NOT bring the stream back: every
        # later bladerf_sync_tx()/sync_rx() then fails with
        #     "sync tx invalid: not initialized"
        # which gives no hint that sync_config() has to be repeated.
        #
        # Remember the last configuration per direction and restore it on
        # re-enable, so a disable/enable cycle keeps working.
        result = cbladerf.bladerf_enable_module(self.__bladerf_device, channel, enable)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_enable_module()', result)

        direction = 1 if (channel & 1) else 0          # TX channels are odd
        if not enable:
            self.__sync_torn_down.add(direction)
            return
        if direction in self.__sync_torn_down:
            self.__sync_torn_down.discard(direction)
            if not self.__auto_reconfig:
                return
            cfg = self.__sync_config.get(direction)
            if cfg is not None:
                self.pybladerf_sync_config(*cfg)

    @property
    def auto_sync_reconfig(self) -> bool:
        """Whether re-enabling a direction repeats its last sync_config.

        On by default: without it every sync_tx/sync_rx after a
        disable/enable cycle fails with "not initialized". Turn it off to
        measure the library's own behaviour, or to drive sync_config by
        hand.
        """
        return self.__auto_reconfig

    @auto_sync_reconfig.setter
    def auto_sync_reconfig(self, value: bool) -> None:
        self.__auto_reconfig = bool(value)

    def pybladerf_get_timestamp(self, direction: pybladerf_direction) -> int:
        cdef uint64_t timestamp
        result = cbladerf.bladerf_get_timestamp(self.__bladerf_device, direction, &timestamp)
        raise_error('pybladerf_get_timestamp()', result)
        return timestamp

    def pybladerf_get_loss_event_count(self, direction: pybladerf_direction) -> int:
        '''Loss EPISODES the FPGA counted, per direction.

        Episodes, not samples: an unbroken run of overflow increments this
        once however long it lasts. Do not scale it into a sample count.

        Not the same as the OVERRUN metadata flag: that one is computed on
        the host from USB queue state and never reads the fabric, so a loss
        the FPGA absorbed on its own leaves it clear.

        Cleared by enable_module(True) -- a difference across an enable
        boundary is meaningless. Monotonic within one enabled session.
        '''
        cdef uint64_t count
        result = cbladerf.bladerf_get_loss_event_count(self.__bladerf_device, direction, &count)
        raise_error('pybladerf_get_loss_event_count()', result)
        return count

    def pybladerf_sync_config(self, layout: pybladerf_channel_layout, data_format: pybladerf_format, num_buffers: int, buffer_size: int, num_transfers: int, stream_timeout: int) -> None:
        result = cbladerf.bladerf_sync_config(self.__bladerf_device, layout, data_format, <unsigned int> num_buffers, <unsigned int> buffer_size, <unsigned int> num_transfers, <unsigned int> stream_timeout)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_sync_config()', result)

        # Keep the settings so pybladerf_enable_module() can restore the
        # stream after libbladeRF tears it down on disable.
        direction = 1 if (int(layout) & 1) else 0      # TX layouts are odd
        self.__sync_config[direction] = (layout, data_format, num_buffers,
                                         buffer_size, num_transfers,
                                         stream_timeout)
        self.__sync_torn_down.discard(direction)

    def pybladerf_sync_tx(self, samples: np.ndarray[Any, Any], num_samples: int, metadata: pybladerf_metadata | None = None, timeout_ms: int = 0) -> None:
        cdef cbladerf.bladerf_metadata *c_metadata_ptr = NULL
        cdef pybladerf_metadata metadata_link

        if isinstance(metadata, pybladerf_metadata):
            metadata_link = metadata
            c_metadata_ptr = <cbladerf.bladerf_metadata*> metadata_link.get_ptr()
        else:
            self.__check_metadata_required(1, 'pybladerf_sync_tx')

        cdef unsigned int c_num_samples = <unsigned int> num_samples
        cdef unsigned int c_timeout_ms = <unsigned int> timeout_ms
        cdef void *c_samples_ptr = <void*> <uintptr_t> samples.ctypes.data
        cdef int result

        with nogil:
            result = cbladerf.bladerf_sync_tx(self.__bladerf_device, c_samples_ptr, c_num_samples, c_metadata_ptr, c_timeout_ms)
        raise_error('pybladerf_sync_tx()', result)

    def pybladerf_sync_rx(self, samples: np.ndarray[Any, Any], num_samples: int, metadata: pybladerf_metadata | None = None, timeout_ms: int = 0) -> None:
        cdef cbladerf.bladerf_metadata *c_metadata_ptr = NULL
        cdef pybladerf_metadata metadata_link

        if isinstance(metadata, pybladerf_metadata):
            metadata_link = metadata
            c_metadata_ptr = <cbladerf.bladerf_metadata*> metadata_link.get_ptr()
        else:
            self.__check_metadata_required(0, 'pybladerf_sync_rx')

        cdef unsigned int c_num_samples = <unsigned int> num_samples
        cdef unsigned int c_timeout_ms = <unsigned int> timeout_ms
        cdef void *c_samples_ptr = <void*> <uintptr_t> samples.ctypes.data
        cdef int result

        with nogil:
            result = cbladerf.bladerf_sync_rx(self.__bladerf_device, c_samples_ptr, c_num_samples, c_metadata_ptr, c_timeout_ms)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_sync_rx()', result)

    def __check_metadata_required(self, direction: int, caller: str) -> None:
        """Refuse a metadata-format transfer that was given no metadata.

        A stream configured with a *_META format carries per-buffer
        timestamps and flags. Passing metadata=None leaves libbladeRF with
        nowhere to report them, so the caller silently loses the timestamp
        it needs and bladerf_get_timestamp() keeps returning 0. Nothing in
        the error path points at the real cause, so this reads as dead
        hardware rather than a mismatched call.

        Measured on a TX1 -> 50 dB pad -> RX1 loopback: with SC16_Q11 the
        frame timestamp stayed at 762229041 across 8 consecutive reads and
        get_timestamp() returned 0, so consecutive gain steps analysed the
        same buffer and the gain ladder came out non-monotonic.
        """
        cfg = self.__sync_config.get(direction)
        if cfg is None:
            return
        fmt = int(cfg[1])
        if fmt in (int(pybladerf_format.PYBLADERF_FORMAT_SC16_Q11_META),
                   int(pybladerf_format.PYBLADERF_FORMAT_SC8_Q7_META)):
            raise RuntimeError(
                f'{caller}(): stream is configured with a metadata format '
                f'({pybladerf_format(fmt)}) but metadata=None was passed. '
                'Timestamps and flags would be lost silently; pass a '
                'pybladerf_metadata instance.')

    def pybladerf_init_rx_stream(self, num_buffers: int, data_format: pybladerf_format, samples_per_buffer: int, num_transfers: int) -> pybladerf_stream:
        cdef pybladerf_stream pystream = pybladerf_stream()
        cdef pybladerf_async_data* async_data = <pybladerf_async_data*> malloc(sizeof(pybladerf_async_data))
        cdef void **buffers
        cdef int result = -1

        async_data.bytes_per_sample = 4 if data_format == pybladerf_format.PYBLADERF_FORMAT_SC16_Q11 else 2
        async_data.package_size = USB_PACKAGE_SIZE_SS if self.pybladerf_device_speed() == pybladerf_dev_speed.PYBLADERF_DEVICE_SPEED_SUPER else USB_PACKAGE_SIZE_HS
        async_data.packages_per_buffer = samples_per_buffer // (async_data.package_size // async_data.bytes_per_sample)
        async_data.samples_per_package = (samples_per_buffer - PYMETADATA_HEADER_SIZE) // async_data.bytes_per_sample
        async_data.pystream = <void*>pystream
        async_data.tx_complete = False

        # if data_format in {pybladerf_format.PYBLADERF_FORMAT_SC16_Q11_META, pybladerf_format.PYBLADERF_FORMAT_SC8_Q7_META}:

        if data_format == pybladerf_format.PYBLADERF_FORMAT_SC16_Q11:
            result = cbladerf.bladerf_init_stream(pystream.get_double_ptr(), self.__bladerf_device, __rx_callback_SC16_Q11, &buffers, <size_t> num_buffers, data_format, <size_t> samples_per_buffer, <size_t> num_transfers, <void*> async_data)
        elif data_format == pybladerf_format.PYBLADERF_FORMAT_SC8_Q7:
            result = cbladerf.bladerf_init_stream(pystream.get_double_ptr(), self.__bladerf_device, __rx_callback_SC8_Q7, &buffers, <size_t> num_buffers, data_format, <size_t> samples_per_buffer, <size_t> num_transfers, <void*> async_data)
        else:
            raise raise_error('pybladerf_init_rx_stream', -8)
        if result < 0:
            free(async_data)

        raise_error('pybladerf_init_rx_stream', result)
        Py_INCREF(pystream)
        return pystream

    def pybladerf_init_tx_stream(self, num_buffers: int, data_format: pybladerf_format, samples_per_buffer: int, num_transfers: int) -> pybladerf_stream:
        cdef pybladerf_stream pystream = pybladerf_stream()
        cdef pybladerf_async_data* async_data = <pybladerf_async_data*> malloc(sizeof(pybladerf_async_data))
        cdef void **buffers
        cdef int result = -1

        async_data.bytes_per_sample = 4 if data_format == pybladerf_format.PYBLADERF_FORMAT_SC16_Q11 else 2
        async_data.package_size = USB_PACKAGE_SIZE_SS if self.pybladerf_device_speed() == pybladerf_dev_speed.PYBLADERF_DEVICE_SPEED_SUPER else USB_PACKAGE_SIZE_HS
        async_data.packages_per_buffer = samples_per_buffer // (async_data.package_size // async_data.bytes_per_sample)
        async_data.samples_per_package = (samples_per_buffer - PYMETADATA_HEADER_SIZE) // async_data.bytes_per_sample
        async_data.pystream = <void*>pystream
        async_data.tx_complete = False

        # if data_format in {pybladerf_format.PYBLADERF_FORMAT_SC16_Q11_META, pybladerf_format.PYBLADERF_FORMAT_SC8_Q7_META}:

        if data_format == pybladerf_format.PYBLADERF_FORMAT_SC16_Q11:
            result = cbladerf.bladerf_init_stream(pystream.get_double_ptr(), self.__bladerf_device, __tx_callback_SC16_Q11, &buffers, <size_t> num_buffers, data_format, <size_t> samples_per_buffer, <size_t> num_transfers, <void*> async_data)
        elif data_format == pybladerf_format.PYBLADERF_FORMAT_SC8_Q7:
            result = cbladerf.bladerf_init_stream(pystream.get_double_ptr(), self.__bladerf_device, __tx_callback_SC8_Q7, &buffers, <size_t> num_buffers, data_format, <size_t> samples_per_buffer, <size_t> num_transfers, <void*> async_data)
        else:
            raise raise_error('pybladerf_init_tx_stream', -8)

        if result < 0:
            free(async_data)

        raise_error('pybladerf_init_tx_stream', result)
        Py_INCREF(pystream)
        return pystream

    def pybladerf_start_stream(self, stream: pybladerf_stream, layout: pybladerf_channel_layout) -> None:
        cdef cbladerf.bladerf_stream *c_stream = stream.get_ptr()
        cdef cbladerf.bladerf_channel_layout c_layout = layout
        cdef int result

        with nogil:
            result = cbladerf.bladerf_start_stream(c_stream, c_layout)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_start_stream()', result)

    def pybladerf_submit_stream_buffer(self, stream: pybladerf_stream, buffer: np.ndarray[Any, Any], timeout_ms: int) -> None:
        cdef cbladerf.bladerf_stream *c_stream = stream.get_ptr()
        cdef void *c_buffer = <void*> <uintptr_t> buffer.ctypes.data
        cdef unsigned int c_timeout_ms = <unsigned int> timeout_ms
        cdef int result

        with nogil:
            result = cbladerf.bladerf_submit_stream_buffer(c_stream, c_buffer, c_timeout_ms)
        raise_error('pybladerf_submit_stream_buffer()', result)

    def pybladerf_submit_stream_buffer_nb(self, stream: pybladerf_stream, buffer: np.ndarray[Any, Any]) -> None:
        result = cbladerf.bladerf_submit_stream_buffer_nb(stream.get_ptr(), <void*> <uintptr_t> buffer.ctypes.data)
        raise_error('pybladerf_submit_stream_buffer_nb()', result)

    def pybladerf_deinit_stream(self, stream: pybladerf_stream) -> None:
        cbladerf.bladerf_deinit_stream(stream.get_ptr())
        Py_DECREF(stream)

    def pybladerf_set_stream_timeout(self, direction: pybladerf_direction, timeout: int) -> None:
        result = cbladerf.bladerf_set_stream_timeout(self.__bladerf_device, direction, <unsigned int> timeout)
        raise_error('pybladerf_set_stream_timeout()', result)

    def pybladerf_get_stream_timeout(self, direction: pybladerf_direction) -> int:
        cdef unsigned int timeout
        result = cbladerf.bladerf_get_stream_timeout(self.__bladerf_device, direction, &timeout)
        raise_error('pybladerf_get_stream_timeout()', result)
        return timeout

    def pybladerf_device_reset(self) -> None:
        result = cbladerf.bladerf_device_reset(self.__bladerf_device)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_device_reset()', result)

    def pybladerf_load_fpga(self, fpga_file: str) -> None:
        """Load an FPGA image while RX/TX modules are disabled.

        The current RX epoch is invalidated first. RX remains uncertified
        until the caller configures RX and completes a new event transition.
        """
        result = cbladerf.bladerf_load_fpga(
            self.__bladerf_device, fpga_file.encode('utf-8'))
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_load_fpga()', result)

    def pybladerf_jump_to_bootloader(self) -> None:
        """Enter the FX3 bootloader after revoking current RX validity."""
        result = cbladerf.bladerf_jump_to_bootloader(self.__bladerf_device)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_jump_to_bootloader()', result)

    def pybladerf_get_fw_log(self, filename: str | None = None) -> None:
        cdef char *c_filename = NULL
        if filename is not None:
            filename_bytes = filename.encode('utf-8')
            c_filename = filename_bytes

        result = cbladerf.bladerf_get_fw_log(self.__bladerf_device, c_filename)
        raise_error('pybladerf_get_fw_log()', result)

    def pybladerf_read_flash_bytes(self, address: int, count: int) -> bytes:
        cdef bytearray buf = bytearray(count)
        cdef unsigned char[::1] view = buf
        result = cbladerf.bladerf_read_flash_bytes(self.__bladerf_device, &view[0], address, count)
        raise_error('pybladerf_read_flash_bytes()', result)
        return bytes(buf)

    def pybladerf_set_vctcxo_tamer_mode(self, mode: pybladerf_vctcxo_tamer_mode) -> None:
        result = cbladerf.bladerf_set_vctcxo_tamer_mode(self.__bladerf_device, mode)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_vctcxo_tamer_mode()', result)

    def pybladerf_get_vctcxo_tamer_mode(self) -> pybladerf_vctcxo_tamer_mode:
        cdef cbladerf.bladerf_vctcxo_tamer_mode mode
        result = cbladerf.bladerf_get_vctcxo_tamer_mode(self.__bladerf_device, &mode)
        raise_error('pybladerf_get_vctcxo_tamer_mode()', result)
        return pybladerf_vctcxo_tamer_mode(mode)

    def pybladerf_get_vctcxo_trim(self) -> int:
        cdef uint16_t trim
        result = cbladerf.bladerf_get_vctcxo_trim(self.__bladerf_device, &trim)
        raise_error('pybladerf_get_vctcxo_trim()', result)
        return trim

    def pybladerf_trim_dac_write(self, value: int) -> None:
        result = cbladerf.bladerf_trim_dac_write(self.__bladerf_device, <uint16_t> value)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_trim_dac_write()', result)

    def pybladerf_trim_dac_read(self) -> int:
        cdef uint16_t value
        result = cbladerf.bladerf_trim_dac_read(self.__bladerf_device, &value)
        raise_error('pybladerf_trim_dac_read()', result)
        return value

    def pybladerf_set_tuning_mode(self, mode: pybladerf_tuning_mode) -> None:
        result = cbladerf.bladerf_set_tuning_mode(self.__bladerf_device, mode)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_tuning_mode()', result)

    def pybladerf_get_tuning_mode(self) -> pybladerf_tuning_mode:
        cdef cbladerf.bladerf_tuning_mode mode
        result = cbladerf.bladerf_get_tuning_mode(self.__bladerf_device, &mode)
        raise_error('pybladerf_get_tuning_mode()', result)
        return pybladerf_tuning_mode(mode)

    def pybladerf_read_trigger(self, channel: int, trigger_signal: pybladerf_trigger_signal) -> int:
        cdef uint8_t value
        result = cbladerf.bladerf_read_trigger(self.__bladerf_device, channel, trigger_signal, &value)
        raise_error('pybladerf_read_trigger()', result)
        return value

    def pybladerf_write_trigger(self, channel: int, trigger_signal: pybladerf_trigger, value: int) -> None:
        result = cbladerf.bladerf_write_trigger(self.__bladerf_device, channel, trigger_signal, <uint8_t> value)
        _dispatch_rf_events_then_raise(self, 'pybladerf_write_trigger()', result)

    def pybladerf_set_rf_port(self, channel: int, port: str) -> None:
        result = cbladerf.bladerf_set_rf_port(self.__bladerf_device, channel, port.encode('utf-8'))
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rf_port()', result)

    def pybladerf_get_rf_port(self, channel: int) -> str:
        cdef const char **port
        result = cbladerf.bladerf_get_rf_port(self.__bladerf_device, channel, port)
        raise_error('pybladerf_get_rf_port()', result)
        return port[0].decode('utf-8')

    def pybladerf_get_rf_ports(self, channel: int) -> list[str]:
        result = cbladerf.bladerf_get_rf_ports(self.__bladerf_device, channel, NULL, 0)
        raise_error('pybladerf_get_rf_ports()', result)
        cdef const char **ports
        result = cbladerf.bladerf_get_rf_ports(self.__bladerf_device, channel, ports, result)
        raise_error('pybladerf_get_rf_ports()', result)
        return [ports[i].decode('utf-8') for i in range(result)]

    def pybladerf_enable_feature(self, feature: pybladerf_feature, enable: bool) -> None:
        result = cbladerf.bladerf_enable_feature(self.__bladerf_device, feature, enable)
        # Feature changes invalidate the shared RX data certificate in
        # libbladeRF. Deliver that event at the API boundary, including when
        # the native call reports an error after recording the invalidation.
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_enable_feature()', result)

    def pybladerf_get_feature(self) -> pybladerf_feature:
        cdef cbladerf.bladerf_feature feature
        result = cbladerf.bladerf_get_feature(self.__bladerf_device, &feature)
        raise_error('pybladerf_get_feature()', result)
        return pybladerf_feature(feature)

    # ---- BLADERF2 ---- #
    def pybladerf_get_bias_tee(self, channel: int) -> bool:
        cdef c_bool enable
        result = cbladerf.bladerf_get_bias_tee(self.__bladerf_device, channel, &enable)
        raise_error('pybladerf_get_bias_tee()', result)
        return enable

    def pybladerf_set_bias_tee(self, channel: int, enable: bool) -> None:
        result = cbladerf.bladerf_set_bias_tee(self.__bladerf_device, channel, enable)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_bias_tee()', result)

    def pybladerf_config_gpio_read(self) -> int:
        """Read the FPGA configuration GPIO register.

        Carries the per-format mode bits (TIMESTAMP, PACKET, 8BIT_MODE,
        HIGHLY_PACKED) that both directions share. perform_format_config()
        writes the whole word from one direction's format, so this is where
        a stream configuration on one direction can clobber the mode the
        other direction needs.
        """
        cdef uint32_t value
        result = cbladerf.bladerf_config_gpio_read(self.__bladerf_device, &value)
        raise_error('pybladerf_config_gpio_read()', result)
        return value

    def pybladerf_get_rffe_control(self) -> int:
        """Read the RFFE control register (FPGA, not RFIC).

        Carries the RF front-end state that no RFIC register reflects:
        SPDT switch positions, per-channel enables, and the direction
        ENABLE/TXNRX bits. Needed to tell a switch left in its shutdown
        position from an RFIC problem -- every RFIC register can read
        back correct while the signal is routed nowhere.
        """
        cdef uint32_t value
        result = cbladerf.bladerf_get_rffe_control(self.__bladerf_device, &value)
        raise_error('pybladerf_get_rffe_control()', result)
        return value

    def pybladerf_get_rfic_register(self, address: int) -> int:
        """Read one RFIC (AD9361) register over SPI.

        Needed because no FPGA-side register reflects the RFIC's internal
        state: the ENSM state, the digital datapath status and the filter
        enables live only here. Without this an RFIC stuck with a gated
        TX digital clock is indistinguishable from a healthy one, since
        the FPGA enable pins read correct in both cases.
        """
        cdef uint8_t value
        result = cbladerf.bladerf_get_rfic_register(self.__bladerf_device, <uint16_t> address, &value)
        raise_error('pybladerf_get_rfic_register()', result)
        return value

    def pybladerf_set_rfic_register(self, address: int, value: int) -> None:
        """Write one RFIC (AD9361) register over SPI."""
        result = cbladerf.bladerf_set_rfic_register(self.__bladerf_device, <uint16_t> address, <uint8_t> value)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rfic_register()', result)

    def pybladerf_get_rfic_temperature(self) -> float:
        cdef float value
        result = cbladerf.bladerf_get_rfic_temperature(self.__bladerf_device, &value)
        raise_error('pybladerf_get_rfic_temperature()', result)
        return value

    def pybladerf_get_rfic_rssi(self, channel: int) -> tuple[int]:
        cdef int32_t pre_rssi, sym_rssi
        result = cbladerf.bladerf_get_rfic_rssi(self.__bladerf_device, channel, &pre_rssi, &sym_rssi)
        raise_error('pybladerf_get_rfic_rssi()', result)
        return pre_rssi, sym_rssi

    def pybladerf_get_rfic_ctrl_out(self) -> int:
        cdef uint8_t ctrl_out
        result = cbladerf.bladerf_get_rfic_ctrl_out(self.__bladerf_device, &ctrl_out)
        raise_error('pybladerf_get_rfic_ctrl_out()', result)
        return ctrl_out

    def pybladerf_get_rfic_rx_fir(self) -> pybladerf_rfic_rxfir:
        cdef cbladerf.bladerf_rfic_rxfir rxfir
        result = cbladerf.bladerf_get_rfic_rx_fir(self.__bladerf_device, &rxfir)
        raise_error('pybladerf_get_rfic_rx_fir()', result)
        return pybladerf_rfic_rxfir(rxfir)

    def pybladerf_set_rfic_rx_fir(self, rxfir: pybladerf_rfic_rxfir) -> None:
        result = cbladerf.bladerf_set_rfic_rx_fir(self.__bladerf_device, rxfir)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rfic_rx_fir()', result)

    def pybladerf_get_rfic_tx_fir(self) -> pybladerf_rfic_txfir:
        cdef cbladerf.bladerf_rfic_txfir txfir
        result = cbladerf.bladerf_get_rfic_tx_fir(self.__bladerf_device, &txfir)
        raise_error('pybladerf_get_rfic_tx_fir()', result)
        return pybladerf_rfic_txfir(txfir)

    def pybladerf_set_rfic_tx_fir(self, txfir: pybladerf_rfic_txfir) -> None:
        result = cbladerf.bladerf_set_rfic_tx_fir(self.__bladerf_device, txfir)
        # TX FIR programming can recalculate shared RFIC clock/datapath state,
        # so libbladeRF revokes the RX certificate as part of this operation.
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_rfic_tx_fir()', result)

    def pybladerf_get_pll_lock_state(self) -> bool:
        cdef c_bool locked
        result = cbladerf.bladerf_get_pll_lock_state(self.__bladerf_device, &locked)
        raise_error('pybladerf_get_pll_lock_state()', result)
        return locked

    def pybladerf_get_pll_enable(self) -> bool:
        cdef c_bool enabled
        result = cbladerf.bladerf_get_pll_enable(self.__bladerf_device, &enabled)
        raise_error('pybladerf_get_pll_enable()', result)
        return enabled

    def pybladerf_set_pll_enable(self, enable: bool) -> None:
        result = cbladerf.bladerf_set_pll_enable(self.__bladerf_device, enable)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_pll_enable()', result)

    def pybladerf_get_pll_refclk_range(self) -> pybladerf_range:
        pll_refclk_range = pybladerf_range()
        result = cbladerf.bladerf_get_pll_refclk_range(self.__bladerf_device, pll_refclk_range.get_double_ptr())
        raise_error('pybladerf_get_pll_refclk_range()', result)
        return pll_refclk_range

    def pybladerf_get_pll_refclk(self) -> int:
        cdef uint64_t frequency
        result = cbladerf.bladerf_get_pll_refclk(self.__bladerf_device, &frequency)
        raise_error('pybladerf_get_pll_refclk()', result)
        return frequency

    def pybladerf_set_pll_refclk(self, frequency: int) -> None:
        result = cbladerf.bladerf_set_pll_refclk(self.__bladerf_device, <uint64_t> frequency)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_pll_refclk()', result)

    def pybladerf_get_pll_register(self, address: int) -> int:
        cdef uint32_t value
        result = cbladerf.bladerf_get_pll_register(self.__bladerf_device, <uint8_t> address, &value)
        raise_error('pybladerf_get_pll_register()', result)
        return value

    def pybladerf_set_pll_register(self, address: int, value: int) -> None:
        result = cbladerf.bladerf_set_pll_register(self.__bladerf_device, <uint8_t> address, <uint32_t> value)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_pll_register()', result)

    def pybladerf_get_power_source(self) -> pybladerf_power_sources:
        cdef cbladerf.bladerf_power_sources value
        result = cbladerf.bladerf_get_power_source(self.__bladerf_device, &value)
        raise_error('pybladerf_get_power_source()', result)
        return pybladerf_power_sources(value)

    def pybladerf_get_clock_select(self) -> pybladerf_clock_select:
        cdef cbladerf.bladerf_clock_select sel
        result = cbladerf.bladerf_get_clock_select(self.__bladerf_device, &sel)
        raise_error('pybladerf_get_clock_select()', result)
        return pybladerf_clock_select(sel)

    def pybladerf_set_clock_select(self, sel: pybladerf_clock_select) -> None:
        result = cbladerf.bladerf_set_clock_select(self.__bladerf_device, sel)
        self.pybladerf_dispatch_rf_events()
        raise_error('pybladerf_set_clock_select()', result)

    def pybladerf_get_clock_output(self) -> bool:
        cdef c_bool state
        result = cbladerf.bladerf_get_clock_output(self.__bladerf_device, &state)
        raise_error('pybladerf_get_clock_output()', result)
        return state

    def pybladerf_set_clock_output(self, enable: bool) -> None:
        result = cbladerf.bladerf_set_clock_output(self.__bladerf_device, enable)
        raise_error('pybladerf_set_clock_output()', result)

    def pybladerf_get_pmic_register(self, reg: pybladerf_pmic_register) -> int | float:
        cdef uint16_t i_val
        cdef float f_val
        if reg in (pybladerf_pmic_register.PYBLADERF_PMIC_CONFIGURATION, pybladerf_pmic_register.PYBLADERF_PMIC_CALIBRATION):
            result = cbladerf.bladerf_get_pmic_register(self.__bladerf_device, reg, <void*> &i_val)
            raise_error('pybladerf_get_pmic_register()', result)
            return i_val
        else:
            result = cbladerf.bladerf_get_pmic_register(self.__bladerf_device, reg, <void*> &f_val)
            raise_error('pybladerf_get_pmic_register()', result)
            return f_val

    def pybladerf_get_rf_switch_config(self) -> pybladerf_rf_switch_config:
        cdef pybladerf_rf_switch_config config = pybladerf_rf_switch_config()
        result = cbladerf.bladerf_get_rf_switch_config(self.__bladerf_device, config.get_ptr())
        raise_error('pybladerf_get_rf_switch_config()', result)
        return config

    # ---- new function ---- #
    def pybladerf_enable_tx_block_complete_callback(self) -> None:
        global global_callbacks

        if self.__bladerf_device is not NULL:
            global_callbacks[<size_t> self.__bladerf_device]['tx_complete_enabled'] = True
            return

        raise RuntimeError(f'pybladerf_enable_tx_block_complete_callback() failed: Device not initialized!')

    # ---- python callbacks setters ---- #
    def set_rx_callback(self, rx_callback_function: Callable[[Self, pybladerf_stream, np.ndarray[Any, Any], int], int]) -> None:
        global global_callbacks

        if self.__bladerf_device is not NULL:
            global_callbacks[<size_t> self.__bladerf_device]['__rx_callback'] = rx_callback_function
            global_callbacks[<size_t> self.__bladerf_device]['__rx_callback_with_metadata'] = None
            return

        raise RuntimeError(f'set_rx_callback() failed: Device not initialized!')

    def set_rx_callback_with_metadata(self, rx_callback_function) -> None:
        """Install an RX callback receiving a copied metadata dict as arg 5."""
        global global_callbacks

        if self.__bladerf_device is not NULL:
            global_callbacks[<size_t> self.__bladerf_device]['__rx_callback'] = None
            global_callbacks[<size_t> self.__bladerf_device]['__rx_callback_with_metadata'] = rx_callback_function
            return

        raise RuntimeError('set_rx_callback_with_metadata() failed: Device not initialized!')

    def set_tx_callback(self, tx_callback_function: Callable[[Self, pybladerf_stream, np.ndarray[Any, Any], int, int], int]) -> None:
        global global_callbacks

        if self.__bladerf_device is not NULL:
            global_callbacks[<size_t> self.__bladerf_device]['__tx_callback'] = tx_callback_function
            return

        raise RuntimeError(f'set_tx_callback() failed: Device not initialized!')

    def set_tx_complete_callback(self, tx_complete_callback_function: Callable[[Self, pybladerf_stream, np.ndarray[Any, Any], int], None]) -> None:
        global global_callbacks

        if self.__bladerf_device is not NULL:
            global_callbacks[<size_t> self.__bladerf_device]['__tx_complete_callback'] = tx_complete_callback_function
            return

        raise RuntimeError(f'set_tx_complete_callback() failed: Device not initialized!')

def pybladerf_open() -> PyBladerfDevice | None:
    cdef PyBladerfDevice pybladerf_device = PyBladerfDevice()

    IF ANDROID:
        result = -7
        bladerf_device_list = get_bladerf_device_list(1)
        if len(bladerf_device_list):
            devinfo = pybladerf_devinfo(backend=pybladerf_backend.PYBLADERF_BACKEND_LIBUSB, instance=bladerf_device_list[0][0])
            result = cbladerf.bladerf_open_with_devinfo(pybladerf_device.get_double_ptr(), devinfo.get_ptr())
    ELSE:
        result = cbladerf.bladerf_open(pybladerf_device.get_double_ptr(), NULL)

    raise_error('pybladerf_open()', result)
    pybladerf_device._setup_device()
    return pybladerf_device

def pybladerf_open_by_serial(desired_serial_number: str) -> PyBladerfDevice | None:
    if desired_serial_number in (None, ''):
        return pybladerf_open()

    cdef PyBladerfDevice pybladerf_device = PyBladerfDevice()
    IF ANDROID:
        result = -7
        bladerf_device_list = get_bladerf_device_list(1)
        if len(bladerf_device_list):
            for file_descriptor, serial_number, manufacturer, product in bladerf_device_list:
                if serial_number == desired_serial_number:
                    devinfo = pybladerf_devinfo(backend=pybladerf_backend.PYBLADERF_BACKEND_LIBUSB, instance=file_descriptor)
                    result = cbladerf.bladerf_open_with_devinfo(pybladerf_device.get_double_ptr(), devinfo.get_ptr())
    ELSE:
        device_identifier = f'*:serial={desired_serial_number}'
        result = cbladerf.bladerf_open(pybladerf_device.get_double_ptr(), device_identifier.encode('utf-8'))

    raise_error('pybladerf_open_by_serial()', result)
    pybladerf_device._setup_device()
    return pybladerf_device

def pybladerf_open_with_devinfo(devinfo: pybladerf_devinfo) -> PyBladerfDevice | None:
    IF ANDROID:
        if devinfo.serial != 'ANY':
            devinfo.usb_addr = 255
            devinfo.usb_bus = 255
            devinfo.backend = pybladerf_backend.PYBLADERF_BACKEND_LIBUSB

            return pybladerf_open_by_serial(devinfo.serial)
        else:
            return pybladerf_open()

    ELSE:
        cdef PyBladerfDevice pybladerf_device = PyBladerfDevice()
        result = cbladerf.bladerf_open_with_devinfo(pybladerf_device.get_double_ptr(), devinfo.get_ptr())

        raise_error('pybladerf_open_with_devinfo()', result)
        pybladerf_device._setup_device()
        return pybladerf_device

def pybladerf_get_devinfo_from_str(devstr: str) -> pybladerf_devinfo:
    cdef pybladerf_devinfo info = pybladerf_devinfo()
    result = cbladerf.bladerf_get_devinfo_from_str(devstr.encode('utf-8'), info.get_ptr())
    raise_error('pybladerf_get_devinfo_from_str()', result)
    return info

def pybladerf_devinfo_matches(a: pybladerf_devinfo, b: pybladerf_devinfo) -> bool:
    return cbladerf.bladerf_devinfo_matches(a.get_ptr(), b.get_ptr())

def pybladerf_devstr_matches(dev_str: str, info: pybladerf_devinfo) -> bool:
    return cbladerf.bladerf_devstr_matches(dev_str.encode('utf-8'), info.get_ptr())

def pybladerf_set_usb_reset_on_open(enabled: bool) -> None:
    cbladerf.bladerf_set_usb_reset_on_open(enabled)

def pybladerf_log_set_verbosity(level: pybladerf_log_level) -> None:
    cbladerf.bladerf_log_set_verbosity(level)

def pybladerf_library_version() -> pybladerf_version:
    cdef pybladerf_version version = pybladerf_version()
    cbladerf.bladerf_library_version(version.get_ptr())
    return version

def python_bladerf_library_version() -> pybladerf_version:
    major, minor, patch = __version__.split('.')
    cdef pybladerf_version version = pybladerf_version(
        int(major),
        int(minor),
        int(patch),
        ''
    )
    return version
