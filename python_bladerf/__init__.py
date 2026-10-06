__version__ = '1.5.0'

"""bladeRF Python modules.

Load extension modules on first attribute access. The core Cython extension
imports ``__version__`` while initializing, so eager extension imports here
create a package initialization cycle.
"""

from importlib import import_module

_MODULES = {
    "pybladerf": ".pylibbladerf.pybladerf",
    "pybladerf_transfer": ".pybladerf_tools.pybladerf_transfer",
    "pybladerf_sweep": ".pybladerf_tools.pybladerf_sweep",
    "pybladerf_scan": ".pybladerf_tools.pybladerf_scan",
    "pybladerf_info": ".pybladerf_tools.pybladerf_info",
    "utils": ".pybladerf_tools.utils",
}

__all__ = ["__version__", *_MODULES]


def __getattr__(name):
    module_path = _MODULES.get(name)
    if module_path is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module = import_module(module_path, __name__)
    globals()[name] = module
    return module
