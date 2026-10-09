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
