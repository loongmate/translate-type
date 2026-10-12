#include <stdint.h>
#include <stdbool.h>
bool TTInitializeRime(const char *shared, const char *user);
uintptr_t TTCreateSession(const char *schema);
void TTDestroySession(uintptr_t session);
bool TTProcessKey(uintptr_t session, int key, int modifiers);
bool TTSelectCandidate(uintptr_t session, int index);
bool TTHighlightCandidate(uintptr_t session, int index);
void TTCommitComposition(uintptr_t session);
void TTClearComposition(uintptr_t session);
char *TTSnapshot(uintptr_t session);
void TTFreeString(char *text);
