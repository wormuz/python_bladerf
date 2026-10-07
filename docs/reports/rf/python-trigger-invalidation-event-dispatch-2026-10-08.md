# Python trigger setters dispatch RX invalidation events

`bladerf_trigger_arm()` and `bladerf_write_trigger()` now invalidate the RX
epoch in libbladeRF before changing trigger controls. The corresponding
Python methods previously raised the native result without draining the RF
event history. A Python caller could therefore retain its old RX validity
certificate after a successful trigger mutation, or miss the invalidation
when the native operation returned an error after recording it.

Both methods now dispatch native RF events immediately after the C call and
before translating its status into a Python exception. The shared helper also
preserves native error mapping. A regression verifies dispatch on success and
that dispatch precedes a `WOULD_BLOCK` exception.

Validation:

- Cython extension rebuilt against `/home/bonho/projects/bladerf/host/libraries/libbladeRF/include` and its production shared library.
- `LD_PRELOAD=/home/bonho/projects/bladerf/host/build/output/libbladeRF.so .venv/bin/python -m pytest -q tests/test_rf_event_notifications.py`: 19 passed.
- `git diff --check`: passed.

This closes wrapper notification delivery for these two trigger configuration
calls. Triggered RF capture and board-level qualification were not run. No
timeout or fixed discard is involved in IQ validity.
