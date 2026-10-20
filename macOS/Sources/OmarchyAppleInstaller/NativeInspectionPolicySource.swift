#if os(macOS)
  // Source-pinned inspection policy extracted from the retained runtime.
  // This table admits backend capability; the signed catalog separately
  // admits the selected public release and model qualification.
  enum NativeInspectionPolicySource {
    static let json = #"""
      {
        "baselineMetadata": {
          "os_list": [
            {
              "boot_object": "m1n1.bin",
              "default_os_name": "Omarchy",
              "icon": "omarchy-volume.icns",
              "name": "Omarchy MX Mac",
              "next_object": "m1n1/boot.bin",
              "omarchy_target": "apple-silicon-full-os",
              "package": "omarchy-2026.09.02-aarch64-apple-silicon-asahi-os-package.zip",
              "partitions": [
                {
                  "copy_firmware": true,
                  "copy_installer_data": true,
                  "format": "fat",
                  "name": "EFI",
                  "size": "524288000B",
                  "source": "esp",
                  "type": "EFI",
                  "volume_id": "0x4f4d5801"
                },
                {
                  "image": "boot.img",
                  "name": "Boot",
                  "size": "2147483648B",
                  "type": "Linux"
                },
                {
                  "expand": true,
                  "image": "root.img",
                  "name": "Root",
                  "size": "34359738368B",
                  "type": "Linux"
                }
              ],
              "supported_fw": [
                "13.5",
                "14.8.3"
              ]
            }
          ]
        },
        "chipMinimum": {
          "24576": "12.0",
          "24577": "12.0",
          "24578": "12.3",
          "24608": "13.1",
          "24609": "13.1",
          "24610": "13.4",
          "24624": "14.8.3",
          "24625": "14.8.3",
          "24628": "14.8.3",
          "33027": "11.0",
          "33042": "12.4",
          "33058": "14.8.3",
          "33088": "26.6"
        },
        "devices": {
          "j180d": {
            "expert": false,
            "minimum": "13.4"
          },
          "j274": {
            "expert": false,
            "minimum": "11.0"
          },
          "j293": {
            "expert": false,
            "minimum": "11.0"
          },
          "j313": {
            "expert": false,
            "minimum": "11.0"
          },
          "j314c": {
            "expert": false,
            "minimum": "12.0"
          },
          "j314s": {
            "expert": false,
            "minimum": "12.0"
          },
          "j316c": {
            "expert": false,
            "minimum": "12.0"
          },
          "j316s": {
            "expert": false,
            "minimum": "12.0"
          },
          "j375c": {
            "expert": false,
            "minimum": "12.3"
          },
          "j375d": {
            "expert": false,
            "minimum": "12.3"
          },
          "j413": {
            "expert": false,
            "minimum": "12.4"
          },
          "j414c": {
            "expert": false,
            "minimum": "13.2"
          },
          "j414s": {
            "expert": false,
            "minimum": "13.2"
          },
          "j415": {
            "expert": false,
            "minimum": "13.4"
          },
          "j416c": {
            "expert": false,
            "minimum": "13.2"
          },
          "j416s": {
            "expert": false,
            "minimum": "13.2"
          },
          "j433": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j434": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j456": {
            "expert": false,
            "minimum": "11.3"
          },
          "j457": {
            "expert": false,
            "minimum": "11.3"
          },
          "j473": {
            "expert": false,
            "minimum": "13.2"
          },
          "j474s": {
            "expert": false,
            "minimum": "13.2"
          },
          "j475c": {
            "expert": false,
            "minimum": "13.4"
          },
          "j475d": {
            "expert": false,
            "minimum": "13.4"
          },
          "j493": {
            "expert": false,
            "minimum": "12.4"
          },
          "j504": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j514c": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j514m": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j514s": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j516c": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j516m": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j516s": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j613": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j615": {
            "expert": false,
            "minimum": "14.8.3"
          },
          "j700": {
            "expert": false,
            "minimum": "26.6"
          }
        },
        "firmware": [
          {
            "expert": false,
            "minimumBoot": "mBoot-18000.161.9",
            "minimumMacOS": "26.0",
            "minimumRecovery": "25.7.72.0.0,0",
            "models": [
              "j700"
            ],
            "version": "26.6"
          },
          {
            "expert": false,
            "minimumBoot": "mBoot-18000.161.10",
            "minimumMacOS": "26.0",
            "minimumRecovery": "25.7.83.0.0,0",
            "models": [
              "j613",
              "j615",
              "j700"
            ],
            "version": "26.6.2"
          },
          {
            "expert": false,
            "minimumBoot": "iBoot-7459.101.3",
            "minimumMacOS": "12.1",
            "minimumRecovery": "21.5.258.0.0,0",
            "models": null,
            "version": "12.3.1"
          },
          {
            "expert": false,
            "minimumBoot": "iBoot-7459.101.2",
            "minimumMacOS": "12.1",
            "minimumRecovery": "21.5.230.0.0,0",
            "models": null,
            "version": "12.3"
          },
          {
            "expert": false,
            "minimumBoot": "iBoot-8422.141.2",
            "minimumMacOS": "13.0",
            "minimumRecovery": "22.7.74.0.0,0",
            "models": null,
            "version": "13.5"
          },
          {
            "expert": false,
            "minimumBoot": "iBoot-10151.140.19",
            "minimumMacOS": "14.6",
            "minimumRecovery": "23.10.220.0.0,0",
            "models": [
              "j433",
              "j434",
              "j504",
              "j613",
              "j615",
              "j514s",
              "j514c",
              "j514m",
              "j516s",
              "j516c",
              "j516m"
            ],
            "version": "14.8.3"
          }
        ],
        "runtimeVersion": "v0.9.2-aurora.5",
        "sourceSHA256": "17d0e11464af7996f45f83f0f535a0cc4e8d8c877a05775d3e1834aa38f16ad8"
      }
      """#
  }
#endif
