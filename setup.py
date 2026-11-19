#!/usr/bin/env python

from distutils.core import setup

setup(name='aurora_firmware',
      version='0.1',
      description='Aurora firmware tools',
      author='Hector Martin',
      author_email='marcan@marcan.st',
      url='https://github.com/aurora-silicon/aurora-installer/',
      packages=['aurora_firmware'],
      entry_points={"console_scripts": ["aurora-fwextract = aurora_firmware.update:main"]}
     )
