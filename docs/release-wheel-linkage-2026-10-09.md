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

## Follow-up: current firmware-stack pairing and live RX1/RX2 smoke

The initial pairing above was superseded on 2026-10-09 after bladeRF fixes
`0cb49567` and `58401a8a` were committed. The fork was rebuilt as
`2.6.1-git-58401a8a`; `/usr/local/lib/libbladeRF.so.2` now has SHA-256
`ae3cd253ab2532f3ba875dc7481a69a1bb161387a67ac4799fc5ef92fc34b7f8`.
The previous installed library was preserved at
`/home/bonho/.local/state/bladerf/system-library-backups/20261009/libbladeRF.so.2.pre-58401a8a`.

A fresh CPython 3.14 no-RPATH wheel was built at
`build/release-wheel-58401a8a/python_bladerf-1.5.0-cp314-cp314-linux_x86_64.whl`
with SHA-256
`55695aaffa1205ac6dde508a48a94b205e57ec8772a2bbea069b7704d37e90ac` and
staged under `build/release-stage-58401a`. `readelf` confirms only a
`NEEDED libbladeRF.so.2` dependency and no RPATH/RUNPATH. With both
`LD_PRELOAD` and `LD_LIBRARY_PATH` unset, the staged wrapper resolves the
updated system library; the 19 RF-event tests pass.

Live xA4 smoke used that same staged wheel and ordinary loader resolution.
On RX1 and RX2 independently, META RX_X1 transitions required PLL locked,
ENSM RX, FPGA epoch valid, and first valid host data. Both completed with
`rx_first_valid_host_data` (event 13), then returned an 8,192-sample
`RX_NOW` capture through the terminal capture-close helper, with no error.
The paired META RX_X2 smoke also passed at 1 Msps with a 64-buffer/32-transfer
ring: `transition_wait` returned `rx_first_valid_host_data` with
`rx_layout=RX_X2`, then terminal capture-close returned 8,192 samples per
lane with no overrun. For a first paired capture, wait on the transition
transaction before issuing a standalone `RX_NOW` read; reading first can
legitimately return `WOULD_BLOCK` while the new epoch remains uncertified.
This is a positive API/linkage and single-capture smoke, not a long-run or LTE
detector release qualification. Startup reports the already-classified
missing FPGA-size/VCTCXO calibration-record warnings; no flash was written.

## Updated event provenance build

After libbladeRF commit `3c6466af` added source epoch and timestamp to
withheld async META events, the system library was rebuilt and installed at
`/usr/local/lib/libbladeRF.so.2` with SHA-256
`e61df9d53fbec1f988dac5255ff9476f20a274c4f484bebb175c573d09f6825a`.
The previous file was backed up before replacement. The existing CPython 3.14
no-RPATH wheel was retained because the public API and ABI did not change;
`ldd` resolves it through the normal loader, with `LD_PRELOAD` and
`LD_LIBRARY_PATH` unset. The staged wheel's 19 RF-event tests pass against the
updated system library.

The matched wheel/system-library pair then completed a production RX_X2 LTE
sweep on xA4 with 200/200 transitions carrying `iq_valid=True`,
`rx_epoch_valid=True`, and first-host-data events. All 100 returns to
1.835 GHz decoded PCI 85 / 100 RB / four ports; all 100 decoy points at
947.5 MHz were rejected as LTE. No short reads or overrun records occurred,
and no target no-PSS dump was produced. Transition latency P50/P95/P99/max
was 23.748/24.896/28.617/29.342 ms. Evidence: scanner report
`/home/bonho/projects/sdr-scanner/docs/reports/rf/lte-release-rxx2-current-candidate-100-20261009.md`.

## Transaction-provenance release candidate

libbladeRF `3c8b7ff4` adds retained-event correlation for stale withheld META
buffers, without changing the Python API or ABI. The installed library SHA-256
is `001d519963a2f6849e7a8b30b64c3a11c5ac7cf9c00b31d059518558a4204c84`.
The staged CPython 3.14 no-RPATH wheel passed all 19 RF-event tests against
this system library with loader overrides unset.

