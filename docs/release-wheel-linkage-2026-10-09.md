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
- With `LD_PRELOAD` unset and the local library directory on
  `LD_LIBRARY_PATH` for this staging test, import reports
  `2.6.1-git-51203bc5`, maps the fork's `libbladeRF.so.2`, and exposes
  transition begin/wait/event APIs.
- `tests/test_rf_event_notifications.py`: 19 passed.

This proves wheel linkage and API pairing in a staged install. The final
system-install check, with libbladeRF installed in a standard loader path and
without `LD_LIBRARY_PATH`, remains a release gate. This is not a hardware
qualification.
