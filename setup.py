import subprocess  # noqa I001
import sys
from os import environ, getenv, path

import numpy
from setuptools import Extension, find_packages, setup
from setuptools.command.install import install
from setuptools.command.build_ext import build_ext
from Cython.Build import cythonize

INSTALL_REQUIRES = ['Cython>=3.1.0,<3.2.1', 'numpy']
SETUP_REQUIRES = ['Cython>=3.1.0,<3.2.1', 'numpy']
libbladerf_h_paths = []
libbladerf_link_args = []

# The .pxd files carry the layout of PyBladerfDevice and the libbladeRF
# declarations. Without them in depends, editing a .pxd leaves the modules that
# cimport it compiled against the old struct layout, which shows up at import
# time as "PyBladerfDevice size changed, may indicate binary incompatibility"
# and then as a segfault.
PXD_DEPENDS = [
    'python_bladerf/pylibbladerf/pybladerf.pxd',
    'python_bladerf/pylibbladerf/cbladerf.pxd',
]

PLATFORM = sys.platform

if getenv('LIBLINK'):
    PLATFORM = 'android'

if PLATFORM != 'android':
    if getenv('PYTHON_BLADERF_RELEASE_BUILD') == '1':
        missing_flags = [
            name for name in ('PYTHON_BLADERF_CFLAGS', 'PYTHON_BLADERF_LDFLAGS')
            if not getenv(name)
        ]
        if missing_flags:
            raise RuntimeError(
                'PYTHON_BLADERF_RELEASE_BUILD=1 requires explicit '
                + ' and '.join(missing_flags)
                + '; provide the matching libbladeRF headers and link flags '
                'without a development RUNPATH'
            )

    cflags = environ.get('CFLAGS', '')
    ldflags = environ.get('LDFLAGS', '')
    new_cflags = ''
    new_ldflags = ''

    if PLATFORM in {'linux', 'darwin'}:
        # In the local multi-repository checkout, always build the wrapper
        # against the sibling bladeRF fork. pkg-config commonly points at an
        # older system install, which can silently produce an extension with
        # missing symbols or mismatched event enums. Explicit environment
        # overrides still take precedence for packaging/release builds.
        local_bladerf_root = path.abspath(
            path.join(path.dirname(__file__), '..', 'bladerf'))
        local_bladerf_include = path.join(
            local_bladerf_root, 'host', 'libraries', 'libbladeRF', 'include')
        local_bladerf_lib = path.join(
            local_bladerf_root, 'host', 'build', 'output')
        local_bladerf_available = path.isfile(
            path.join(local_bladerf_lib, 'libbladeRF.so'))

        if environ.get('PYTHON_BLADERF_CFLAGS', None) is None:
            if local_bladerf_available:
                new_cflags = f'-I{local_bladerf_include}'
                libbladerf_h_paths = [local_bladerf_include]
            else:
                try:
                    new_cflags = subprocess.check_output(
                        ['pkg-config', '--cflags', 'libbladeRF']).decode(
                            'utf-8').strip()
                    libbladerf_h_paths = [new_cflag[2:] for new_cflag in new_cflags.split()]
                except Exception:
                    raise RuntimeError(
                        'Unable to run pkg-config. Set cflags manually '
                        'export PYTHON_BLADERF_CFLAGS=') from None
        else:
            new_cflags = environ.get('PYTHON_BLADERF_CFLAGS', '')
            libbladerf_h_paths = [new_cflag[2:] for new_cflag in new_cflags.split()]

        if environ.get('PYTHON_BLADERF_LDFLAGS', None) is None:
            if local_bladerf_available:
                new_ldflags = (
                    f'-L{local_bladerf_lib} -lbladeRF '
                    f'-Wl,-rpath,{local_bladerf_lib}')
            else:
                try:
                    new_ldflags = subprocess.check_output(
                        ['pkg-config', '--libs', 'libbladeRF']).decode(
                            'utf-8').strip()
                except Exception:
                    raise RuntimeError(
                        'Unable to run pkg-config. Set libs manually '
                        'export PYTHON_BLADERF_LDFLAGS=') from None
        else:
            new_ldflags = environ.get('PYTHON_BLADERF_LDFLAGS', '')
        # Put library arguments after extension object files. Passing these
        # through LDFLAGS places them before the objects on setuptools' link
        # command; with --as-needed, libbladeRF is then dropped from DT_NEEDED.
        libbladerf_link_args = new_ldflags.split()

    elif PLATFORM.startswith('win'):
        include_path = 'C:\\Program Files\\BladeRF\\include'
        lib_path = 'C:\\Program Files\\BladeRF\\lib'
        libbladerf_h_paths = [include_path]

        if environ.get('PYTHON_BLADERF_INCLUDE_PATH', None) is None:
            new_cflags = f'-I"{include_path}"'
        else:
            include_path = environ.get('PYTHON_BLADERF_INCLUDE_PATH', '')
            new_cflags = f'-I"{include_path}"'
            libbladerf_h_paths = [include_path]

        if environ.get('PYTHON_BLADERF_LIB_PATH', None) is None:
            new_ldflags = f'-L"{lib_path}" -lbladeRF'
        else:
            lib_path = environ.get('PYTHON_BLADERF_LIB_PATH', '')
            new_ldflags = f'-L"{lib_path}" -lbladeRF'

        environ['CL'] = f'/I"{include_path}"'
        environ['LINK'] = f'/LIBPATH:"{lib_path}" bladeRF.lib'

    environ['CFLAGS'] = f'{cflags} {new_cflags}'.strip()
    environ['LDFLAGS'] = ldflags

