#include "AuroraInstallerSystem.h"

#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>

int aurora_installer_flock(int descriptor, int operation) {
  return flock(descriptor, operation);
}

int aurora_lsm2_velocity_parameter_max(float *maximum) {
  if (!maximum) return -1;
  AudioComponentDescription description = {
    kAudioUnitType_Effect, 'lsm2', kAudioUnitManufacturer_Apple, 0, 0
  };
  AudioComponent component = AudioComponentFindNext(NULL, &description);
  if (!component) {
    void *image = dlopen(
      "/System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP",
      RTLD_NOW | RTLD_LOCAL);
    AudioComponentFactoryFunction factory = image
      ? (AudioComponentFactoryFunction)dlsym(image, "AULoudspeakerManagerV2Factory") : NULL;
    if (!factory) return -2;
    component = AudioComponentRegister(
      &description, CFSTR("Aurora tuning metadata"), 0x10001, factory);
  }
  if (!component) return -3;
  AudioUnit unit = NULL;
  OSStatus status = AudioComponentInstanceNew(component, &unit);
  if (status || !unit) return -4;

  UInt32 bytes = 0;
  status = AudioUnitGetPropertyInfo(
    unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &bytes, NULL);
  if (status || bytes == 0 || bytes % sizeof(AudioUnitParameterID)) {
    AudioComponentInstanceDispose(unit);
    return -5;
  }
  AudioUnitParameterID *identifiers = malloc(bytes);
  if (!identifiers) {
    AudioComponentInstanceDispose(unit);
    return -6;
  }
  status = AudioUnitGetProperty(
    unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, identifiers, &bytes);
  if (status) {
    free(identifiers);
    AudioComponentInstanceDispose(unit);
    return -7;
  }

  CFStringRef names[3] = { CFSTR("VelocityLimit0"), CFSTR("VelocityLimit1"), CFSTR("VelocityLimit2") };
  UInt32 counts[3] = {0, 0, 0};
  float found = 0.0f;
  bool have = false;
  int result = 0;
  UInt32 count = bytes / sizeof(AudioUnitParameterID);
  for (UInt32 i = 0; i < count; ++i) {
    AudioUnitParameterInfo info = {0};
    UInt32 infoBytes = sizeof(info);
    status = AudioUnitGetProperty(
      unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, identifiers[i],
      &info, &infoBytes);
    if (status) { result = -8; break; }
    int matched = -1;
    for (int j = 0; j < 3; ++j) {
      const char *plain = j == 0 ? "VelocityLimit0" : j == 1 ? "VelocityLimit1" : "VelocityLimit2";
      if (((info.flags & kAudioUnitParameterFlag_HasCFNameString) && info.cfNameString
           && CFEqual(info.cfNameString, names[j]))
          || (!(info.flags & kAudioUnitParameterFlag_HasCFNameString)
              && !strncmp(info.name, plain, sizeof(info.name)) && strlen(plain) < sizeof(info.name))) {
        matched = j;
        break;
      }
    }
    if (matched >= 0) {
      if (!isfinite(info.maxValue) || info.maxValue <= 0.0f
          || (have && info.maxValue != found)) {
        result = -9;
      } else {
        found = info.maxValue;
        have = true;
        counts[matched]++;
      }
    }
    if ((info.flags & kAudioUnitParameterFlag_HasCFNameString) && info.cfNameString
        && (info.flags & kAudioUnitParameterFlag_CFNameRelease)) {
      CFRelease(info.cfNameString);
    }
    if (result) break;
  }
  free(identifiers);
  AudioComponentInstanceDispose(unit);
  if (result) return result;
  if (!have || counts[0] == 0 || counts[0] != counts[1] || counts[1] != counts[2]) return -10;
  *maximum = found;
  return 0;
}
