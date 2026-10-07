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
try:
    from pyfftw.interfaces.numpy_fft import fft, fftshift  # type: ignore
except ImportError:
    try:
        from scipy.fft import fft, fftshift  # type: ignore
    except ImportError:
        from numpy.fft import fft, fftshift  # type: ignore

from python_bladerf.pylibbladerf cimport pybladerf as c_pybladerf
from libc.stdint cimport uint64_t, uint32_t, uint16_t, uint8_t
from python_bladerf.pylibbladerf cimport cbladerf
from python_bladerf import pybladerf
from python_bladerf.sweep_helpers import (
    iq_component_views,
    validate_epoch_block,
    validate_transition_layout,
)
from libcpp.atomic cimport atomic
from queue import Queue
cimport numpy as cnp
import numpy as np
import threading
import datetime
cimport cython
import signal
import struct
import time
import sys
import os

cnp.import_array()

FREQ_MIN_MHZ = 70  # 70 MHz
FREQ_MAX_MHZ = 6_000  # 6000 MHZ
FREQ_MIN_HZ = int(FREQ_MIN_MHZ * 1e6)  # Hz
FREQ_MAX_HZ = int(FREQ_MAX_MHZ * 1e6)  # Hz

MIN_SAMPLE_RATE = 520_834
MAX_SAMPLE_RATE = 61_440_000

MIN_BASEBAND_FILTER_BANDWIDTHS = 200_000  # MHz
MAX_BASEBAND_FILTER_BANDWIDTHS = 56_000_000  # MHz

INTERLEAVED_OFFSET_RATIO = 0.375
LINEAR_OFFSET_RATIO = 0.5

cdef atomic[uint8_t] working_sdrs[16]
cdef dict sdr_ids = {}

def sigint_callback_handler(sig, frame, sdr_id):
    global working_sdrs
    working_sdrs[sdr_id].store(0)


def init_signals() -> int:
    global working_sdrs

    sdr_id = -1
    for i in range(16):
        if working_sdrs[i].load() == 0:
            sdr_id = i
            break

    if sdr_id >= 0:
        try:
            signal.signal(signal.SIGINT, lambda sig, frame: sigint_callback_handler(sig, frame, sdr_id))
            signal.signal(signal.SIGILL, lambda sig, frame: sigint_callback_handler(sig, frame, sdr_id))
            signal.signal(signal.SIGTERM, lambda sig, frame: sigint_callback_handler(sig, frame, sdr_id))
            signal.signal(signal.SIGABRT, lambda sig, frame: sigint_callback_handler(sig, frame, sdr_id))
        except Exception as ex:
            sys.stderr.write(f'Error: {ex}\n')

    return sdr_id


def stop_all() -> None:
    global working_sdrs
    for i in range(16):
        working_sdrs[i].store(0)


def stop_sdr(serialno: str) -> None:
    global sdr_ids, working_sdrs
    if serialno in sdr_ids:
        working_sdrs[sdr_ids[serialno]].store(0)


