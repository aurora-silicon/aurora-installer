# Camera tuning and module calibration

The native vendor collector and legacy Python collector accept `appleh13camerad` and `appleh16camerad` from `usr/sbin` or `usr/libexec` of the admitted, read-only recovery image. The fallback archive retains these inputs under their basename so the firmware updater can reproduce the extraction. Duplicate names or tuning records must agree byte for byte.

The extractors recognize the model-wide setfiles required by the shared Linux ISP driver:

| Sensor / firmware | Output | Source bytes | Driver upload bytes |
| --- | --- | ---: | ---: |
| IMX558 / H17 (J700) | `apple/isp_1925_03XX.dat` | `0xcba6` | `0xcbc0` |
| IMX958 (J616s) | `apple/isp_2224_01XX.dat` | `0x6ff4` | `0x6ff4` |

The archive entries are rounded to 64 bytes with zeroes; padding is never copied from the next object in the daemon. Truncated inputs are rejected by the native converter and omitted with a warning by the legacy extractor. Existing legacy setfiles remain available. The native J700 required-file set stays J700-specific; registering J616s tuning does not admit a new board or change source authentication.

These constants are interoperability facts from the public [Linux ISP setfile table](https://github.com/aurora-silicon/linux/blob/8348f8244b208b5185b0764ebb21183a678e9e86/drivers/media/platform/apple/isp/isp-cam.c). No daemon, setfile, plist or factory-record bytes are included in source. Synthetic tests check extraction, padding, truncation and the `usr/libexec` collection path.

Both installers already preserve the current machine's raw Hardware-volume factory records under `com.apple.factorydata/` in `asahi/all_firmware.tar.gz`. That includes `iCCl-<module serial>` when present. These archives belong to that individual installation and must never be distributed. The native collector retains its store/volume identity, ownership, path and read-stability checks.

Preserving iCCl is not calibration upload. The kernel currently has no validated iCCl envelope/payload parser, module-serial binding or firmware command. Keep the raw record local until that contract is established. Do not rename a random record to a global calibration filename, substitute another module's record, or feed iCCl to `CH_SET_FILE_LOAD`, which consumes sensor setfiles.

The kernel's NV12 path already starts CNR, MBNR, temporal filtering and motion history. Its J616s P010 path uses the minimal preview sequence and skips explicit tuning/NR, so image quality can depend on prior NV12 use with resident firmware. Changes to that sequence require command validation and camera A/B captures. The separate ANE ML stage remains future work: auto mode 2, gain entry/exit 2304/1792 for J700 and 3584/2816 for J616s, FPS threshold 30, 30-frame ramp-down. The FPS predicate and gain units still need confirmation.
