#ifndef AURORA_INSTALLER_SYSTEM_H
#define AURORA_INSTALLER_SYSTEM_H

int aurora_installer_flock(int descriptor, int operation);

// Instantiates lsm2 without initializing or rendering it and returns the
// finite positive maximum shared by every public VelocityLimit0/1/2
// AudioUnitParameterInfo record. Zero is success.
int aurora_lsm2_velocity_parameter_max(float *maximum);

#endif