@cython.boundscheck(False)
@cython.wraparound(False)
cpdef void process_data(uint8_t device_id,
                       uint64_t sample_rate,
                       int sweep_style,
                       uint8_t oversample,
                       uint32_t fft_size,
                       uint8_t binary_output,
                       object close_ready,
                       object raw_data_queue,
                       object empty_raw_data_queue,
                       object file,
                       object queue,
                       bint dual_channel,
    ):

    global working_sdrs

    cdef cnp.ndarray window = np.hanning(fft_size)
    cdef double divider = 1 / (128 if oversample else 2048)

    cdef cnp.ndarray data
    cdef cnp.ndarray raw_iq
    cdef cnp.ndarray fft_out
    cdef cnp.ndarray dbfs
    cdef cnp.ndarray pwr
    cdef object components
    cdef object i_samples
    cdef object q_samples
    cdef unsigned int rx_channel
    cdef unsigned int channel_count
    cdef double psd_norm = 1 / (sample_rate * np.dot(window, window))

    cdef uint32_t fft_1_start = 1 + (fft_size * 5) // 8
    cdef uint32_t fft_1_stop = 1 + (fft_size * 5) // 8 + fft_size // 4

    cdef uint32_t fft_2_start = 1 + fft_size // 8
    cdef uint32_t fft_2_stop = 1 + fft_size // 8 + fft_size // 4

    cdef uint64_t frequency = 0
    cdef str time_str

    while working_sdrs[device_id].load() or not raw_data_queue.empty():

        if raw_data_queue.empty():
            if not working_sdrs[device_id].load():
                break
            time.sleep(.035)
            continue

        time_str, frequency, data = raw_data_queue.get()
        components = iq_component_views(data, dual_channel)
        channel_count = 2 if dual_channel else 1

        for rx_channel in range(channel_count):
            i_samples, q_samples = components[rx_channel]
            raw_iq = i_samples * divider + 1j * q_samples * divider
            fft_out = fft((raw_iq - raw_iq.mean()) * window)
            dbfs = np.log10(
                (fft_out.real**2 + fft_out.imag**2) * psd_norm + 1e-300
            ) * 10.0
            pwr = dbfs

            if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_LINEAR:
                pwr = fftshift(dbfs)

            if binary_output:
                channel_header = struct.pack('I', rx_channel) if dual_channel else b''
                header_bytes = 20 if dual_channel else 16
                if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED:
                    record_length = header_bytes + (fft_size // 4) * 4
                    line = struct.pack('I', record_length) + channel_header
                    line += struct.pack('Q', frequency)
                    line += struct.pack('Q', frequency + sample_rate // 4)
                    line += struct.pack('<' + 'f' * (fft_size // 4), *pwr[fft_1_start:fft_1_stop])
                    line += struct.pack('I', record_length) + channel_header
                    line += struct.pack('Q', frequency + sample_rate // 2)
                    line += struct.pack('Q', frequency + (sample_rate * 3) // 4)
                    line += struct.pack('<' + 'f' * (fft_size // 4), *pwr[fft_2_start:fft_2_stop])
                else:
                    record_length = header_bytes + fft_size * 4
                    line = struct.pack('I', record_length) + channel_header
                    line += struct.pack('Q', frequency)
                    line += struct.pack('Q', frequency + sample_rate)
                    line += struct.pack('<' + 'f' * fft_size, *pwr)
                file.write(line)

            elif queue is not None:
                channel_field = {'channel': rx_channel} if dual_channel else {}
                if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED:
                    queue.put({
                        'timestamp': time_str,
                        'start_frequency': frequency,
                        'stop_frequency': frequency + sample_rate // 4,
                        'dbfs': pwr[fft_1_start:fft_1_stop].astype(np.float32),
                        **channel_field,
                    })
                    queue.put({
                        'timestamp': time_str,
                        'start_frequency': frequency + sample_rate // 2,
                        'stop_frequency': frequency + (sample_rate * 3) // 4,
                        'dbfs': pwr[fft_2_start:fft_2_stop].astype(np.float32),
                        **channel_field,
                    })
                else:
                    queue.put({
                        'timestamp': time_str,
                        'start_frequency': frequency,
                        'stop_frequency': frequency + sample_rate,
                        'dbfs': pwr.astype(np.float32),
                        **channel_field,
                    })

            else:
                channel_prefix = f'RX{rx_channel + 1}, ' if dual_channel else ''
                if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED:
                    for start_frequency, stop_frequency, bins in (
                        (frequency, frequency + sample_rate // 4,
                         pwr[fft_1_start:fft_1_stop]),
                        (frequency + sample_rate // 2,
                         frequency + (sample_rate * 3) // 4,
                         pwr[fft_2_start:fft_2_stop]),
                    ):
                        line = f'{channel_prefix}{time_str}, {start_frequency}, {stop_frequency}, {sample_rate / fft_size}, {fft_size}, '
                        for value in bins:
                            line += f'{value:.10f}, '
                        file.write(line[:len(line) - 2] + '\n')
                else:
                    line = f'{channel_prefix}{time_str}, {frequency}, {frequency + sample_rate}, {sample_rate / fft_size}, {fft_size}, '
                    for value in pwr:
                        line += f'{value:.2f}, '
                    file.write(line[:len(line) - 2] + '\n')

        # Do not return storage to the producer until both channel FFTs finish.
        empty_raw_data_queue.put(data)

    close_ready.set()


def pybladerf_sweep(frequencies: list[int] | None = None, sample_rate: int = 61_000_000, baseband_filter_bandwidth: int | None = None,
                    gain: int = 20, bin_width: int = 100_000, channel: int = 0, oversample: bool = False, antenna_enable: bool = False,
                    sweep_style: pybladerf.pybladerf_sweep_style = pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED, serial_number: str | None = None,
                    binary_output: bool = False, one_shot: bool = False, num_sweeps: int | None = None,
                    filename: str | None = None, queue: object | None = None,
                    print_to_console: bool = True,
                    dual_channel: bool = False,
                    ) -> None:

    global working_sdrs, sdr_ids

    cdef uint8_t device_id = init_signals()
    cdef uint8_t formated_channel = pybladerf.PYBLADERF_CHANNEL_RX(
        0 if dual_channel else channel)
    cdef uint8_t second_channel = pybladerf.PYBLADERF_CHANNEL_RX(1)
    cdef object stream_layout
    cdef c_pybladerf.PyBladerfDevice device
    cdef uint64_t offset = 0

    if serial_number is None:
        device = pybladerf.pybladerf_open()
    else:
        device = pybladerf.pybladerf_open_by_serial(serial_number)

    working_sdrs[device_id].store(1)
    sdr_ids[device.serialno] = device_id

    device.pybladerf_enable_feature(pybladerf.pybladerf_feature.PYBLADERF_FEATURE_OVERSAMPLE, False)

    if oversample:
        sample_rate = int(sample_rate) if MIN_SAMPLE_RATE * 2 <= int(sample_rate) <= MAX_SAMPLE_RATE * 2 else 122_000_000
    else:
        sample_rate = int(sample_rate) if MIN_SAMPLE_RATE <= int(sample_rate) <= MAX_SAMPLE_RATE else 61_000_000

    real_min_freq_hz = FREQ_MIN_HZ - sample_rate // 2
    real_max_freq_hz = FREQ_MAX_HZ + sample_rate // 2

    if baseband_filter_bandwidth is None:
        baseband_filter_bandwidth = int(sample_rate * .75)
    baseband_filter_bandwidth = int(baseband_filter_bandwidth) if MIN_BASEBAND_FILTER_BANDWIDTHS <= int(baseband_filter_bandwidth) <= MAX_BASEBAND_FILTER_BANDWIDTHS else int(sample_rate * .75)

    if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED:
        offset = int(sample_rate * INTERLEAVED_OFFSET_RATIO)
    else:
        offset = int(sample_rate * LINEAR_OFFSET_RATIO)

    if frequencies is None:
        frequencies = [int(FREQ_MIN_MHZ - sample_rate // 2e6), int(FREQ_MAX_MHZ + sample_rate // 2e6)]

    if print_to_console:
        sys.stderr.write(f'call pybladerf_set_tuning_mode({pybladerf.pybladerf_tuning_mode.PYBLADERF_TUNING_MODE_FPGA})\n')
    device.pybladerf_set_tuning_mode(pybladerf.pybladerf_tuning_mode.PYBLADERF_TUNING_MODE_FPGA)

    if oversample:
        if print_to_console:
            sys.stderr.write(f'call pybladerf_enable_feature({pybladerf.pybladerf_feature.PYBLADERF_FEATURE_OVERSAMPLE}, True)\n')
        device.pybladerf_enable_feature(pybladerf.pybladerf_feature.PYBLADERF_FEATURE_OVERSAMPLE, True)

    if print_to_console:
        sys.stderr.write(f'call pybladerf_set_sample_rate({sample_rate / 1e6 :.3f} MHz)\n')
    device.pybladerf_set_sample_rate(formated_channel, sample_rate)
    if dual_channel:
        device.pybladerf_set_sample_rate(second_channel, sample_rate)

    if not oversample:
        if print_to_console:
            sys.stderr.write(f'call pybladerf_set_bandwidth({formated_channel}, {baseband_filter_bandwidth / 1e6 :.3f} MHz)\n')
        device.pybladerf_set_bandwidth(formated_channel, baseband_filter_bandwidth)
        if dual_channel:
            device.pybladerf_set_bandwidth(second_channel, baseband_filter_bandwidth)

    if print_to_console:
        sys.stderr.write(f'call pybladerf_set_gain_mode({formated_channel}, {pybladerf.pybladerf_gain_mode.PYBLADERF_GAIN_MGC})\n')
    device.pybladerf_set_gain_mode(formated_channel, pybladerf.pybladerf_gain_mode.PYBLADERF_GAIN_MGC)
    device.pybladerf_set_gain(formated_channel, gain)
    if dual_channel:
        device.pybladerf_set_gain_mode(second_channel, pybladerf.pybladerf_gain_mode.PYBLADERF_GAIN_MGC)
        device.pybladerf_set_gain(second_channel, gain)

    if antenna_enable:
        if print_to_console:
            sys.stderr.write(f'call pybladerf_set_bias_tee({formated_channel}, True)\n')
        device.pybladerf_set_bias_tee(formated_channel, True)
        if dual_channel:
            device.pybladerf_set_bias_tee(second_channel, True)

    num_ranges = len(frequencies) // 2
    calculated_frequencies = []

    for i in range(num_ranges):
        frequencies[2 * i] = int(frequencies[2 * i] * 1e6)
        frequencies[2 * i + 1] = int(frequencies[2 * i + 1] * 1e6)

        if frequencies[2 * i] >= frequencies[2 * i + 1]:
            device.pybladerf_close()
            raise RuntimeError('max frequency must be greater than min frequency.')

        step_count = 1 + (frequencies[2 * i + 1] - frequencies[2 * i] - 1) // sample_rate
        frequencies[2 * i + 1] = int(frequencies[2 * i] + step_count * sample_rate)

        if frequencies[2 * i] < real_min_freq_hz:
            device.pybladerf_close()
            raise RuntimeError(f'min frequency must must be greater than {int(real_min_freq_hz / 1e6)} MHz.')
        if frequencies[2 * i + 1] > real_max_freq_hz:
            device.pybladerf_close()
            raise RuntimeError(f'max frequency may not be higher {int(real_max_freq_hz / 1e6)} MHz.')

        frequency = frequencies[2 * i]
        if sweep_style == pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED:
            for j in range(step_count * 2):
                calculated_frequencies.append(frequency)
                if j % 2 == 0:
                    frequency += int(sample_rate / 4)
                else:
                    frequency += int(3 * sample_rate / 4)
        else:
            for j in range(step_count):
                calculated_frequencies.append(frequency)
                frequency += sample_rate

        if print_to_console:
            sys.stderr.write(f'Sweeping from {frequencies[2 * i] / 1e6} MHz to {frequencies[2 * i + 1] / 1e6} MHz\n')

    if len(calculated_frequencies) > 256:
        device.pybladerf_close()
        raise RuntimeError('Reached maximum number of RX quick tune profiles. Please reduce the frequency range or increase the sample rate.')

    cdef uint32_t fft_size = int(sample_rate / bin_width)
    if fft_size < 4:
        device.pybladerf_close()
        raise RuntimeError(f'bin_width should be no more than {sample_rate // 4} Hz')

    while ((fft_size + 4) % 8):
        fft_size += 1

    quick_tunes = []
    for frequency in calculated_frequencies:
        device.pybladerf_set_frequency(formated_channel, frequency + offset)

        quick_tune = device.pybladerf_get_quick_tune(formated_channel)
        quick_tunes.append((frequency, quick_tune))

    raw_data_queue = Queue()
    empty_raw_data_queue = Queue()

    file = open(filename, 'w' if not binary_output else 'wb') if filename is not None else (sys.stdout.buffer if binary_output else sys.stdout)
    close_ready = threading.Event()

    device.pybladerf_set_rfic_rx_fir(pybladerf.pybladerf_rfic_rxfir.PYBLADERF_RFIC_RXFIR_BYPASS)
    stream_layout = (
        pybladerf.pybladerf_channel_layout.PYBLADERF_RX_X2 if dual_channel
        else pybladerf.pybladerf_channel_layout.PYBLADERF_RX_X1)
    device.pybladerf_sync_config(
        layout=stream_layout,
        data_format=pybladerf.pybladerf_format.PYBLADERF_FORMAT_SC8_Q7_META if oversample else pybladerf.pybladerf_format.PYBLADERF_FORMAT_SC16_Q11_META,
        num_buffers=int(os.environ.get('pybladerf_sweep_num_buffers', 16)),
        buffer_size=int(os.environ.get('pybladerf_sweep_buffer_size', 65536)),
        num_transfers=int(os.environ.get('pybladerf_sweep_num_transfers', 8)),
        stream_timeout=0,
    )
    device.pybladerf_enable_module(formated_channel, True)
    if dual_channel:
        device.pybladerf_enable_module(second_channel, True)

    processing_thread = threading.Thread(target=process_data, args=(
        device_id,
        sample_rate,
        sweep_style if sweep_style in pybladerf.pybladerf_sweep_style else pybladerf.pybladerf_sweep_style.PYBLADERF_SWEEP_STYLE_INTERLEAVED,
        1 if oversample else 0,
        fft_size,
        1 if binary_output else 0,
        close_ready,
        raw_data_queue,
        empty_raw_data_queue,
        file,
        queue,
        dual_channel,
    ), daemon=True)
    processing_thread.start()

    cdef uint16_t tune_steps = len(calculated_frequencies)

    cdef double time_start = time.time()
    cdef double time_prev = time.time()
    cdef uint8_t rffe_profiles = min(8, tune_steps)

    cdef uint64_t accepted_samples = 0
    cdef double time_difference = 0
    cdef uint64_t sweep_count = 0
    cdef uint16_t tune_step = 0
    cdef double sweep_rate = 0
    cdef double time_now = 0

    cdef uint32_t transaction_id
    cdef uint32_t transition_timeout_ms = int(
        os.environ.get('pybladerf_sweep_transition_timeout_ms', 1000))
    cdef uint32_t rx_sample_count
    cdef dict transition
    cdef object paired_sync_read_error = None
    cdef uint32_t required_events = pybladerf.RF_REQUIRE_EPOCH_VALID
    cdef cnp.ndarray buffer
    rx_sample_count = fft_size * (2 if dual_channel else 1)
    if dual_channel:
        required_events |= pybladerf.RF_REQUIRE_RX_X2_HOST_DATA

    cdef bint buffer_checked_out = False

    while working_sdrs[device_id].load():
        quick_tune = quick_tunes[tune_step][1]
        quick_tune.rffe_profile = tune_step % rffe_profiles
        try:
            transaction_id = device.pybladerf_rx_transition_begin(
                formated_channel,
                quick_tunes[tune_step][0] + offset,
                required_events,
                transition_timeout_ms,
                True,
                quick_tune,
            )
            if empty_raw_data_queue.empty():
                # One complex sample has two scalar components. RX_X2 returns
                # both channels in each time frame, doubling the scalar count.
                buffer = np.empty(
                    rx_sample_count * 2,
                    dtype=np.int8 if oversample else np.int16)
            else:
                buffer = empty_raw_data_queue.get()
            buffer_checked_out = True

            meta = pybladerf.pybladerf_metadata(
                flags=pybladerf.PYBLADERF_META_FLAG_RX_NOW)
            if dual_channel:
                # The paired host-data requirement is satisfied by the first
                # sync read. Keep that validated block for the detector path;
                # transition_wait then confirms its transaction and layout.
                paired_sync_read_error = None
                try:
                    device.pybladerf_sync_rx(
                        buffer, rx_sample_count, meta, transition_timeout_ms)
                except Exception as exc:
                    # Always retire the RF transaction through wait(), even
                    # when the concurrent data consumer fails. A read error
                    # can never be promoted to transition success.
                    paired_sync_read_error = exc
                transition = device.pybladerf_rx_transition_wait(
                    transaction_id, transition_timeout_ms)
                validate_transition_layout(transition, True)
                if paired_sync_read_error is not None:
                    raise paired_sync_read_error
            else:
                transition = device.pybladerf_rx_transition_wait(
                    transaction_id, transition_timeout_ms)
                validate_transition_layout(transition, False)
                device.pybladerf_sync_rx(buffer, rx_sample_count, meta, 0)
            validate_epoch_block(
                meta, transition, rx_sample_count,
                pybladerf.PYBLADERF_META_STATUS_OVERRUN)

            raw_data_queue.put((
                datetime.datetime.now().strftime('%Y-%m-%d, %H:%M:%S.%f'),
                quick_tunes[tune_step][0],
                buffer,
            ))
            buffer_checked_out = False

            tune_step = (tune_step + 1) % tune_steps
            if tune_step == 0:
                sweep_count += 1
                if one_shot or num_sweeps == sweep_count:
                    working_sdrs[device_id].store(0)

            accepted_samples += rx_sample_count

        except pybladerf.PYBLADERF_ERR as ex:
            if buffer_checked_out:
                empty_raw_data_queue.put(buffer)
                buffer_checked_out = False
            sys.stderr.write(
                f"RX transition/read failed: {cbladerf.bladerf_strerror(ex.code)} "
                f"({ex.code}); sweep stopped without accepting this block\n")
            working_sdrs[device_id].store(0)
            break
        except Exception as ex:
            if buffer_checked_out:
                empty_raw_data_queue.put(buffer)
                buffer_checked_out = False
            sys.stderr.write(
                f"RX transition/read failed: {ex}; sweep stopped without "
                "accepting this block\n")
            working_sdrs[device_id].store(0)
            break

        time_now = time.time()
        time_difference = time_now - time_prev
        if time_difference >= 1.0:
            if print_to_console:
                sweep_rate = sweep_count / (time_now - time_start)
                sys.stderr.write(f'{sweep_count} total sweeps completed, {round(sweep_rate, 2)} sweeps/second\n')

            if accepted_samples == 0:
                if print_to_console:
                    sys.stderr.write("Couldn\'t transfer any data for one second.\n")
                break

            accepted_samples = 0
            time_prev = time_now

    if print_to_console:
        if not working_sdrs[device_id].load():
            sys.stderr.write('\nExiting...\n')
        else:
            sys.stderr.write('\nExiting... [ pybladerf streaming stopped ]\n')

    working_sdrs[device_id].store(0)
    close_ready.wait()
    sdr_ids.pop(device.serialno, None)

    if filename is not None:
        file.close()

    time_now = time.time()
    time_difference = time_now - time_prev
    if sweep_rate == 0 and time_difference > 0:
        sweep_rate = sweep_count / (time_now - time_start)

    if print_to_console:
        sys.stderr.write(f'Total sweeps: {sweep_count} in {time_now - time_start:.5f} seconds ({sweep_rate :.2f} sweeps/second)\n')

    if antenna_enable:
        try:
            device.pybladerf_set_bias_tee(formated_channel, False)
            if dual_channel:
                device.pybladerf_set_bias_tee(second_channel, False)
        except Exception as ex:
                sys.stderr.write(f'{ex}\n')

    try:
        device.pybladerf_enable_module(formated_channel, False)
        if dual_channel:
            device.pybladerf_enable_module(second_channel, False)
    except Exception as ex:
            sys.stderr.write(f'{ex}\n')

    try:
        device.pybladerf_close()
        if print_to_console:
            sys.stderr.write('pybladerf_close() done\n')
    except Exception as ex:
        sys.stderr.write(f'{ex}\n')
