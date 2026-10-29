// iOS 6's libSystem predates the out-of-line atomics used by our OpenSSL
// archive. Use one mutex for these operations, including unaligned 64-bit
// fields. The assembly is_lock_free shim already selects the locked path.
#include <pthread.h>
#include <stdint.h>
#include <string.h>

static pthread_mutex_t atomic_lock = PTHREAD_MUTEX_INITIALIZER;

uint64_t podcold_load8(const volatile void *ptr, int order) __asm__("___atomic_load_8");
uint64_t podcold_load8(const volatile void *ptr, int order) {
    uint64_t value;
    pthread_mutex_lock(&atomic_lock);
    memcpy(&value, (const void *)ptr, sizeof(value));
    pthread_mutex_unlock(&atomic_lock);
    return value;
}

#define FETCH_OP(NAME, OP) \
uint64_t podcold_##NAME(volatile void *ptr, uint64_t value, int order) __asm__("___atomic_fetch_" #NAME "_8"); \
uint64_t podcold_##NAME(volatile void *ptr, uint64_t value, int order) { \
    uint64_t previous, updated; \
    pthread_mutex_lock(&atomic_lock); \
    memcpy(&previous, (const void *)ptr, sizeof(previous)); \
    updated = previous OP value; \
    memcpy((void *)ptr, &updated, sizeof(updated)); \
    pthread_mutex_unlock(&atomic_lock); \
    return previous; \
}
FETCH_OP(add, +)
FETCH_OP(sub, -)
FETCH_OP(and, &)
FETCH_OP(or, |)

void podcold_load(size_t size, const volatile void *ptr, void *result, int order) __asm__("___atomic_load");
void podcold_load(size_t size, const volatile void *ptr, void *result, int order) {
    pthread_mutex_lock(&atomic_lock);
    memcpy(result, (const void *)ptr, size);
    pthread_mutex_unlock(&atomic_lock);
}

void podcold_store(size_t size, volatile void *ptr, const void *value, int order) __asm__("___atomic_store");
void podcold_store(size_t size, volatile void *ptr, const void *value, int order) {
    pthread_mutex_lock(&atomic_lock);
    memcpy((void *)ptr, value, size);
    pthread_mutex_unlock(&atomic_lock);
}
