"""Small, testable helpers for channel-aware bladeRF sweep processing."""

from __future__ import annotations

import numpy as np


def iq_component_views(samples: np.ndarray, dual_channel: bool):
    """Return ``(I, Q)`` vector views for each channel in an RX buffer.

    SC16/SC8 complex samples are I/Q interleaved. RX_X2 interleaves channel
    samples by timestamp, so its scalar order is I0,Q0,I1,Q1.
    """
    flat = np.asarray(samples).reshape(-1)
    if dual_channel:
        if flat.size % 4:
            raise ValueError("RX_X2 buffer must contain complete I0,Q0,I1,Q1 groups")
        return ((flat[0::4], flat[1::4]), (flat[2::4], flat[3::4]))

    if flat.size % 2:
        raise ValueError("RX_X1 buffer must contain complete I,Q pairs")
    return ((flat[0::2], flat[1::2]),)


def validate_epoch_block(metadata, transition, expected_samples: int,
                         overrun_status: int) -> None:
    """Fail closed unless sync RX returned the transition's valid IQ block."""
    if metadata.actual_count != expected_samples:
        raise RuntimeError(
            f"short RX block: {metadata.actual_count}/{expected_samples} samples")
    if metadata.rx_epoch_id is None or metadata.rx_epoch_id != transition["epoch_id"]:
        raise RuntimeError("RX block epoch does not match completed transition")
    if metadata.timestamp < transition["fpga_timestamp"]:
        raise RuntimeError("RX block timestamp precedes the certified epoch boundary")
    if metadata.status & overrun_status:
        raise RuntimeError("RX block reports an overrun; IQ block rejected")


def validate_transition_layout(transition, require_rx_x2: bool) -> None:
    """Require the transition result to match the requested RX stream layout."""
    if require_rx_x2:
        if (transition.get("event_name") != "rx_first_valid_host_data" or
                transition.get("rx_layout") != "RX_X2"):
            raise RuntimeError(
                "paired RX transition did not confirm validated RX_X2 host data")
    elif transition.get("event_name") != "rx_epoch_valid":
        raise RuntimeError(
            f"RX transition ended at {transition.get('event_name')}")
