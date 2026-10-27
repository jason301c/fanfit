#ifndef FANFIT_SMC_H
#define FANFIT_SMC_H

#include <stdint.h>
#include <stdbool.h>

// Thin wrapper over the AppleSMC IOKit user client.
// Reads work as any user; writes need root.

typedef struct {
    char key[5];       // four-character key, NUL-terminated
    char type[5];      // e.g. "flt ", "ui8 ", "fpe2"
    uint32_t size;     // payload size in bytes
    uint8_t bytes[32]; // raw payload
} smc_value_t;

// Opens the connection. Returns 0 on success, an IOKit error otherwise.
int smc_open(void);
void smc_close(void);

int smc_read(const char *key, smc_value_t *out);
// Writes `size` bytes to `key`. The size must match the key's own size.
int smc_write(const char *key, const uint8_t *bytes, uint32_t size);

uint32_t smc_key_count(void);
// Gets the key at `index` (0-based) into `out` (5 bytes).
int smc_key_at(uint32_t index, char out[5]);

#endif
