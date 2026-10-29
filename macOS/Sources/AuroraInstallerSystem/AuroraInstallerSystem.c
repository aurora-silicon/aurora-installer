#include "AuroraInstallerSystem.h"

#include <sys/file.h>

int aurora_installer_flock(int descriptor, int operation) {
  return flock(descriptor, operation);
}
