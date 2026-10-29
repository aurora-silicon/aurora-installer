#ifndef AURORA_ACCOUNT_COMMAND_H
#define AURORA_ACCOUNT_COMMAND_H
int aurora_account_command(const char *path, const char *const *arguments,
                            const unsigned char *input, long input_size,
                            unsigned char **output, long *output_size,
                            unsigned timeout_seconds);
void aurora_account_free(void *buffer, long size);
void aurora_account_wipe(void *buffer, long size);
#endif
