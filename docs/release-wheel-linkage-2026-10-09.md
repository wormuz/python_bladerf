# Release wheel libbladeRF linkage

Date: 2026-10-09

## Defect found

The normal developer build links against the sibling bladeRF fork and embeds
its absolute checkout path in `DT_RUNPATH`. An installed wheel therefore
loaded the right `2.6.1-git-51203bc5` library on this workstation, but depended
on `/home/bonho/projects/bladerf/host/build/output` continuing to exist.
That is not a portable release artifact.

## Change

`PYTHON_BLADERF_RELEASE_BUILD=1` now requires explicit
`PYTHON_BLADERF_CFLAGS` and `PYTHON_BLADERF_LDFLAGS`. The release path does not
add the development RUNPATH; the target system must resolve
`libbladeRF.so.2` through its normal dynamic-loader configuration. The README
documents this build mode and the matching-prefix requirement.

## Qualification

- Building with release mode and missing either flag fails immediately.
- Rebuilt all four Cython extensions using the local fork headers and library
  link directory, without any `-rpath` linker option.
- Built a CPython 3.14 wheel and installed it to a separate staging directory.
- `readelf` reports `NEEDED libbladeRF.so.2` and no `RPATH`/`RUNPATH`.
- Initially, with `LD_PRELOAD` unset and the local library directory on
  `LD_LIBRARY_PATH` for the staging test, import reports
  `2.6.1-git-51203bc5`, maps the fork's `libbladeRF.so.2`, and exposes
  transition begin/wait/event APIs.
- `tests/test_rf_event_notifications.py`: 19 passed.
- Before system installation, the same wheel without either library override
  failed to import because `/usr/local/lib/libbladeRF.so.2` lacked
  `bladerf_rx_transition_get_events`. This confirmed the installed library
  was stale rather than a wheel defect.
- Backed up the old library to
  `/home/bonho/.local/state/bladerf/system-library-backups/20261009/libbladeRF.so.2.pre-event-chain`
  (SHA-256 `bb53d1c7603d833c401d9fa0879dae0ed17b80772c40859a041307f7911ab354`),
  then installed the matching fork library to `/usr/local/lib/libbladeRF.so.2`
  and refreshed the loader cache. The installed file SHA-256 is
  `9ade8b1fac8f957d1d3a15778344e0b109c9d6aa3bb2c24661339defe1b94320`.
- After installation, `ldd` resolves the wheel's `libbladeRF.so.2` to
  `/usr/local/lib/libbladeRF.so.2`. With both `LD_PRELOAD` and
  `LD_LIBRARY_PATH` unset, the staged wheel imports the installed library,
  reports `2.6.1-git-51203bc5`, and passes all 19 event tests.

This closes the Python-wheel/libbladeRF loader and API-pairing gate for this
host. It does not qualify the hardware RX chain.