else:
    libbladerf_h_paths = [environ.get('PYTHON_BLADERF_LIBBLADERF_H_PATH', '')]


class CustomBuildExt(build_ext):
    def run(self) -> None:  # type: ignore
        # A release build must never reuse developer objects from build/lib.
        # In particular, an extension previously linked with the sibling
        # checkout RUNPATH would otherwise be copied unchanged into a
        # nominally no-RPATH release wheel even when release linker flags are
        # supplied. Re-link every extension under the selected build mode.
        if getenv('PYTHON_BLADERF_RELEASE_BUILD') == '1':
            self.force = True

        compile_env = {'ANDROID': PLATFORM == 'android'}
        self.distribution.ext_modules = cythonize(  # type: ignore
            self.distribution.ext_modules,
            compile_time_env=compile_env,
        )
        # `build_ext.__init__` captured the original `.pyx` extensions
        # before the call above. Refresh its command-local copy as well;
        # otherwise Cython's build_ext cythonizes those stale entries a
        # second time without the compile-time environment (ANDROID).
        self.extensions = self.distribution.ext_modules
        # Setuptools 80 expects this attribute on Extension instances, but
        # Cython 3.2's `cythonize()` returns plain setuptools Extension
        # objects when sources have already been converted to C++.
        for ext in self.extensions:
            if not hasattr(ext, '_needs_stub'):
                ext._needs_stub = False
        super().run()  # type: ignore


class InstallWithPth(install):
    def run(self) -> None:  # type: ignore
        super().run()  # type: ignore

        if PLATFORM.startswith('win'):
            pth_code = (
                'import os; '
                'os.add_dll_directory(os.getenv("BLADERF_LIB_DIR", r"C:\\Program Files\\BladeRF\\lib"))'
            )
            with open(path.join(self.install_lib, "python_bladerf.pth"), mode='w', encoding='utf-8') as file:  # type: ignore
                file.write(pth_code)


setup(  # type: ignore
    name='python_bladerf',
    cmdclass={'build_ext': CustomBuildExt, 'install': InstallWithPth},
    install_requires=INSTALL_REQUIRES,
    setup_requires=SETUP_REQUIRES,
    ext_modules=[
        Extension(  # type: ignore
            name='python_bladerf.pylibbladerf.pybladerf',
            sources=['python_bladerf/pylibbladerf/pybladerf.pyx'],
            include_dirs=['python_bladerf/pylibbladerf', *libbladerf_h_paths, numpy.get_include()],
            extra_compile_args=['-w'],
            extra_link_args=libbladerf_link_args,
            depends=PXD_DEPENDS,
            language='c++',
        ),
        Extension(  # type: ignore
            name='python_bladerf.pybladerf_tools.pybladerf_sweep',
            sources=['python_bladerf/pybladerf_tools/pybladerf_sweep.pyx'],
            include_dirs=['python_bladerf/pylibbladerf', 'python_bladerf/pybladerf_tools', *libbladerf_h_paths, numpy.get_include()],
            extra_compile_args=['-w'],
            extra_link_args=libbladerf_link_args,
            depends=PXD_DEPENDS,
            language='c++',
        ),
        Extension(  # type: ignore
            name='python_bladerf.pybladerf_tools.pybladerf_scan',
            sources=['python_bladerf/pybladerf_tools/pybladerf_scan.pyx'],
            include_dirs=['python_bladerf/pylibbladerf', 'python_bladerf/pybladerf_tools', *libbladerf_h_paths, numpy.get_include()],
            extra_compile_args=['-w'],
            extra_link_args=libbladerf_link_args,
            depends=PXD_DEPENDS,
            language='c++',
        ),
        Extension(  # type: ignore
            name='python_bladerf.pybladerf_tools.pybladerf_transfer',
            sources=['python_bladerf/pybladerf_tools/pybladerf_transfer.pyx'],
            include_dirs=['python_bladerf/pylibbladerf', 'python_bladerf/pybladerf_tools', *libbladerf_h_paths, numpy.get_include()],
            extra_compile_args=['-w'],
            extra_link_args=libbladerf_link_args,
            depends=PXD_DEPENDS,
            language='c++',
        ),
    ],
    include_package_data=True,
    packages=find_packages(),
    package_dir={'': '.'},
    zip_safe=False,
)
