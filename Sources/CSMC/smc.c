#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Struct layout and selectors used by AppleSMC since the Intel days; Apple
// Silicon keeps the same user-client interface.

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo = 9,
};

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24);
    out[1] = (char)(v >> 16);
    out[2] = (char)(v >> 8);
    out[3] = (char)v;
    out[4] = 0;
}

static kern_return_t call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCKeyData), out, &outSize);
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return r;
}

void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

static int key_info(uint32_t key, SMCKeyInfo *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    kern_return_t r = call(&in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return out.result;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, smc_value_t *outValue) {
    memset(outValue, 0, sizeof(*outValue));
    uint32_t k = fourcc(key);
    SMCKeyInfo info;
    int r = key_info(k, &info);
    if (r) return r;

    SMCKeyData in = {0}, out = {0};
    in.key = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    r = call(&in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return out.result;

    unfourcc(k, outValue->key);
    unfourcc(info.dataType, outValue->type);
    outValue->size = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(outValue->bytes, out.bytes, outValue->size);
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    uint32_t k = fourcc(key);
    SMCKeyInfo info;
    int r = key_info(k, &info);
    if (r) return r;
    if (info.dataSize != size || size > 32) return -2;

    SMCKeyData in = {0}, out = {0};
    in.key = k;
    in.data8 = kSMCWriteKey;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    r = call(&in, &out);
    if (r != KERN_SUCCESS) return r;
    return out.result;
}

uint32_t smc_key_count(void) {
    smc_value_t v;
    if (smc_read("#KEY", &v) != 0 || v.size < 4) return 0;
    return ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) | ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
}

int smc_key_at(uint32_t index, char out[5]) {
    SMCKeyData in = {0}, o = {0};
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    kern_return_t r = call(&in, &o);
    if (r != KERN_SUCCESS) return r;
    if (o.result != 0) return o.result;
    unfourcc(o.key, out);
    return 0;
}
