from types import SimpleNamespace

import numpy as np
import pytest

from python_bladerf.sweep_helpers import (
    iq_component_views,
    validate_epoch_block,
)


def test_rx_x1_iq_views_preserve_interleaved_iq():
    samples = np.array([10, 11, 20, 21], dtype=np.int16)
    (i, q), = iq_component_views(samples, False)
    np.testing.assert_array_equal(i, [10, 20])
    np.testing.assert_array_equal(q, [11, 21])


def test_rx_x2_views_split_both_channels_by_timestamp():
    samples = np.array([
        100, 101, 200, 201,
        110, 111, 210, 211,
    ], dtype=np.int16)
    (i0, q0), (i1, q1) = iq_component_views(samples, True)
    np.testing.assert_array_equal(i0, [100, 110])
    np.testing.assert_array_equal(q0, [101, 111])
    np.testing.assert_array_equal(i1, [200, 210])
    np.testing.assert_array_equal(q1, [201, 211])


@pytest.mark.parametrize("dual, samples", [(False, [1]), (True, [1, 2, 3])])
def test_iq_views_reject_partial_channel_frames(dual, samples):
    with pytest.raises(ValueError):
        iq_component_views(np.asarray(samples), dual)


def test_epoch_validation_accepts_only_matching_complete_block():
    metadata = SimpleNamespace(
        actual_count=8, rx_epoch_id=7, timestamp=1000, status=0)
    transition = {"epoch_id": 7, "fpga_timestamp": 1000}
    validate_epoch_block(metadata, transition, 8, 1)


@pytest.mark.parametrize("changes", [
    {"actual_count": 7},
    {"rx_epoch_id": 6},
    {"timestamp": 999},
    {"status": 1},
])
def test_epoch_validation_rejects_invalid_iq(changes):
    fields = {"actual_count": 8, "rx_epoch_id": 7, "timestamp": 1000, "status": 0}
    fields.update(changes)
    metadata = SimpleNamespace(**fields)
    transition = {"epoch_id": 7, "fpga_timestamp": 1000}
    with pytest.raises(RuntimeError):
        validate_epoch_block(metadata, transition, 8, 1)
