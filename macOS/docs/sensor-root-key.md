# Touch ID root-key extraction: draft qualification boundary

The Neo sensor needs a complete device-local combined root-key container. A bare `IMG4` containing an `MSRk` payload is not sufficient. Keep the outer `comb`, its `fdrd` image and manifest, and its `secb` trust bundle byte-for-byte. Never synthesize a manifest or combine records from different machines.

`SignedSensorInputs.rootKey` checks this envelope and rejects a missing trust bundle, wrong payload type, truncated records and trailing bytes. This is structural admission only. It does not verify the certificate chain or establish that the record belongs to the connected sensor.

The native collector still reads the named root-key record from the protected factory store on the selected internal disk. That raw factory record has not been shown to contain the combined envelope required by the sensor. Do not merge this draft as a working automatic extractor: the sealed-record retrieval path remains to be implemented and qualified.

Before merging, use a Touch ID-equipped Neo and its own accepted capture to identify the sealed source, compare the complete signed record and trust bundle, verify sensor binding, and confirm that the installed kernel opens a sensor session after a cold boot. Then repeat through a fresh native install. Keep all device records and keys private; synthetic fixture acceptance is not hardware qualification.

The currently available Neo has no Touch ID. The previously tested sensor-equipped machine and its capture are unavailable. Sensorless machines must continue to skip this collection path.

Treat the root-key record as device-private: root-owned mode `0600` in staging and after installation, with private staging directories mode `0700`. Its archive writer and final installer must preserve that mode before this path is enabled; ordinary world-readable firmware defaults are unsuitable.
