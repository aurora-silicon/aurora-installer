// SPDX-License-Identifier: MIT

#include <errno.h>
#include <hivex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BOOT_MANAGER_GUID "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"

static void fail(const char *message)
{
    fprintf(stderr, "bcd-set-testsigning: %s", message);
    if (errno)
        fprintf(stderr, ": %s", strerror(errno));
    fputc('\n', stderr);
    exit(1);
}

static hive_node_h child(hive_h *hive, hive_node_h parent, const char *name)
{
    hive_node_h node = hivex_node_get_child(hive, parent, name);
    if (!node)
        fail(name);
    return node;
}

static void format_guid(const uint8_t *value, char output[39])
{
    snprintf(output, 39,
             "{%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
             "%02x%02x%02x%02x%02x%02x}",
             value[3], value[2], value[1], value[0], value[5], value[4],
             value[7], value[6], value[8], value[9], value[10], value[11],
             value[12], value[13], value[14], value[15]);
}

static void find_default_loader(hive_h *hive, char output[39])
{
    hive_node_h objects = child(hive, hivex_root(hive), "Objects");
    hive_node_h bootmgr = child(hive, objects, BOOT_MANAGER_GUID);
    hive_node_h elements = child(hive, bootmgr, "Elements");
    hive_node_h default_object = child(hive, elements, "23000003");
    hive_value_h element = hivex_node_get_value(hive, default_object, "Element");
    if (!element)
        fail("default boot object has no Element value");

    hive_type type;
    size_t length;
    char *value = hivex_value_value(hive, element, &type, &length);
    if (!value)
        fail("unable to read default boot object");
    if (type != hive_t_REG_BINARY || length != 16) {
        free(value);
        errno = 0;
        fail("default boot object is not a 16-byte GUID");
    }
    format_guid((const uint8_t *)value, output);
    free(value);
}

static hive_node_h testsigning_node(hive_h *hive, const char *loader_guid,
                                    int create)
{
    hive_node_h objects = child(hive, hivex_root(hive), "Objects");
    hive_node_h loader = child(hive, objects, loader_guid);
    hive_node_h elements = child(hive, loader, "Elements");
    hive_node_h node = hivex_node_get_child(hive, elements, "16000049");
    if (!node && create)
        node = hivex_node_add_child(hive, elements, "16000049");
    if (!node)
        fail("default loader has no TESTSIGNING element");
    return node;
}

static void verify_testsigning(const char *path, const char *loader_guid)
{
    hive_h *hive = hivex_open(path, 0);
    if (!hive)
        fail("unable to reopen BCD store");
    hive_node_h node = testsigning_node(hive, loader_guid, 0);
    hive_value_h element = hivex_node_get_value(hive, node, "Element");
    if (!element)
        fail("TESTSIGNING element has no value");
    hive_type type;
    size_t length;
    char *value = hivex_value_value(hive, element, &type, &length);
    if (!value || type != hive_t_REG_BINARY || length != 1 || value[0] != 1)
        fail("TESTSIGNING verification failed");
    free(value);
    if (hivex_close(hive) == -1)
        fail("unable to close verified BCD store");
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: bcd-set-testsigning BCD\n");
        return 2;
    }

    hive_h *hive = hivex_open(argv[1], HIVEX_OPEN_WRITE);
    if (!hive)
        fail("unable to open BCD store for writing");
    char loader_guid[39];
    find_default_loader(hive, loader_guid);
    hive_node_h node = testsigning_node(hive, loader_guid, 1);
    char enabled = 1;
    hive_set_value value = {
        .key = "Element",
        .t = hive_t_REG_BINARY,
        .len = sizeof(enabled),
        .value = &enabled,
    };
    if (hivex_node_set_value(hive, node, &value, 0) == -1)
        fail("unable to set TESTSIGNING");
    if (hivex_commit(hive, NULL, 0) == -1)
        fail("unable to commit BCD store");
    if (hivex_close(hive) == -1)
        fail("unable to close BCD store");

    verify_testsigning(argv[1], loader_guid);
    printf("Enabled TESTSIGNING for WinPE loader %s\n", loader_guid);
    return 0;
}
