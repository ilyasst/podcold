#include "../../podcold/podcold/Networking/atomic_stubs.c"
#include <assert.h>
#include <stdio.h>

static unsigned char unaligned[16];
static void *increment(void *unused) {
    for (int i = 0; i < 10000; ++i) podcold_add(unaligned + 1, 1, 5);
    return NULL;
}

int main(void) {
    pthread_t threads[4];
    uint64_t value = 0;
    podcold_store(8, unaligned + 1, &value, 5);
    for (int i = 0; i < 4; ++i) assert(pthread_create(&threads[i], NULL, increment, NULL) == 0);
    for (int i = 0; i < 4; ++i) assert(pthread_join(threads[i], NULL) == 0);
    assert(podcold_load8(unaligned + 1, 5) == 40000);
    assert(podcold_sub(unaligned + 1, 39990, 5) == 40000);
    assert(podcold_or(unaligned + 1, 1, 5) == 10);
    assert(podcold_and(unaligned + 1, 7, 5) == 11);
    podcold_load(8, unaligned + 1, &value, 5);
    assert(value == 3);
    puts("Passed legacy atomic load/store/bitwise and 40,000 concurrent unaligned increments.");
}