The exact wheel/library pair completed 200/200 valid RX_X2 first-host-data
transitions and 100/100 PCI85/100RB/four-port returns in the production LTE
path. No short reads, overrun records, or target no-PSS frames occurred.
Transition latency P50/P95/P99/max was 23.719/24.513/24.932/25.183 ms. See
`/home/bonho/projects/sdr-scanner/docs/reports/rf/lte-release-rxx2-3c8b7ff4-100-20261009.md`.

## Scheduled-retune callback and release-cache requalification — 2026-10-09

A wrapper audit found `pybladerf_schedule_retune()` called the native API but
raised its result without dispatching the RX invalidation event. The native
library already fenced RX before queueing the retune; Python subscribers now
receive that `RX_DATA_INVALIDATED(reason=frequency)` event on the same wrapper
call. Regression coverage was expanded for dispatch on both success and an
error return. Cython rebuilt and all 21 RF-event tests passed.

The first attempted release wheel reused a developer extension from
`build/lib` and retained its checkout `RUNPATH`, despite release linker flags.
`CustomBuildExt` now forces recompilation whenever
`PYTHON_BLADERF_RELEASE_BUILD=1`, so stale development objects cannot enter a
release wheel. A fresh wheel was rebuilt and staged:

- Wheel: `build/release-wheel-scheduled-retune-clean/python_bladerf-1.5.0-cp314-cp314-linux_x86_64.whl`
- SHA-256: `a2595b0325cb5c5181a2557f42bacfd796d873c5a77ed74b5a70a87e1f5a84b8`
- Staged extension SHA-256: `e2e939e6beb55cc0654fd7ec88003041226b97b937227814bdc1fd831ae45cf4`

`readelf` reports `NEEDED libbladeRF.so.2` and no RPATH/RUNPATH. With
`LD_PRELOAD` and `LD_LIBRARY_PATH` unset and execution from `/tmp`, the import
resolved to the staged extension and the system loader mapped
`/usr/local/lib/libbladeRF.so.2` (SHA-256
`001d519963a2f6849e7a8b30b64c3a11c5ac7cf9c00b31d059518558a4204c84`). The
staged wheel passed all 21 RF-event tests. A live xA4 check using this exact
staged wheel queued an RX1 same-frequency fastlock retune for a future FPGA
timestamp, observed the frequency invalidation in the Python callback before
return, then cancelled the retune successfully. It did not retune the live
radio. Existing FPGA-size/VCTCXO calibration warnings were emitted; no flash
was written.

## RX clipping release pair — 2026-10-09

After adding per-lane RX clipping event support, CMake was reconfigured after
the implementation commits so the library version header matched the source
commit. Installed `/usr/local/lib/libbladeRF.so.2` is now version
`2.6.1-git-e985a454`, SHA-256
`bbac2282a44bb1ea0cf9b6e22f5cf0cda14adb5d88acbab4bb0ae3ff46af4348`. The
previous installed libraries remain backed up at
`/home/bonho/.local/state/bladerf/system-library-backups/20261009/libbladeRF.so.2.pre-rx-clipping`
and `.pre-e985a454`.

The matching CPython 3.14 release wheel is
`build/release-wheel-rx-clipping-e985a454/python_bladerf-1.5.0-cp314-cp314-linux_x86_64.whl`,
SHA-256
`4800cb9306ae93cb844b266fbd964ec37a1a741f0d1c7f29b7edab4ffb092b3a`.
`readelf` shows a `NEEDED libbladeRF.so.2` dependency and no RPATH/RUNPATH;
with loader overrides unset, `ldd` resolves to `/usr/local/lib/libbladeRF.so.2`.
From an isolated staging directory the wheel passes all 21 RF-event tests.

The exact installed-library/wheel pair passed induced clipping on RX1-only,
RX2-only, and dual RX_X2 with the timing-qualified seed-3 sweep image. It also
completed a production RX_X2 LTE smoke at 1.835 GHz (PCI 85, 100 RB, four
antenna ports), plus a native 10,000-transition paired cross-band soak at
4 Msps with zero unrecovered transitions, first-read faults, retries, or
overruns. Full metrics and raw trace are in the scanner clipping report and
the bladeRF RF trace. The archived wideband LTE no-PSS capture remains an
independent open release gate.
